import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/notify.dart';
import '../services/plugin_catalog.dart';
import '../services/plugins.dart';
import '../services/store.dart';
import '../services/updater.dart' show compareVersions;
import '../theme.dart';
import 'panel.dart';

/// Instalar um plugin, em dois passos: de onde, e se você confia nele.
///
/// O segundo passo é o motivo de isto ser um diálogo e não um campo na tela
/// de configurações. Um plugin é um programa que vai rodar com as suas
/// permissões, e o momento de ler o que ele pede é antes de ele estar
/// instalado -- ver [StagedPlugin].
Future<void> showInstallPlugin(BuildContext context, AppStore store) => showDialog<void>(
  context: context,
  builder: (ctx) => _Install(store: store),
);

class _Install extends StatefulWidget {
  const _Install({required this.store});

  final AppStore store;

  @override
  State<_Install> createState() => _InstallState();
}

class _InstallState extends State<_Install> {
  final _source = TextEditingController();
  bool _busy = false;
  String? _error;
  StagedPlugin? _staged;

  @override
  void dispose() {
    // Fechar o diálogo por fora -- esc, clique na barreira -- com um plugin
    // já baixado é desistir dele: o rascunho não pode ficar pra trás.
    if (_staged case final s?) widget.store.plugins.discard(s);
    _source.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final staged = await widget.store.plugins.stage(_source.text);
      if (!mounted) {
        await widget.store.plugins.discard(staged);
        return;
      }
      setState(() => _staged = staged);
    } on PluginInstallError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFolder() async {
    final path = await Notifier.chooseFolder();
    if (path == null || !mounted) return;
    _source.text = path;
    await _fetch();
  }

  Future<void> _install() async {
    final staged = _staged;
    if (staged == null || _busy) return;
    setState(() => _busy = true);
    try {
      final plugin = await widget.store.pluginUpdates.finish(staged);
      _staged = null;
      widget.store.showBanner(
        staged.replacing == null
            ? '${plugin.name} ${plugin.manifest?.version ?? ''} instalado'
            : '${plugin.name} atualizado de ${staged.replacing} pra ${plugin.manifest?.version}',
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _staged = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final staged = _staged;
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(
        staged == null
            ? 'Instalar plugin'
            : staged.replacing == null
            ? 'Instalar ${staged.manifest.name}?'
            : 'Atualizar ${staged.manifest.name}?',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 480,
        child: staged == null ? _where() : PluginTrust(manifest: staged.manifest, staged: staged),
      ),
      actions: staged == null
          ? [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
              FilledButton(onPressed: _busy ? null : _fetch, child: const Text('Continuar')),
            ]
          : [
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        widget.store.plugins.discard(staged);
                        setState(() => _staged = null);
                      },
                child: const Text('Voltar'),
              ),
              FilledButton(
                onPressed: _busy ? null : _install,
                child: Text(staged.replacing == null ? 'Confio, instalar' : 'Confio, atualizar'),
              ),
            ],
    );
  }

  Widget _where() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Uma URL de git, um .zip ou uma pasta com um $mxManifestName na raiz.',
          style: TextStyle(fontSize: 12, color: Mx.fgDim, height: 1.4),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _source,
          autofocus: true,
          enabled: !_busy,
          style: TextStyle(fontSize: 13, fontFamily: Mx.mono),
          onSubmitted: (_) => _fetch(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'https://github.com/voce/maestria-plugin-x.git',
            hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12.5),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: _busy ? null : _pickFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 15),
              label: const Text('Escolher pasta…'),
            ),
            const Spacer(),
            if (_busy)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        if (_error case final why?) ...[
          const SizedBox(height: 8),
          Text(why, style: TextStyle(fontSize: 12, color: Mx.red, height: 1.4)),
        ],
      ],
    );
  }
}

/// O catálogo: os plugins que dá pra instalar com um clique, cada um com o que
/// ele é e o que pede. Ver [PluginUpdates].
///
/// Quem instala escolhe um por um: os outros nem chegam ao disco. E o que
/// entra por aqui recebe as versões novas de lá.
Future<void> showPluginCatalog(BuildContext context, AppStore store) => showDialog<void>(
  context: context,
  builder: (ctx) => _Catalog(store: store),
);

class _Catalog extends StatefulWidget {
  const _Catalog({required this.store});

  final AppStore store;

  @override
  State<_Catalog> createState() => _CatalogState();
}

class _CatalogState extends State<_Catalog> {
  static const _url = mxOfficialCatalog;

  bool _loading = false;
  String? _error;

  /// O que deu errado com cada plugin, debaixo dele.
  final Map<String, String> _failed = {};

  /// Os que estão sendo baixados por este diálogo.
  final Set<String> _busy = {};

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Sempre do servidor: o que ficou na memória da última procura aparece
  /// enquanto isso, mas pode ser de horas atrás.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await store.pluginUpdates.load(_url);
    } catch (e) {
      if (mounted) setState(() => _error = 'Não deu pra ler o catálogo: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install(CatalogEntry e) async {
    setState(() {
      _busy.add(e.id);
      _failed.remove(e.id);
    });
    try {
      final staged = await store.pluginUpdates.stageEntry(e, _url);
      if (!mounted) {
        await store.plugins.discard(staged);
        return;
      }
      await confirmStagedPlugin(context, store, staged);
    } catch (err) {
      if (mounted) setState(() => _failed[e.id] = '$err');
    } finally {
      if (mounted) setState(() => _busy.remove(e.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final catalog = store.pluginUpdates.loaded(_url);
        return AlertDialog(
          backgroundColor: Mx.bgSidebar,
          title: Row(
            children: [
              const Expanded(child: Text('Catálogo de plugins', style: TextStyle(fontSize: 15))),
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: 460,
            child: catalog == null
                ? Center(
                    child: _error == null
                        ? const SizedBox()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 12, color: Mx.red, height: 1.4),
                              ),
                              const SizedBox(height: 8),
                              TextButton(onPressed: _load, child: const Text('Tentar de novo')),
                            ],
                          ),
                  )
                : ListView(children: [for (final e in catalog.plugins) _entry(e)]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                showInstallPlugin(context, store);
              },
              child: const Text('De uma URL, .zip ou pasta…'),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
          ],
        );
      },
    );
  }

  Widget _entry(CatalogEntry e) {
    final installed = store.plugins.byId(e.id);
    final have = installed?.manifest?.version;
    final line = TextStyle(fontSize: 11.5, color: Mx.fgDim, height: 1.4);
    final perms = [for (final id in e.permissions) PluginPermission.byId(id)?.label ?? id];
    final busy = _busy.contains(e.id) || store.pluginUpdates.busy.contains(e.id);

    final Widget action;
    if (busy) {
      action = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (installed?.linked == true) {
      action = Text('Desenvolvimento', style: TextStyle(fontSize: 11.5, color: Mx.purple));
    } else if (!e.fits) {
      action = Text('Pede uma MaestrIA\nmais nova', textAlign: TextAlign.end, style: line);
    } else if (have != null && compareVersions(e.version, have) <= 0) {
      action = Text('Instalado', style: line);
    } else {
      action = FilledButton.tonal(
        onPressed: () => _install(e),
        child: Text(have == null ? 'Instalar' : 'Atualizar'),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Mx.bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Mx.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _CatalogGlyph(url: e.icon),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            e.name,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Mx.fg,
                            ),
                          ),
                          Text(
                            have != null && have != e.version ? '$have → ${e.version}' : e.version,
                            style: TextStyle(fontSize: 11, fontFamily: Mx.mono, color: Mx.fgFaint),
                          ),
                          if (e.git != null)
                            Text('De fora', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (e.description.isNotEmpty)
                        Text(
                          e.description,
                          style: line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (perms.isNotEmpty)
                        Text(
                          'Pode ${perms.join('; ')}',
                          style: line.copyWith(color: Mx.yellow),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (_failed[e.id] case final why?)
                        Text(why, style: line.copyWith(color: Mx.red)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          action,
        ],
      ),
    );
  }
}

/// O ícone de um plugin do catálogo: o `.svg` dele, numa cor só como o
/// `PluginGlyph` -- ou o genérico, enquanto não chega ou quando não há.
class _CatalogGlyph extends StatelessWidget {
  const _CatalogGlyph({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.extension_outlined, size: 17, color: Mx.fgDim);
    final u = url;
    if (u == null || !u.toLowerCase().endsWith('.svg')) return fallback;
    return SvgPicture.network(
      u,
      width: 17,
      height: 17,
      colorFilter: ColorFilter.mode(Mx.fgDim, BlendMode.srcIn),
      placeholderBuilder: (_) => fallback,
      errorBuilder: (_, _, _) => fallback,
      excludeFromSemantics: true,
    );
  }
}

/// O "confio" de um plugin já baixado: o que ele é e pede, e instalar. Desistir
/// apaga o rascunho.
Future<MxPlugin?> confirmStagedPlugin(
  BuildContext context,
  AppStore store,
  StagedPlugin staged,
) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(
        staged.replacing == null
            ? 'Instalar ${staged.manifest.name}?'
            : 'Atualizar ${staged.manifest.name}?',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 480,
        child: PluginTrust(manifest: staged.manifest, staged: staged),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(staged.replacing == null ? 'Confio, instalar' : 'Confio, atualizar'),
        ),
      ],
    ),
  );
  if (go != true) {
    await store.plugins.discard(staged);
    return null;
  }
  final plugin = await store.pluginUpdates.finish(staged);
  store.showBanner(_installedText(plugin, staged));
  return plugin;
}

String _installedText(MxPlugin plugin, StagedPlugin staged) => staged.replacing == null
    ? '${plugin.name} ${plugin.manifest?.version ?? ''} instalado'
    : '${plugin.name} atualizado de ${staged.replacing} pra ${plugin.manifest?.version}';

/// O "atualizar" pedido na tela: baixa a versão nova e instala. Pergunta antes
/// quando ela pede mais do que a instalada pedia, ou quando vem de outro lugar
/// -- passar a receber pelo catálogo é instalar um pacote de outra origem.
Future<void> updatePlugin(BuildContext context, AppStore store, PluginUpdate u) async {
  final StagedPlugin staged;
  try {
    staged = await store.pluginUpdates.prepare(u);
  } catch (e) {
    store.showBanner('Não deu pra baixar a ${u.to}: $e', sticky: true);
    return;
  }
  final old = store.plugins.byId(u.id)?.manifest;
  final switching = store.plugins.origins[u.id] != u.origin;
  if (!switching && old != null && !PluginUpdates.asksMore(old, staged.manifest)) {
    final plugin = await store.pluginUpdates.finish(staged);
    store.showBanner(_installedText(plugin, staged));
    return;
  }
  if (!context.mounted) {
    await store.plugins.discard(staged);
    return;
  }
  await confirmStagedPlugin(context, store, staged);
}

/// O que um plugin é e o que ele pede, do jeito que se lê antes de confiar.
///
/// Público porque são dois lugares: a instalação e o carregamento de uma
/// pasta de desenvolvimento.
class PluginTrust extends StatelessWidget {
  const PluginTrust({super.key, required this.manifest, this.staged});

  final PluginManifest manifest;
  final StagedPlugin? staged;

  @override
  Widget build(BuildContext context) {
    final m = manifest;
    Widget fact(IconData icon, Color color, String text, {bool mono = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: Mx.fg,
                fontFamily: mono ? Mx.mono : null,
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            '${m.id} ${m.version}',
            if (m.author.isNotEmpty) 'de ${m.author}',
            if (staged?.replacing case final v?) 'no lugar da $v',
          ].join(' · '),
          style: TextStyle(fontSize: 11.5, fontFamily: Mx.mono, color: Mx.fgDim),
        ),
        if (m.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(m.description, style: TextStyle(fontSize: 12.5, color: Mx.fg, height: 1.4)),
        ],
        const SizedBox(height: 16),
        if (m.hasProcess)
          fact(
            Icons.terminal,
            Mx.yellow,
            'Roda um programa seu, com as suas permissões: ${m.main!.join(' ')}',
          )
        else
          fact(Icons.check_rounded, Mx.green, 'Só declarações — nenhum programa roda'),
        for (final perm in m.permissions) fact(Icons.key_outlined, Mx.yellow, 'Pode ${perm.label}'),
        if (m.commands.isNotEmpty)
          fact(
            Icons.bolt_outlined,
            Mx.fgDim,
            'Comandos: ${m.commands.map((c) => c.key == null ? c.title : '${c.title} (${c.key!.label})').join(', ')}',
          ),
        if (m.themes.isNotEmpty)
          fact(
            Icons.palette_outlined,
            Mx.fgDim,
            m.themes.length == 1 ? 'Um tema' : '${m.themes.length} temas',
          ),
        for (final w in m.warnings) fact(Icons.warning_amber_outlined, Mx.yellow, w),
      ],
    );
  }
}

/// O log de um plugin, ao vivo: o stderr dele, o que ele mandou pelo `log`, e
/// o que a janela disse sobre ele. É onde quem escreve o plugin depura.
Future<void> showPluginLog(BuildContext context, AppStore store, MxPlugin plugin) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: Text('Log de ${plugin.name}', style: const TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 640,
          height: 380,
          child: ValueListenableBuilder<int>(
            valueListenable: store.plugins.logs,
            builder: (context, _, _) => Container(
              decoration: BoxDecoration(
                color: Mx.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Mx.border),
              ),
              child: plugin.log.isEmpty
                  ? Center(
                      child: Text('Nada ainda', style: TextStyle(fontSize: 12, color: Mx.fgFaint)),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(10),
                      itemCount: plugin.log.length,
                      itemBuilder: (context, i) => SelectableText(
                        plugin.log[plugin.log.length - 1 - i],
                        style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fg, height: 1.45),
                      ),
                    ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: plugin.log.join('\n'))),
            child: const Text('Copiar'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
        ],
      ),
    );

Future<void> confirmUninstallPlugin(BuildContext context, AppStore store, MxPlugin plugin) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('Remover ${plugin.name}?', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Text(
          plugin.linked
              ? 'Sai da MaestrIA o link pra ${plugin.dir.split('/').last}. A sua pasta de '
                    'desenvolvimento fica onde está, intocada.'
              : 'A pasta do plugin e o que ele guardou vão embora. Pra ter de volta, '
                    'instale de novo.',
          style: TextStyle(fontSize: 12.5, color: Mx.fg, height: 1.45),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Mx.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remover'),
        ),
      ],
    ),
  );
  if (go != true) return;
  await store.uninstallPlugin(plugin);
  store.showBanner('${plugin.name} removido');
}

/// Carrega um plugin da pasta em que ele está sendo escrito. Ver
/// [Plugins.link].
Future<void> linkDevPlugin(AppStore store) async {
  final path = await Notifier.chooseFolder();
  if (path == null) return;
  try {
    final plugin = await store.plugins.link(path);
    store.showBanner('${plugin.name} carregado de ${path.split('/').last} — reinicie pra pegar mudanças');
  } on PluginInstallError catch (e) {
    store.showBanner('Não deu pra carregar: ${e.message}', sticky: true);
  }
}

/// Uma opção do seletor rápido: o que volta pro plugin, o nome e uma linha
/// embaixo dele.
typedef QuickPickItem = ({String value, String label, String? detail});

/// O seletor rápido de um plugin (`window.pick`): o quick pick do VS Code.
///
/// Um campo que filtra e a lista embaixo, com as setas andando e o enter
/// escolhendo -- é o que se espera de "escolha um projeto" quando a mão já está
/// no teclado. Null é o esc, ou o clique fora.
Future<String?> showQuickPick(
  BuildContext context, {
  required String title,
  String? placeholder,
  required List<QuickPickItem> items,
}) => showDialog<String>(
  context: context,
  barrierColor: const Color(0x33000000),
  builder: (ctx) => _QuickPick(title: title, placeholder: placeholder, items: items),
);

class _QuickPick extends StatefulWidget {
  const _QuickPick({required this.title, this.placeholder, required this.items});

  final String title;
  final String? placeholder;
  final List<QuickPickItem> items;

  @override
  State<_QuickPick> createState() => _QuickPickState();
}

class _QuickPickState extends State<_QuickPick> {
  final _query = TextEditingController();
  int _at = 0;

  List<QuickPickItem> get _shown {
    final terms = _query.text.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return [
      for (final it in widget.items)
        if (terms.every((t) => '${it.label} ${it.detail ?? ''}'.toLowerCase().contains(t))) it,
    ];
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = _shown.length;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && n > 0) {
      setState(() => _at = (_at + 1) % n);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && n > 0) {
      setState(() => _at = (_at - 1 + n) % n);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _pick() {
    final shown = _shown;
    if (shown.isEmpty) return;
    Navigator.pop(context, shown[_at.clamp(0, shown.length - 1)].value);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Dialog(
      backgroundColor: Mx.bgSidebar,
      alignment: const Alignment(0, -0.6),
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text(widget.title, style: TextStyle(fontSize: 12, color: Mx.fgDim)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Focus(
                onKeyEvent: _key,
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => setState(() => _at = 0),
                  onSubmitted: (_) => _pick(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.placeholder ?? 'Filtrar',
                    hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12.5),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text('Nada com esse nome', style: TextStyle(fontSize: 12, color: Mx.fgFaint)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final it = shown[i];
                        final lit = i == _at;
                        // O aceso é o da linha (`_at`), que o teclado também
                        // move; a tinta só acompanha o mesmo contorno.
                        return MxHover(
                          onTap: () => Navigator.pop(context, it.value),
                          onHover: (h) {
                            if (h && _at != i) setState(() => _at = i);
                          },
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          radius: 6,
                          hoverColor: Colors.transparent,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: lit ? Mx.bgActive : null,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(it.label, style: TextStyle(fontSize: 13, color: Mx.fg)),
                                if (it.detail case final d? when d.isNotEmpty)
                                  Text(
                                    d,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// O campo de texto rápido de um plugin (`window.input`): o `showInputBox` do
/// VS Code.
///
/// Existe porque perguntar um nome -- o de um grupo novo -- abria uma janela
/// inteira na grade pra um campo só. Aqui é o mesmo cartão do [showQuickPick],
/// no mesmo lugar: o enter confirma, e o esc ou o clique fora devolvem null.
/// O texto volta como foi digitado, sem os espaços das pontas; vazio é null.
Future<String?> showQuickInput(
  BuildContext context, {
  required String title,
  String? placeholder,
  String? value,
  String? prompt,
}) => showDialog<String>(
  context: context,
  barrierColor: const Color(0x33000000),
  builder: (ctx) =>
      _QuickInput(title: title, placeholder: placeholder, value: value, prompt: prompt),
);

class _QuickInput extends StatefulWidget {
  const _QuickInput({required this.title, this.placeholder, this.value, this.prompt});

  final String title;
  final String? placeholder;
  final String? value;
  final String? prompt;

  @override
  State<_QuickInput> createState() => _QuickInputState();
}

class _QuickInputState extends State<_QuickInput> {
  // Com o valor de antes todo selecionado: renomear é quase sempre trocar tudo.
  late final _text = TextEditingController(text: widget.value)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.value?.length ?? 0);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _text.text.trim();
    Navigator.pop(context, text.isEmpty ? null : text);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Mx.bgSidebar,
      alignment: const Alignment(0, -0.6),
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text(widget.title, style: TextStyle(fontSize: 12, color: Mx.fgDim)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: TextField(
                controller: _text,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.placeholder,
                  hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12.5),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                widget.prompt ?? 'enter pra confirmar, esc pra cancelar',
                style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// O formulário em modal de um plugin (`window.form`). Ver [PluginForm].
///
/// Volta o botão apertado e os valores de todos os campos, inclusive os que o
/// `showIf` escondeu -- quem decide o que eles querem dizer é o plugin. Null é
/// o cancelar, o esc ou o clique fora.
Future<({String action, Map<String, String> values})?> showQuickForm(
  BuildContext context,
  PluginForm form,
) => showDialog<({String action, Map<String, String> values})>(
  context: context,
  builder: (ctx) => _QuickForm(form: form),
);

class _QuickForm extends StatefulWidget {
  const _QuickForm({required this.form});

  final PluginForm form;

  @override
  State<_QuickForm> createState() => _QuickFormState();
}

class _QuickFormState extends State<_QuickForm> {
  late final Map<String, TextEditingController> _text = {
    for (final f in widget.form.fields)
      if (!f.select) f.id: TextEditingController(text: f.value),
  };
  late final Map<String, String> _picks = {
    for (final f in widget.form.fields)
      if (f.select)
        f.id: f.options.any((o) => o.$1 == f.value) ? f.value : (f.options.firstOrNull?.$1 ?? ''),
  };

  /// O campo obrigatório que estava vazio no último clique.
  String? _missing;

  Map<String, String> get _values => {
    for (final f in widget.form.fields) f.id: f.select ? _picks[f.id]! : _text[f.id]!.text,
  };

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _press(PluginFormButton b) {
    final values = _values;
    if (!b.danger) {
      final empty = widget.form.fields.firstWhereOrNull(
        (f) => f.required && f.visibleWith(values) && values[f.id]!.trim().isEmpty,
      );
      if (empty != null) {
        setState(() => _missing = empty.id);
        return;
      }
    }
    Navigator.pop(context, (action: b.action, values: values));
  }

  /// O enter de um campo: o botão de destaque, ou o último que não apaga nada.
  void _submit() {
    final b =
        widget.form.buttons.firstWhereOrNull((b) => b.primary) ??
        widget.form.buttons.lastWhereOrNull((b) => !b.danger);
    if (b != null) _press(b);
  }

  static const _border = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(7)));

  InputDecoration _decoration(PluginFormField f) => InputDecoration(
    labelText: f.label,
    hintText: f.placeholder,
    isDense: true,
    labelStyle: TextStyle(color: Mx.fgDim, fontSize: 12),
    hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12.5),
    border: _border,
    errorText: _missing == f.id ? 'falta ${f.label ?? 'este campo'}' : null,
  );

  Widget _field(PluginFormField f, {required bool first}) {
    if (!f.select) {
      return TextField(
        controller: _text[f.id],
        autofocus: first,
        style: const TextStyle(fontSize: 13),
        onChanged: (_) {
          if (_missing == f.id) setState(() => _missing = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: _decoration(f),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: _picks[f.id],
      isDense: true,
      isExpanded: true,
      dropdownColor: Mx.bgActive,
      borderRadius: BorderRadius.circular(Mx.radius),
      elevation: 12,
      menuMaxHeight: 320,
      style: TextStyle(fontSize: 13, color: Mx.fg),
      decoration: _decoration(f),
      items: [
        for (final (value, label) in f.options)
          DropdownMenuItem(
            value: value,
            child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1),
          ),
      ],
      // Repinta: um campo com `showIf` neste aparece ou some.
      onChanged: (v) => setState(() => _picks[f.id] = v ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.form;
    final values = _values;
    final shown = [
      for (final f in form.fields)
        if (f.visibleWith(values)) f,
    ];
    final firstText = shown.firstWhereOrNull((f) => !f.select);
    final danger = [
      for (final b in form.buttons)
        if (b.danger) b,
    ];
    final rows = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      final f = shown[i];
      final field = _field(f, first: f == firstText);
      // Dois de meia largura seguidos dividem a linha; um sozinho fica com a
      // metade dele, e o resto da linha vazio -- a porta não estica até o fim.
      if (f.half) {
        final next = i + 1 < shown.length && shown[i + 1].half ? shown[++i] : null;
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Expanded(child: field),
              Expanded(child: next == null ? const SizedBox() : _field(next, first: false)),
            ],
          ),
        );
      } else {
        rows.add(field);
      }
    }
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(form.title, style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          // O rótulo do primeiro campo sobe pra borda quando ele ganha o foco:
          // sem este respiro ele é cortado pelo topo da rolagem.
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              ...rows,
              if (form.error case final error?)
                Text(error, style: TextStyle(fontSize: 12, color: Mx.red)),
            ],
          ),
        ),
      ),
      // O que apaga fica na outra ponta, longe do salvar.
      actionsAlignment: danger.isEmpty ? MainAxisAlignment.end : MainAxisAlignment.spaceBetween,
      actions: [
        if (danger.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final b in danger)
                TextButton(
                  onPressed: () => _press(b),
                  style: TextButton.styleFrom(foregroundColor: Mx.red),
                  child: Text(b.label),
                ),
            ],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancelar')),
            for (final b in form.buttons.where((b) => !b.danger))
              b.primary
                  ? FilledButton(onPressed: () => _press(b), child: Text(b.label))
                  : OutlinedButton(onPressed: () => _press(b), child: Text(b.label)),
          ],
        ),
      ],
    );
  }
}

/// As configurações de um plugin, desenhadas do que o manifesto declarou
/// (`contributes.settings`). Ver [PluginSetting].
///
/// Como o resto da tela de configurações, vale na hora: cada mudança é
/// guardada e chega no plugin (`settings.changed`) sem botão de salvar.
Future<void> showPluginSettings(BuildContext context, AppStore store, MxPlugin plugin) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => _PluginSettings(store: store, plugin: plugin),
      ),
    );

/// A cor de um valor de configuração: hex, um nome do tema, ou vazio (o texto
/// do tema). Null quando não é nenhum dos três -- o campo fica vermelho.
Color? pluginColor(String value) {
  final v = value.trim();
  if (v.isEmpty) return Mx.fg;
  if (v.startsWith('#')) return parseHexColor(v);
  return switch (v) {
    'red' => Mx.red,
    'green' => Mx.green,
    'yellow' => Mx.yellow,
    'accent' => Mx.accent,
    'purple' => Mx.purple,
    'faint' => Mx.fgFaint,
    'dim' => Mx.fgDim,
    _ => null,
  };
}

class _PluginSettings extends StatelessWidget {
  const _PluginSettings({required this.store, required this.plugin});

  final AppStore store;
  final MxPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final settings = plugin.manifest?.settings ?? const <PluginSetting>[];
    final values = store.plugins.settingsOf(plugin);
    final rows = <Widget>[];
    String? group;
    for (final s in settings) {
      if (s.group != null && s.group != group) {
        rows.add(
          Padding(
            padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 18, bottom: 8),
            child: Text(
              s.group!,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
            ),
          ),
        );
      }
      group = s.group;
      rows.add(
        _SettingRow(
          key: ValueKey(s.id),
          setting: s,
          value: values[s.id],
          changed: values[s.id] != s.resolve(null),
          onChanged: (v) => store.setPluginSetting(plugin, s.id, v),
        ),
      );
    }
    // As teclas que o manifesto pede, e as que o app já usa -- essas ficam sem
    // efeito, e é aqui que isso é dito (o cartão só pinta o ⋮ de amarelo).
    final keyed = [
      for (final c in plugin.manifest?.commands ?? const <PluginCommand>[])
        if (c.key != null) c,
    ];
    if (keyed.isNotEmpty) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 18, bottom: 8),
          child: Text(
            'Atalhos',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
          ),
        ),
      );
      for (final c in keyed) {
        final taken = store.keymap.owner(c.key!);
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(c.title, style: TextStyle(fontSize: 12.5, color: Mx.fg)),
                    ),
                    Text(
                      c.key!.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: Mx.mono,
                        color: taken == null ? Mx.fgDim : Mx.fgFaint,
                        decoration: taken == null ? null : TextDecoration.lineThrough,
                      ),
                    ),
                  ],
                ),
                if (taken != null)
                  Text(
                    'Já é "${taken.label}" no app — este comando fica sem tecla',
                    style: TextStyle(fontSize: 11.5, color: Mx.yellow, height: 1.4),
                  ),
              ],
            ),
          ),
        );
      }
    }
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('Configurar ${plugin.name}', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
      actions: [
        Text('Vale na hora', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Pronto')),
      ],
    );
  }
}

class _SettingRow extends StatefulWidget {
  const _SettingRow({
    super.key,
    required this.setting,
    required this.value,
    required this.changed,
    required this.onChanged,
  });

  final PluginSetting setting;
  final Object? value;

  /// Se o valor não é o padrão -- e aí aparece o "voltar ao padrão".
  final bool changed;

  /// Null volta pro padrão.
  final ValueChanged<Object?> onChanged;

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  late final _text = TextEditingController(text: _shown(widget.value));
  bool _invalid = false;

  /// As cores do debug console do VS Code, pra não precisar saber o hex de cor.
  static const _presets = ['#4FC1FF', '#89D185', '#F48771', '#CCA700', '#C586C0', '#9DA5B4'];

  static String _shown(Object? v) => v == null ? '' : '$v';

  @override
  void didUpdateWidget(_SettingRow old) {
    super.didUpdateWidget(old);
    // O valor mudou por fora -- um preset, o "voltar ao padrão": o campo
    // acompanha, a menos que seja o que você está digitando agora.
    final now = _shown(widget.value);
    if (old.value != widget.value && _text.text != now) {
      _text.text = now;
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _typed(String raw) {
    final s = widget.setting;
    switch (s.type) {
      case PluginSettingType.color:
        final ok = pluginColor(raw) != null;
        setState(() => _invalid = !ok);
        if (ok) widget.onChanged(raw.trim());
      case PluginSettingType.number:
        final n = num.tryParse(raw.trim());
        setState(() => _invalid = n == null);
        if (n != null) widget.onChanged(n);
      default:
        widget.onChanged(raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.title, style: TextStyle(fontSize: 12.5, color: Mx.fg)),
        if (s.description.isNotEmpty)
          Text(s.description, style: TextStyle(fontSize: 11, color: Mx.fgFaint, height: 1.35)),
      ],
    );
    final reset = widget.changed
        ? IconButton(
            tooltip: 'Voltar ao padrão',
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            onPressed: () => widget.onChanged(null),
            icon: Icon(Icons.restart_alt, color: Mx.fgDim),
          )
        : const SizedBox(width: 26);
    final field = switch (s.type) {
      PluginSettingType.boolean => Transform.scale(
        scale: 0.75,
        child: Switch(value: widget.value == true, onChanged: widget.onChanged),
      ),
      PluginSettingType.select => SizedBox(
        width: 200,
        child: DropdownButton<String>(
          value: widget.value as String?,
          isExpanded: true,
          isDense: true,
          dropdownColor: Mx.bgSidebar,
          style: TextStyle(fontSize: 12.5, color: Mx.fg),
          items: [
            for (final o in s.options) DropdownMenuItem(value: o.value, child: Text(o.label)),
          ],
          onChanged: widget.onChanged,
        ),
      ),
      PluginSettingType.color => _color(),
      _ => SizedBox(width: 200, child: _input()),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: label),
          const SizedBox(width: 12),
          field,
          reset,
        ],
      ),
    );
  }

  Widget _input({String? hint}) => TextField(
    controller: _text,
    style: TextStyle(fontSize: 12.5, fontFamily: widget.setting.type == PluginSettingType.color ? Mx.mono : null),
    onChanged: _typed,
    decoration: InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12),
      errorText: _invalid ? '' : null,
      errorStyle: const TextStyle(height: 0, fontSize: 0),
      border: const OutlineInputBorder(),
    ),
  );

  Widget _color() {
    final color = pluginColor(_text.text) ?? Mx.fgFaint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final hex in _presets)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              onTap: () => widget.onChanged(hex),
              borderRadius: BorderRadius.circular(4),
              child: Tooltip(
                message: hex,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: parseHexColor(hex),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(width: 6),
        // A amostra: a cor como ela vai sair no console, num pedaço de log.
        Container(
          width: 64,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: Mx.canvas,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: Mx.border),
          ),
          child: Text(
            'Aa log',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: color),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(width: 96, child: _input(hint: 'Do tema')),
      ],
    );
  }
}
