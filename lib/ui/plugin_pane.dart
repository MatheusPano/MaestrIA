import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/plugins.dart';
import '../services/store.dart';
import '../theme.dart';
import 'doc_pane.dart';
import 'menus.dart';
import 'panel.dart';
import 'plugin_dialogs.dart';
import 'plugin_rfw.dart';
import 'terminal_pane.dart';

/// Os desenhos que um plugin pode pedir, pelo nome: nos blocos (`icon` de
/// botão e de item de lista) e nos botões de comando da lateral.
IconData? pluginIcon(Object? name) => switch (name) {
  'check' => Icons.check_circle_outline,
  'error' => Icons.error_outline,
  'warning' => Icons.warning_amber_outlined,
  'info' => Icons.info_outline,
  'file' => Icons.description_outlined,
  'folder' => Icons.folder_outlined,
  'play' => Icons.play_arrow,
  'terminal' => Icons.terminal,
  'link' => Icons.link,
  'star' => Icons.star_outline,
  'clock' => Icons.schedule,
  'user' => Icons.person_outline,
  'task' => Icons.task_alt,
  // A barra de depuração, na ordem em que o VS Code a desenha.
  'continue' => Icons.play_arrow_rounded,
  'pause' => Icons.pause_rounded,
  'step-over' => Icons.redo_rounded,
  'step-into' => Icons.south_rounded,
  'step-out' => Icons.north_rounded,
  'reload' => Icons.bolt_rounded,
  'restart' => Icons.replay_rounded,
  'stop' => Icons.stop_rounded,
  'devtools' => Icons.travel_explore_rounded,
  'bug' => Icons.bug_report_outlined,
  'device' => Icons.smartphone_outlined,
  'refresh' => Icons.refresh_rounded,
  'clear' => Icons.block_rounded,
  'copy' => Icons.copy_rounded,
  'search' => Icons.search_rounded,
  'settings' => Icons.settings_outlined,
  'calendar' => Icons.calendar_today_outlined,
  'report' => Icons.summarize_outlined,
  'receipt' => Icons.receipt_long_outlined,
  'open' => Icons.open_in_new_rounded,
  'add' => Icons.add_rounded,
  'remove' => Icons.remove_rounded,
  'undo' => Icons.undo_rounded,
  // Os do controle de código e das conexões, que a aba do git e a do ssh
  // pedem.
  'branch' => Icons.alt_route_rounded,
  'commit' => Icons.commit_rounded,
  'push' => Icons.upload_rounded,
  'pull' => Icons.download_rounded,
  'sync' => Icons.sync_rounded,
  'server' => Icons.dns_outlined,
  'edit' => Icons.edit_outlined,
  'dot' => Icons.circle,
  // Os de containers, que a aba do docker pede: a caixa, a pilha do compose,
  // a imagem, o disco de um volume.
  'box' => Icons.inventory_2_outlined,
  'stack' => Icons.layers_outlined,
  'image' => Icons.album_outlined,
  'drive' => Icons.storage_rounded,
  'network' => Icons.lan_outlined,
  'cpu' => Icons.memory_rounded,
  'trash' => Icons.delete_outline_rounded,
  'globe' => Icons.public_rounded,
  'more' => Icons.more_horiz_rounded,
  'chevron' => Icons.chevron_right_rounded,
  'filter' => Icons.filter_list_rounded,
  'layers' => Icons.layers_outlined,
  _ => null,
};

/// O menu de botão direito de um plugin (`menu` de um item de lista ou de um
/// botão): as linhas, os traços e a cor de cada uma.
Future<void> _pluginMenu(
  BuildContext context,
  List<Map<String, dynamic>> menu,
  Offset at,
  void Function(String action) onAction,
) async {
  final choice = await mxMenu<String>(
    context,
    at: at,
    items: [
      for (final m in menu)
        if (m['type'] == 'divider')
          mxDivider()
        else if (m['children'] case final List children)
          // Um submenu: `children: [{ action, label, tone? }]` -- a paleta de cores.
          MxSubmenuItem(
            label: (m['label'] as String?) ?? '',
            glyph: switch (pluginIcon(m['icon'])) {
              final IconData icon => Icon(icon, size: 14, color: Mx.fgDim),
              _ => null,
            },
            items: () => [
              for (final c in PluginView.blocksFrom(children))
                if (c['action'] case final String action)
                  MxSubItem(
                    value: action,
                    label: (c['label'] as String?) ?? action,
                    glyph: colorDot(
                      c['tone'] == null || c['tone'] == '' ? null : _PluginPaneState._tone(c['tone']),
                    ),
                  ),
            ],
          )
        else if (m['action'] case final String action)
          mxItem(
            action,
            label: (m['label'] as String?) ?? action,
            enabled: m['disabled'] != true,
            color: m['tone'] == null ? null : _PluginPaneState._tone(m['tone']),
            glyph: switch (pluginIcon(m['icon'])) {
              final IconData icon => Icon(
                icon,
                size: 14,
                color: m['tone'] == null ? Mx.fgDim : _PluginPaneState._tone(m['tone']),
              ),
              _ => null,
            },
          ),
    ],
  );
  if (choice != null) onAction(choice);
}

/// A bolinha de uma cor num menu (a paleta do "Cor ▸"); sem cor, só o
/// contorno -- a "automática".
Widget colorDot(Color? color) => Container(
  width: 11,
  height: 11,
  decoration: BoxDecoration(
    color: color,
    shape: BoxShape.circle,
    border: color == null ? Border.all(color: Mx.fgFaint, width: 1.4) : null,
  ),
);

/// O quadrado arredondado e colorido na frente de uma linha (`avatar`), o
/// ícone de app do OrbStack: o desenho na cor, sobre a mesma cor bem clara.
/// Apagado (`dim`) ele fica cinza -- o container parado ao lado dos que rodam.
///
/// `status` é a bolinha no canto de baixo, com um anel da cor do fundo pra
/// descolar do quadrado: no ar, subindo, caído.
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.spec,
    required this.dir,
    required this.size,
    required this.ring,
    this.dim = false,
    this.status,
  });

  /// Um nome de ícone (ou `.svg` da pasta do plugin), ou `{ icon?, text?, color?,
  /// svg?, shape?, plain? }`. `svg` é um desenho inteiro, com as cores dele --
  /// o cubo colorido de um container --, e aí não há caixa em volta.
  final Object? spec;
  final String? dir;
  final double size;
  final Color ring;
  final bool dim;
  final Object? status;

  @override
  Widget build(BuildContext context) {
    final map = spec is Map
        ? (spec as Map).cast<String, dynamic>()
        : <String, dynamic>{'icon': spec};
    final base = map['color'] == null ? Mx.accent : _PluginPaneState._tone(map['color']);
    final color = dim ? Mx.fgFaint : base;
    final text = map['text'] as String?;
    final circle = map['shape'] == 'circle';
    final Widget box;
    if (map['svg'] case final String svg) {
      // O desenho é o avatar inteiro: sem caixa, sem tinta. Apagado fica meio
      // transparente em vez de cinza -- cinza é jogar fora as cores dele.
      final picture = SvgPicture.string(svg, width: size, height: size, excludeFromSemantics: true);
      box = SizedBox(
        width: size,
        height: size,
        child: dim ? Opacity(opacity: 0.7, child: picture) : picture,
      );
    } else if (map['plain'] == true) {
      box = SizedBox(
        width: size,
        height: size,
        child: Center(
          child: PluginGlyph(
            icon: map['icon'] as String?,
            dir: dir,
            size: size * 0.8,
            color: color,
          ),
        ),
      );
    } else {
      box = _box(color, text, map, circle);
    }
    if (status == null) return box;
    final dot = size < 32 ? 9.0 : 11.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          box,
          Positioned(
            right: circle || map['svg'] != null ? -1 : -2.5,
            bottom: circle || map['svg'] != null ? -1 : -2.5,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: _PluginPaneState._tone(status),
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _box(Color color, String? text, Map<String, dynamic> map, bool circle) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dim ? 0.10 : 0.17),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(size * 0.28),
        border: Border.all(color: color.withValues(alpha: dim ? 0.14 : 0.26)),
      ),
      alignment: Alignment.center,
      child: text != null
          ? Text(
              text,
              style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700, color: color),
            )
          : PluginGlyph(icon: map['icon'] as String?, dir: dir, size: size * 0.56, color: color),
    );
  }
}

/// O desenho que um plugin pediu: um nome de [pluginIcon], ou um `.svg` da
/// pasta dele -- que é como o Flutter tem o próprio logo, e não um parecido.
///
/// O svg é pintado de uma cor só, como os [MxIcon] do app: na faixa da
/// lateral todos os glifos têm o mesmo traço e a mesma cor, e um logo colorido
/// no meio deles leria como um adesivo.
class PluginGlyph extends StatelessWidget {
  const PluginGlyph({super.key, this.icon, this.dir, this.size = 18, this.color});

  final String? icon;

  /// A pasta do plugin, de onde um `.svg` é lido.
  final String? dir;
  final double size;
  final Color? color;

  /// O arquivo do svg, se [icon] for um e ele estiver dentro da pasta do
  /// plugin -- um `../../` no manifesto não sai dela.
  static File? svgOf(String? icon, String? dir) {
    if (icon == null || dir == null || !icon.toLowerCase().endsWith('.svg')) return null;
    final file = File('$dir/$icon').absolute;
    final root = Directory(dir).absolute.path;
    if (!file.path.startsWith(root) || icon.contains('..')) return null;
    return file.existsSync() ? file : null;
  }

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Mx.fgDim;
    if (svgOf(icon, dir) case final file?) {
      return SvgPicture.file(
        file,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
        excludeFromSemantics: true,
      );
    }
    return Icon(pluginIcon(icon) ?? Icons.extension_outlined, size: size, color: tint);
  }
}

/// Uma janela de plugin: os blocos que ele mandou, desenhados com o tema.
///
/// Um painel como o leitor -- mesma moldura, mesmo cabeçalho, arrastável pela
/// lateral --, e o miolo é uma lista de blocos json em vez de markdown. Ver
/// [PluginView] pro porquê de blocos e não webview.
///
/// Os campos guardam o que você digitou aqui, e não no plugin: é o painel que
/// sabe o que está escrito, e o plugin recebe tudo de uma vez quando um botão
/// é clicado (`view.action`, com `values`). Um campo que continua com o mesmo
/// `id` depois de um `view.update` mantém o texto -- o plugin que atualiza um
/// contador não pode apagar o que você estava escrevendo embaixo dele.
class PluginPane extends StatefulWidget {
  const PluginPane({
    super.key,
    required this.store,
    required this.tab,
    this.focused = true,
    this.showFocus = false,
    this.onFocus,
    this.bare = false,
  });

  final AppStore store;
  final MxTab tab;
  final bool focused;
  final bool showFocus;
  final VoidCallback? onFocus;

  /// Só os blocos, sem a moldura nem o cabeçalho de painel: a aba que o
  /// plugin desenha na lateral (`sidebar.update`). Mais apertado e numa letra
  /// um passo menor, que é o corpo da lateral -- os blocos são os mesmos.
  final bool bare;

  @override
  State<PluginPane> createState() => _PluginPaneState();
}

class _PluginPaneState extends State<PluginPane> {
  final ScrollController _scroll = ScrollController();
  final Map<String, TextEditingController> _fields = {};

  /// O `value` que cada campo trazia da última vez que o plugin o mandou. Só
  /// quando ele muda o texto na tela é trocado -- ver a nota da classe.
  final Map<String, Object?> _sent = {};
  final Map<String, Object?> _picks = {};

  PluginView get _view => widget.tab.view!;

  static const _same = DeepCollectionEquality();

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// O que os campos têm agora, pros testes.
  @visibleForTesting
  Map<String, dynamic> get debugValues => _values;

  /// Tudo que está preenchido, como o plugin recebe.
  Map<String, dynamic> get _values => {
    for (final e in _fields.entries) e.key: e.value.text,
    ..._picks,
  };

  void _act(String action) => widget.store.pluginViewAction(widget.tab, action, _values);

  /// Acerta os campos com os blocos da vez: cria os novos, atualiza o texto
  /// dos que o plugin mudou, e solta os que sumiram.
  void _sync() {
    final seen = <String>{};
    void visit(List<Map<String, dynamic>> blocks) {
      for (final b in blocks) {
        final id = b['id'];
        switch (b['type']) {
          case 'input' when id is String:
            seen.add(id);
            final value = b['value'] is String ? b['value'] as String : '';
            final field = _fields.putIfAbsent(id, () => TextEditingController(text: value));
            if (_sent.containsKey(id) && _sent[id] != value) field.text = value;
            _sent[id] = value;
          case 'checkbox' || 'select' || 'calendar' when id is String:
            seen.add(id);
            final value = b['value'];
            // Por conteúdo: o período de um calendário é um objeto que chega
            // novo a cada `view.update`, e por referência ele pareceria sempre
            // mudado -- apagando a escolha a cada redesenho do plugin.
            if (!_picks.containsKey(id) || !_same.equals(_sent[id], value)) _picks[id] = value;
            _sent[id] = value;
          case 'row' || 'card' || 'columns':
            visit(PluginView.blocksFrom(b['children']));
        }
      }
    }

    visit(_view.blocks);
    for (final gone in _fields.keys.where((k) => !seen.contains(k)).toList()) {
      _fields.remove(gone)!.dispose();
    }
    _picks.removeWhere((k, _) => !seen.contains(k));
    _sent.removeWhere((k, _) => !seen.contains(k));
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final plugin = widget.store.plugins.byId(_view.pluginId);
    final down = plugin == null || plugin.state == PluginState.crashed;
    if (widget.bare) {
      return Column(
        children: [
          if (down)
            _Stopped(
              why: plugin?.crash ?? 'O plugin não está mais instalado',
              onRestart: plugin == null ? null : () => widget.store.plugins.restart(plugin),
            ),
          Expanded(
            child:
                _rfw() ??
                _expanding() ??
                Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final b in _view.blocks) _block(b)],
                    ),
                  ),
                ),
          ),
        ],
      );
    }
    return Listener(
      onPointerDown: (_) => widget.onFocus?.call(),
      child: MxPanel(
        focused: widget.focused,
        showFocus: widget.showFocus,
        tint: widget.store.tintOf(widget.tab),
        child: Column(
          children: [
            _Header(
              store: widget.store,
              tab: widget.tab,
              dimmed: widget.showFocus && !widget.focused,
            ),
            if (down)
              _Stopped(
                why: plugin?.crash ?? 'O plugin não está mais instalado',
                onRestart: plugin == null ? null : () => widget.store.plugins.restart(plugin),
              ),
            Expanded(
              child:
                  _rfw() ??
                  _expanding() ??
                  (_view.blocks.isEmpty
                      ? Center(
                          child: Text(
                            'Nada pra mostrar ainda',
                            style: TextStyle(fontSize: 13, color: Mx.fgFaint),
                          ),
                        )
                      : Scrollbar(
                          controller: _scroll,
                          child: SingleChildScrollView(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 760),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [for (final b in _view.blocks) _block(b)],
                                ),
                              ),
                            ),
                          ),
                        )),
            ),
          ],
        ),
      ),
    );
  }

  double get _size => MxMarkdown.baseSize + widget.tab.zoom - (widget.bare ? 1 : 0);

  /// A interface que o plugin montou ele mesmo, no lugar dos blocos. Ver
  /// [PluginRfw].
  Widget? _rfw() => _view.rfwLibrary == null ? null : PluginRfw(store: widget.store, tab: widget.tab);

  /// A cor de baixo do bloco que está sendo desenhado: a da lateral, a do
  /// painel, ou a de um `card`. É dela o anel da bolinha de um avatar, e o
  /// `card` a troca enquanto desenha os filhos.
  Color? _surfaceNow;
  Color get _surface => _surfaceNow ?? (widget.bare ? Mx.bgSidebar : Mx.bg);

  /// A pasta do plugin, de onde um `.svg` de avatar é lido.
  String? get _pluginDir => widget.store.plugins.byId(_view.pluginId)?.dir;

  /// A janela com um console que ocupa a altura que sobra -- o `expand` de
  /// um bloco `console`. É o desenho do debug console do VS Code: a barra e
  /// os seletores em cima, fixos, e o log embaixo até o fim do painel. Sem
  /// rolagem da janela inteira, que levaria a barra embora junto com o log.
  ///
  /// Null quando nenhum bloco pede isso, e aí vale a coluna que rola.
  Widget? _expanding() {
    final at = _view.blocks.indexWhere(
      (b) => (b['type'] == 'console' || b['type'] == 'terminal') && b['expand'] == true,
    );
    if (at < 0) return null;
    Widget column(Iterable<Map<String, dynamic>> blocks) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final b in blocks) _block(b)],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          column(_view.blocks.take(at)),
          Expanded(
            child: _view.blocks[at]['type'] == 'terminal'
                ? _terminal(_view.blocks[at], fill: true)
                : _console(_view.blocks[at], fill: true),
          ),
          if (at + 1 < _view.blocks.length) ...[
            const SizedBox(height: 12),
            column(_view.blocks.skip(at + 1)),
          ],
        ],
      ),
    );
  }

  /// Um bloco. O tipo que esta versão não conhece vira uma linha apagada
  /// dizendo isso, em vez de sumir: quem escreveu o plugin precisa ver que
  /// mandou algo que não foi desenhado.
  Widget _block(Map<String, dynamic> b, {bool last = false}) {
    final text = b['text'] is String ? b['text'] as String : '';
    final child = switch (b['type']) {
      'heading' => Text(
        text,
        style: TextStyle(fontSize: _size + 3, fontWeight: FontWeight.w600, color: Mx.fg),
      ),
      'text' => SelectableText(
        text,
        style: _textStyle(b['style']),
        textAlign: b['align'] == 'center' ? TextAlign.center : TextAlign.start,
      ),
      'markdown' => MxMarkdown(
        data: text,
        fontSize: _size,
        onFollow: (href) {
          if (href != null) widget.store.followLink(href, from: widget.tab);
        },
      ),
      'code' => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Mx.bgActive,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Mx.border),
        ),
        child: SelectableText(
          text,
          style: TextStyle(fontFamily: Mx.mono, fontSize: _size - 1.7, height: 1.5, color: Mx.fg),
        ),
      ),
      'divider' => Divider(height: 1, color: Mx.border),
      'section' => _section(b),
      'button' => Align(alignment: Alignment.centerLeft, child: _button(b)),
      'row' => Wrap(
        alignment: switch (b['align']) {
          'center' => WrapAlignment.center,
          'end' => WrapAlignment.end,
          'between' => WrapAlignment.spaceBetween,
          _ => WrapAlignment.start,
        },
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Um campo numa fileira não tem largura de onde tirar -- o Wrap dá
          // a cada filho o espaço que ele pedir, e um TextField pede infinito.
          // Então quem não é botão ganha uma, `width` ou 240.
          for (final c in PluginView.blocksFrom(b['children']))
            c['type'] == 'button'
                ? _button(c)
                : SizedBox(width: (c['width'] as num?)?.toDouble() ?? 240, child: _block(c)),
        ],
      ),
      'input' => _input(b),
      'checkbox' => _checkbox(b),
      'select' => _select(b),
      'list' => _list(b),
      'kv' => _kv(b),
      'progress' => _progress(b),
      'console' => _console(b),
      'calendar' => _calendar(b),
      'header' => _header(b),
      'card' => _card(b),
      'tabs' => _tabs(b),
      'columns' => _columns(b),
      'terminal' => _terminal(b),
      final other => Text(
        'Bloco desconhecido: ${other ?? '(sem "type")'}',
        style: TextStyle(fontSize: 11.5, fontFamily: Mx.mono, color: Mx.fgFaint),
      ),
    };
    if (last) return child;
    return Padding(
      padding: EdgeInsets.only(bottom: widget.bare ? 10 : 12),
      child: child,
    );
  }

  /// O cabeçalho de uma lista ou de uma janela: o avatar, o título grande, uma
  /// linha embaixo e os botões de ícone à direita -- "Containers" com o
  /// buscar e o + do OrbStack, ou o nome do container com parar e reiniciar.
  Widget _header(Map<String, dynamic> b) {
    final subtitle = b['subtitle'] as String?;
    final avatarSize = widget.bare ? 30.0 : 40.0;
    return Row(
      children: [
        if (b['avatar'] != null) ...[
          _Avatar(
            spec: b['avatar'],
            dir: _pluginDir,
            size: avatarSize,
            ring: _surface,
            dim: b['dim'] == true,
            status: b['status'],
          ),
          SizedBox(width: widget.bare ? 10 : 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                (b['title'] as String?) ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _size + (widget.bare ? 2.5 : 5),
                  fontWeight: FontWeight.w700,
                  color: Mx.fg,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _size - 1.5,
                    color: b['tone'] == null ? Mx.fgDim : _tone(b['tone']),
                  ),
                ),
              ],
            ],
          ),
        ),
        for (final a in PluginView.blocksFrom(b['actions'])) _button({...a, 'style': 'icon'}),
      ],
    );
  }

  /// Uma caixa arredondada, um passo acima do fundo, com blocos dentro: a
  /// lista de containers como um cartão, as informações de um deles.
  Widget _card(Map<String, dynamic> b) {
    final saved = _surfaceNow;
    final color = Color.alphaBlend(
      Mx.fg.withValues(alpha: Mx.palette.dark ? 0.035 : 0.025),
      _surface,
    );
    _surfaceNow = color;
    final children = PluginView.blocksFrom(b['children']);
    final body = [
      for (var i = 0; i < children.length; i++) _block(children[i], last: i == children.length - 1),
    ];
    _surfaceNow = saved;
    final pad = (b['padding'] as num?)?.toDouble() ?? (widget.bare ? 6 : 12);
    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Mx.radius),
        border: Border.all(color: Mx.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
    );
  }

  /// As abas de uma janela, num controle segmentado: `items: [{ label,
  /// action, active?, count? }]`. Quem sabe qual está ativa é o plugin.
  Widget _tabs(Map<String, dynamic> b) {
    final items = PluginView.blocksFrom(b['items']);
    return Align(
      alignment: b['align'] == 'center' ? Alignment.center : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Mx.bgActive.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in items)
              _TabChip(
                label: (it['label'] as String?) ?? '',
                count: it['count'] == null ? null : '${it['count']}',
                icon: pluginIcon(it['icon']),
                active: it['active'] == true,
                size: _size,
                onTap: switch (_actionOf(it)) {
                  final String a => () => _act(a),
                  _ => null,
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Blocos lado a lado, cada um com a mesma largura: os medidores de CPU e
  /// memória de um container.
  Widget _columns(Map<String, dynamic> b) {
    final children = PluginView.blocksFrom(b['children']);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: _block(children[i], last: true)),
        ],
      ],
    );
  }

  TextStyle _textStyle(Object? style) {
    final base = TextStyle(fontSize: _size, height: 1.5, color: Mx.fg);
    return switch (style) {
      'dim' => base.copyWith(color: Mx.fgDim),
      'faint' => base.copyWith(color: Mx.fgFaint, fontSize: _size - 1),
      'mono' => base.copyWith(fontFamily: Mx.mono, fontSize: _size - 1.5),
      'error' => base.copyWith(color: Mx.red),
      'success' => base.copyWith(color: Mx.green),
      'warning' => base.copyWith(color: Mx.yellow),
      _ => base,
    };
  }

  /// A ação de um bloco clicável: `action`, e `id` pra quem escreveu o botão
  /// como se fosse um campo.
  static String? _actionOf(Map<String, dynamic> b) =>
      (b['action'] ?? b['id']) is String ? (b['action'] ?? b['id']) as String : null;

  Widget _button(Map<String, dynamic> b) {
    final menu = PluginView.blocksFrom(b['menu']);
    // Com `menu` o botão abre o menu embaixo dele (o "…" de um cabeçalho),
    // em vez de mandar uma ação.
    if (menu.isNotEmpty) {
      return Builder(
        builder: (context) => _buttonWith(b, () {
          final box = context.findRenderObject() as RenderBox?;
          final at = box == null ? Offset.zero : box.localToGlobal(Offset(0, box.size.height + 4));
          _pluginMenu(context, menu, at, _act);
        }),
      );
    }
    final action = _actionOf(b);
    return _buttonWith(b, action == null ? null : () => _act(action));
  }

  Widget _buttonWith(Map<String, dynamic> b, VoidCallback? tap) {
    final action = _actionOf(b);
    final onPressed = b['disabled'] == true ? null : tap;
    final icon = pluginIcon(b['icon']);
    // Só o desenho, sem texto: a barra de depuração do VS Code. O nome vai
    // pro tooltip, que é onde uma barra de ícones diz o que cada um faz.
    if (icon != null && (b['style'] == 'icon' || b['label'] == null)) {
      final tone = b['tone'] == null ? Mx.fgDim : _tone(b['tone']);
      return IconButton(
        tooltip: (b['tooltip'] ?? b['label']) as String?,
        iconSize: 17,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        onPressed: onPressed,
        icon: Icon(icon, color: onPressed == null ? Mx.fgFaint.withValues(alpha: 0.5) : tone),
      );
    }
    final label = (b['label'] as String?) ?? action ?? 'ok';
    if (icon != null) {
      final glyph = Icon(icon, size: 15);
      return switch (b['style']) {
        'primary' => FilledButton.icon(onPressed: onPressed, icon: glyph, label: Text(label)),
        _ => OutlinedButton.icon(onPressed: onPressed, icon: glyph, label: Text(label)),
      };
    }
    return switch (b['style']) {
      'primary' => FilledButton(onPressed: onPressed, child: Text(label)),
      'danger' => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: Mx.red,
          side: BorderSide(color: Mx.red.withValues(alpha: 0.6)),
        ),
        child: Text(label),
      ),
      _ => OutlinedButton(onPressed: onPressed, child: Text(label)),
    };
  }

  Widget _input(Map<String, dynamic> b) {
    final id = b['id'];
    if (id is! String) return _broken('input sem "id"');
    final multiline = b['multiline'] == true;
    final submit = b['submit'] is String ? b['submit'] as String : null;
    return TextField(
      controller: _fields[id],
      enabled: b['disabled'] != true,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 12 : 1,
      style: TextStyle(fontSize: _size - 0.5, color: Mx.fg),
      onSubmitted: multiline || submit == null ? null : (_) => _act(submit),
      decoration: InputDecoration(
        labelText: b['label'] as String?,
        hintText: b['placeholder'] as String?,
        isDense: true,
        labelStyle: TextStyle(color: Mx.fgDim, fontSize: 12),
        hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12.5),
        border: _fieldBorder,
        prefixIcon: switch (pluginIcon(b['icon'])) {
          final IconData icon => Icon(icon, size: 16, color: Mx.fgFaint),
          _ => null,
        },
        prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 20),
      ),
    );
  }

  /// O contorno dos campos (`input` e `select`): o canto de 4 do Material,
  /// ao lado dos botões e painéis arredondados, lia como quadrado.
  static const _fieldBorder = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(7)));

  Widget _checkbox(Map<String, dynamic> b) {
    final id = b['id'];
    if (id is! String) return _broken('checkbox sem "id"');
    final on = _picks[id] == true;
    final action = b['action'] is String ? b['action'] as String : null;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: b['disabled'] == true
          ? null
          : () {
              setState(() => _picks[id] = !on);
              if (action != null) _act(action);
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            on ? Icons.check_box : Icons.check_box_outline_blank,
            size: 18,
            color: on ? Mx.accent : Mx.fgDim,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              (b['label'] as String?) ?? id,
              style: TextStyle(fontSize: _size - 0.5, color: Mx.fg),
            ),
          ),
        ],
      ),
    );
  }

  Widget _select(Map<String, dynamic> b) {
    final id = b['id'];
    if (id is! String) return _broken('select sem "id"');
    // Valor vazio é uma opção como outra: "aparelho automático" é o `""` do
    // seletor de aparelho. Só o que não é opção nenhuma fica de fora.
    final options = <(String, String)>[
      for (final o in (b['options'] as List? ?? const []))
        if (switch (o) {
              final String v => (v, v),
              {'value': final String v, 'label': final String l} => (v, l),
              {'value': final String v} => (v, v),
              _ => null,
            }
            case final option?)
          option,
    ];
    final current = options.any((o) => o.$1 == _picks[id]) ? _picks[id] as String : null;
    final action = b['action'] is String ? b['action'] as String : null;
    // Procurando -- os aparelhos do `flutter devices`, que levam segundos: o
    // campo diz isso e fica travado até a lista chegar.
    final loading = b['loading'] == true;
    final placeholder = b['placeholder'] as String?;
    return DropdownButtonFormField<String>(
      // O campo só lê o valor na hora de nascer. A chave com o valor e as
      // opções faz ele renascer quando o plugin manda outros -- a lista de
      // aparelhos que chegou, a configuração trocada por fora.
      key: ValueKey('$id|$current|${options.map((o) => o.$1).join(',')}|$loading'),
      initialValue: current,
      isDense: true,
      // Sem isto o seletor cresce até o texto mais longo e estoura a largura
      // que a fileira deu: "sdk gphone64 arm64 · android-arm64" num campo de
      // 230. Expandido, o texto é que se ajusta ao campo -- com reticências.
      isExpanded: true,
      // O menu no desenho dos menus de contexto (`popupMenuTheme`): o canto
      // dos painéis, um passo acima do fundo e a sombra de coisa que flutua.
      // A altura tem teto: sem ele o menu do Material vai até a borda da
      // janela -- a lista de configurações de um launch.json com uma dúzia de
      // flavors cobria a tela inteira. Passou disso, rola.
      dropdownColor: Mx.bgActive,
      borderRadius: BorderRadius.circular(Mx.radius),
      elevation: 12,
      menuMaxHeight: 320,
      style: TextStyle(fontSize: _size - 0.5, color: Mx.fg),
      hint: placeholder == null
          ? null
          : Text(
              placeholder,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Mx.fgFaint),
            ),
      disabledHint: loading || placeholder != null
          ? Text(
              current == null ? (placeholder ?? '') : options.firstWhere((o) => o.$1 == current).$2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: loading ? Mx.fgDim : Mx.fgFaint),
            )
          : null,
      icon: loading
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: Mx.fgDim),
            )
          : null,
      decoration: InputDecoration(
        labelText: b['label'] as String?,
        isDense: true,
        labelStyle: TextStyle(color: Mx.fgDim, fontSize: 12),
        border: _fieldBorder,
      ),
      items: [
        for (final (value, label) in options)
          DropdownMenuItem(
            value: value,
            child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1),
          ),
      ],
      // Travado é o seletor de configuração do VS Code com o app rodando:
      // trocar ali não mudaria o que já subiu.
      onChanged: b['disabled'] == true || loading
          ? null
          : (v) {
              setState(() => _picks[id] = v);
              if (action != null) _act(action);
            },
    );
  }

  /// A cor de um `tone`: um nome do tema, ou um hex (`#4FC1FF`) -- que é como
  /// uma configuração de cor de plugin chega até aqui.
  static Color _tone(Object? tone) => switch (tone) {
    final String hex when hex.startsWith('#') => parseHexColor(hex) ?? Mx.fgDim,
    'green' || 'success' => Mx.green,
    'red' || 'error' => Mx.red,
    'yellow' || 'warning' => Mx.yellow,
    'accent' => Mx.accent,
    'purple' => Mx.purple,
    'faint' => Mx.fgFaint,
    // As do terminal, pra quem precisa de mais cores que as do estado: os
    // avatares de uma lista de containers, um por imagem.
    'blue' => Mx.palette.ansi.blue,
    'cyan' => Mx.palette.ansi.cyan,
    'magenta' => Mx.palette.ansi.magenta,
    'white' => Mx.fg,
    'black' => Mx.fgFaint,
    _ => Mx.fgDim,
  };

  /// A régua da lateral -- uma palavra, um traço e um número --, pra aba que
  /// o plugin desenha se ler como as seções das sessões.
  ///
  /// Com `collapsed` (true ou false) ela ganha a seta dos workspaces e o
  /// clique manda a `action`: quem esconde o que está embaixo é o plugin, que
  /// deixa de mandar os blocos da seção fechada.
  Widget _section(Map<String, dynamic> b) {
    // `style: "label"`: só a palavra, sem traço -- o "Stopped" da lista do
    // OrbStack, que separa os parados sem riscar a lista no meio.
    if (b['style'] == 'label') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
        child: Text(
          (b['text'] as String?) ?? '',
          style: TextStyle(fontSize: _size - 1.5, fontWeight: FontWeight.w600, color: Mx.fgFaint),
        ),
      );
    }
    final count = b['count'];
    final collapsed = b['collapsed'];
    final action = _actionOf(b);
    final toggles = collapsed is bool;
    final rule = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          if (toggles) ...[
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 14,
              color: Mx.fgFaint,
            ),
            const SizedBox(width: 2),
          ],
          Text(
            (b['text'] as String?) ?? '',
            style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, letterSpacing: 0.5),
          ),
          const SizedBox(width: 9),
          Expanded(child: Container(height: 1, color: Mx.border)),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text('$count', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
          ],
        ],
      ),
    );
    if (action == null) return rule;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _act(action),
        child: rule,
      ),
    );
  }

  Widget _list(Map<String, dynamic> b) {
    final items = PluginView.blocksFrom(b['items']);
    if (items.isEmpty) {
      return Text(
        (b['empty'] as String?) ?? 'Nada aqui',
        style: TextStyle(fontSize: _size - 1, color: Mx.fgFaint),
      );
    }
    // Uma árvore: com alguma linha de seta (`expanded`), as sem seta guardam
    // o lugar dela, e os avatares do mesmo nível ficam numa coluna só.
    final tree = items.any((i) => i['expanded'] is bool);
    // Sem moldura nem traço entre as linhas: a lista de uma aba da lateral,
    // que se lê como as linhas das sessões e não como um cartão.
    if (b['flat'] == true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            _ListRow(
              item: item,
              icon: pluginIcon(item['icon']),
              tone: _tone(item['tone']),
              size: _size,
              dir: _pluginDir,
              surface: _surface,
              tree: tree,
              alwaysActions: b['alwaysActions'] == true,
              flat: true,
              onTap: switch (_actionOf(item)) {
                final String a => () => _act(a),
                _ => null,
              },
              onAction: _act,
            ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: 1, color: Mx.border),
            _ListRow(
              item: items[i],
              icon: pluginIcon(items[i]['icon']),
              tone: _tone(items[i]['tone']),
              size: _size,
              dir: _pluginDir,
              surface: _surface,
              tree: tree,
              alwaysActions: b['alwaysActions'] == true,
              onTap: switch (_actionOf(items[i])) {
                final String a => () => _act(a),
                _ => null,
              },
              onAction: _act,
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(Map<String, dynamic> b) {
    final items = PluginView.blocksFrom(b['items']);
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final it in items)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 6),
                child: Text(
                  '${it['key'] ?? ''}',
                  style: TextStyle(fontSize: _size - 1, color: Mx.fgDim),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SelectableText(
                  '${it['value'] ?? ''}',
                  style: TextStyle(
                    fontSize: _size - 1,
                    color: it['tone'] == null ? Mx.fg : _tone(it['tone']),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// A barra: sem `value` ela corre (indeterminada). `detail` é o número à
  /// direita do rótulo -- "12% de 8 núcleos" --, e `tone` a cor da barra.
  Widget _progress(Map<String, dynamic> b) {
    final value = (b['value'] as num?)?.toDouble().clamp(0.0, 1.0);
    final label = b['label'] as String?;
    final detail = b['detail'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null || detail != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: _size - 1, color: Mx.fgDim),
                ),
              ),
              if (detail != null)
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: _size - 1,
                    color: Mx.fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 5,
            color: b['tone'] == null ? Mx.accent : _tone(b['tone']),
            backgroundColor: Mx.bgActive,
          ),
        ),
      ],
    );
  }

  Widget _calendar(Map<String, dynamic> b) {
    final id = b['id'];
    if (id is! String) return _broken('calendar sem "id"');
    final range = b['mode'] == 'range';
    final value = _picks[id];
    DateTime? day(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final (from, to) = switch (value) {
      {'from': final f, 'to': final t} => (day(f), day(t)),
      final String s => (day(s), day(s)),
      _ => (null, null),
    };
    DateTime? bound(Object? v) {
      if (v == 'today') {
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day);
      }
      return day(v);
    }

    final action = b['action'] is String ? b['action'] as String : null;
    final presets = [
      for (final p in PluginView.blocksFrom(b['presets']))
        if ((day(p['from']), day(p['to'] ?? p['from'])) case (final DateTime f, final DateTime t))
          (label: (p['label'] as String?) ?? _ymd(f), from: f, to: t),
    ];
    // Centrado: é o objeto principal de quem o usa, e o cartão tem largura
    // própria -- encostado à esquerda ele deixava meio painel vazio do lado.
    return Center(
      child: PluginCalendar(
        range: range,
        from: from,
        to: to,
        min: bound(b['min']),
        max: bound(b['max']),
        presets: presets,
        onChanged: (f, t) {
          setState(() => _picks[id] = range ? {'from': _ymd(f), 'to': _ymd(t)} : _ymd(f));
          if (action != null) _act(action);
        },
      ),
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _console(Map<String, dynamic> b, {bool fill = false}) {
    final id = b['id'];
    if (id is! String) return _broken('console sem "id"');
    final box = _Console(
      console: _view.console(id),
      size: _size,
      tone: _tone,
      empty: (b['empty'] as String?) ?? 'Nada no console ainda',
      follow: b['follow'] != false,
    );
    if (fill) return box;
    return SizedBox(height: (b['height'] as num?)?.toDouble() ?? 320, child: box);
  }

  /// Um terminal de verdade dentro da janela: a sessão que o plugin abriu com
  /// `session.openShell({ embedded: true })`, pelo `tabId` que voltou. Só as
  /// dele -- um plugin não desenha o terminal de outra pessoa na janela dele.
  Widget _terminal(Map<String, dynamic> b, {bool fill = false}) {
    final id = b['tabId'];
    final tab = widget.store.tabs.firstWhereOrNull(
      (t) => t.id == id && t.owner == _view.pluginId && t.embedded,
    );
    final box = Container(
      decoration: BoxDecoration(
        color: Mx.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: tab == null
          ? Center(
              child: Text(
                (b['empty'] as String?) ?? 'O terminal fechou',
                style: TextStyle(fontSize: 12, color: Mx.fgFaint),
              ),
            )
          : EmbeddedTerminal(
              key: ValueKey(tab.id),
              store: widget.store,
              tab: tab,
              autofocus: b['autofocus'] == true,
            ),
    );
    if (fill) return box;
    return SizedBox(height: (b['height'] as num?)?.toDouble() ?? 360, child: box);
  }

  Widget _broken(String why) => Text(
    why,
    style: TextStyle(fontSize: 11.5, fontFamily: Mx.mono, color: Mx.red),
  );
}

/// O calendário de um bloco `calendar`: um dia, ou um período.
///
/// Um cartão: os atalhos à esquerda ("hoje", "semana passada" -- o que o
/// plugin mandar), o mês à direita e, embaixo, o que está escolhido. É o
/// desenho dos seletores de período que todo mundo já usou, e o que junta as
/// três coisas num objeto só em vez de três soltas pelo painel.
///
/// No período o primeiro clique marca o começo e o segundo o fim -- em
/// qualquer ordem, o mais cedo vira o começo --, e o terceiro recomeça. Entre
/// os dois o ponteiro mostra o período que o segundo clique fecharia. As pontas
/// são círculos e a faixa corre entre elas, arredondando onde a semana quebra.
///
/// Desenhado aqui em vez do `showDatePicker` do Material pelo mesmo motivo do
/// calendário que o relatório tinha antes de virar plugin: aquele fala inglês
/// sem o `flutter_localizations`, e é muito diálogo pra caber num painel.
class PluginCalendar extends StatefulWidget {
  const PluginCalendar({
    super.key,
    required this.range,
    this.from,
    this.to,
    this.min,
    this.max,
    this.presets = const [],
    required this.onChanged,
  });

  final bool range;
  final DateTime? from;
  final DateTime? to;
  final DateTime? min;

  /// O último dia que dá pra escolher -- `"max": "today"` é o de sempre num
  /// relatório: amanhã não teve dia nenhum ainda.
  final DateTime? max;

  /// Os atalhos da coluna da esquerda. O que bate com a escolha fica aceso.
  final List<({String label, DateTime from, DateTime to})> presets;

  /// O dia (num calendário de um dia só, `from == to`) ou o período escolhido.
  final void Function(DateTime from, DateTime to) onChanged;

  @override
  State<PluginCalendar> createState() => _PluginCalendarState();
}

class _PluginCalendarState extends State<PluginCalendar> {
  static const _cell = 38.0;
  static const _initials = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];
  static const _months = [
    'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', //
    'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
  ];
  static const _weekdays = ['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado', 'Domingo'];

  late DateTime _month = _monthOf(widget.to ?? widget.max ?? DateTime.now());

  /// O começo marcado esperando o segundo clique, no modo período.
  DateTime? _anchor;
  DateTime? _hover;

  static DateTime _monthOf(DateTime d) => DateTime(d.year, d.month);
  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _short(DateTime d) => '${_two(d.day)}/${_two(d.month)}';
  static String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  @override
  void didUpdateWidget(PluginCalendar old) {
    super.didUpdateWidget(old);
    // O plugin trocou o período por fora e o mês na tela vai atrás do fim dele.
    if (widget.to != null &&
        (old.to == null || !_sameDay(old.to!, widget.to!)) &&
        _anchor == null) {
      _month = _monthOf(widget.to!);
    }
  }

  bool _off(DateTime d) =>
      (widget.max != null && d.isAfter(widget.max!)) ||
      (widget.min != null && d.isBefore(widget.min!));

  void _tap(DateTime d) {
    if (!widget.range) {
      widget.onChanged(d, d);
      return;
    }
    if (_anchor == null) {
      setState(() => _anchor = d);
      widget.onChanged(d, d);
      return;
    }
    final a = _anchor!;
    setState(() {
      _anchor = null;
      _hover = null;
    });
    d.isBefore(a) ? widget.onChanged(d, a) : widget.onChanged(a, d);
  }

  void _preset(DateTime from, DateTime to) {
    setState(() {
      _anchor = null;
      _hover = null;
      _month = _monthOf(to);
    });
    widget.onChanged(from, to);
  }

  /// O que está escolhido, dito embaixo do mês.
  String _summary() {
    final f = widget.from, t = widget.to;
    if (f == null || t == null) return widget.range ? 'Escolha o primeiro dia' : 'Escolha um dia';
    if (_anchor != null) return 'Começa em ${_short(f)} — clique no último dia';
    if (_sameDay(f, t)) {
      return '${_weekdays[f.weekday - 1]}, ${f.day} de ${_months[f.month - 1]}';
    }
    final days =
        DateTime(t.year, t.month, t.day).difference(DateTime(f.year, f.month, f.day)).inDays + 1;
    return '${_short(f)} a ${_short(t)} · $days dias';
  }

  @override
  Widget build(BuildContext context) {
    final month = _month;
    return LayoutBuilder(
      builder: (context, box) {
        // Largo, os atalhos viram a coluna da esquerda; estreito, uma fileira
        // em cima do mês -- o painel pode estar dividido em quatro.
        final side = widget.presets.isNotEmpty && box.maxWidth >= 470;
        final calendar = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [_header(month), _weekdayRow(), _grid(month)],
        );
        final presets = widget.presets.isEmpty
            ? null
            : (side
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final p in widget.presets) _presetButton(p, stretch: true)],
                    )
                  : Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.center,
                      children: [for (final p in widget.presets) _presetButton(p)],
                    ));
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Mx.border),
          ),
          // Da largura do conteúdo, e não do painel: os fios de separação
          // pediriam a largura toda, e o cartão esticado deixava os atalhos
          // boiando longe do mês.
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (side)
                  IntrinsicHeight(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 148, child: presets),
                        Container(
                          width: 1,
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                          color: Mx.border,
                        ),
                        calendar,
                      ],
                    ),
                  )
                else ...[
                  if (presets != null) ...[presets, const SizedBox(height: 12)],
                  calendar,
                ],
                const SizedBox(height: 10),
                Container(height: 1, color: Mx.border),
                const SizedBox(height: 10),
                Text(
                  _summary(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _anchor != null ? Mx.fgDim : Mx.fg,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _presetButton(({String label, DateTime from, DateTime to}) p, {bool stretch = false}) {
    final on =
        _anchor == null &&
        widget.from != null &&
        widget.to != null &&
        _sameDay(widget.from!, p.from) &&
        _sameDay(widget.to!, p.to);
    return _PresetChip(
      label: p.label,
      on: on,
      stretch: stretch,
      onTap: () => _preset(p.from, p.to),
    );
  }

  Widget _header(DateTime month) {
    final ahead = widget.max == null || _monthOf(widget.max!).isAfter(month);
    final behind = widget.min == null || _monthOf(widget.min!).isBefore(month);
    Widget arrow(IconData icon, VoidCallback? onTap) => IconButton(
      icon: Icon(icon, color: onTap == null ? Mx.fgFaint.withValues(alpha: 0.35) : Mx.fgDim),
      onPressed: onTap,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
    );
    return SizedBox(
      width: _cell * 7,
      child: Row(
        children: [
          arrow(
            Icons.chevron_left_rounded,
            behind ? () => setState(() => _month = DateTime(month.year, month.month - 1)) : null,
          ),
          Expanded(
            child: Center(
              child: Text(
                '${_capitalized(_months[month.month - 1])} de ${month.year}',
                style: TextStyle(fontSize: 13.5, color: Mx.fg, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          arrow(
            Icons.chevron_right_rounded,
            ahead ? () => setState(() => _month = DateTime(month.year, month.month + 1)) : null,
          ),
        ],
      ),
    );
  }

  Widget _weekdayRow() => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final i in _initials)
          SizedBox(
            width: _cell,
            child: Center(
              child: Text(
                i,
                style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    ),
  );

  /// Só as semanas que o mês tem: uma sexta semana vazia embaixo lia como
  /// um buraco no cartão.
  Widget _grid(DateTime month) {
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = month.weekday % 7;
    return MouseRegion(
      onExit: (_) => setState(() => _hover = null),
      child: SizedBox(
        width: _cell * 7,
        child: Wrap(
          children: [
            for (var i = 0; i < ((lead + days + 6) ~/ 7) * 7; i++)
              if (i < lead || i >= lead + days)
                const SizedBox(width: _cell, height: _cell)
              else
                _day(DateTime(month.year, month.month, i - lead + 1), days),
          ],
        ),
      ),
    );
  }

  Widget _day(DateTime d, int monthDays) {
    final now = DateTime.now();
    final today = _sameDay(d, now);
    final off = _off(d);
    // O período na tela: o escolhido, ou -- com o primeiro clique dado -- o que
    // o segundo fecharia até onde o ponteiro está.
    DateTime? from = widget.from, to = widget.to;
    if (_anchor != null) {
      final h = _hover ?? _anchor!;
      from = h.isBefore(_anchor!) ? h : _anchor;
      to = h.isBefore(_anchor!) ? _anchor : h;
    }
    final inside = from != null && to != null && !d.isBefore(from) && !d.isAfter(to);
    final isStart = inside && _sameDay(d, from);
    final isEnd = inside && _sameDay(d, to);
    final band = inside && !(isStart && isEnd);
    // A faixa arredonda onde a linha da semana, ou o mês, acaba -- sem isso ela
    // sai cortada reta na borda da grade, como uma tabela.
    final roundLeft = d.weekday == DateTime.sunday || d.day == 1;
    final roundRight = d.weekday == DateTime.saturday || d.day == monthDays;
    const r = Radius.circular(_cell / 2);
    final fill = Mx.accent.withValues(alpha: 0.18);
    final dot = isStart || isEnd;
    return MouseRegion(
      cursor: off ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) {
        if (!off && _anchor != null) setState(() => _hover = d);
      },
      child: GestureDetector(
        onTap: off ? null : () => _tap(d),
        child: SizedBox(
          width: _cell,
          height: _cell,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (band)
                Positioned(
                  top: 3,
                  bottom: 3,
                  // As pontas só levam faixa do lado de dentro do período.
                  left: isStart ? _cell / 2 : 0,
                  right: isEnd ? _cell / 2 : 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.horizontal(
                        left: roundLeft && !isStart ? r : Radius.zero,
                        right: roundRight && !isEnd ? r : Radius.zero,
                      ),
                    ),
                  ),
                ),
              Container(
                width: _cell - 6,
                height: _cell - 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot ? Mx.accent : null,
                  border: today && !dot
                      ? Border.all(color: Mx.accent.withValues(alpha: 0.8))
                      : null,
                ),
                child: Center(
                  child: Text(
                    '${d.day}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: off ? Mx.fgFaint.withValues(alpha: 0.45) : (dot ? Mx.canvas : Mx.fg),
                      fontWeight: dot || today ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatefulWidget {
  const _PresetChip({
    required this.label,
    required this.on,
    required this.onTap,
    this.stretch = false,
  });

  final String label;
  final bool on;
  final bool stretch;
  final VoidCallback onTap;

  @override
  State<_PresetChip> createState() => _PresetChipState();
}

class _PresetChipState extends State<_PresetChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: EdgeInsets.only(bottom: widget.stretch ? 3 : 0),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on ? Mx.accent.withValues(alpha: 0.18) : (_hover ? Mx.bgHover : null),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12.5,
              color: on ? Mx.accent : Mx.fg,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// O log de um bloco `console`: monoespaçado, selecionável de ponta a ponta
/// e grudado no fim enquanto você não rolar pra cima.
///
/// Escuta o [PluginConsole] direto, e não a store: é a única parte da janela
/// que muda a cada lote de linhas. Ver `view.appendLines`.
class _Console extends StatefulWidget {
  const _Console({
    required this.console,
    required this.size,
    required this.tone,
    required this.empty,
    this.follow = true,
  });

  final PluginConsole console;
  final double size;
  final Color Function(Object?) tone;
  final String empty;

  /// Grudar no fim quando chegam linhas: um log quer, um diff não -- ele se
  /// lê de cima, e redesenhá-lo não pode jogar você lá pra baixo.
  final bool follow;

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  final _scroll = ScrollController();

  /// Se a vista está no fim -- e portanto deve seguir o que chega. Quem rolou
  /// pra cima pra ler um erro não pode ser arrastado de volta a cada linha.
  bool _following = true;

  @override
  void initState() {
    super.initState();
    widget.console.addListener(_grew);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      _following = p.pixels >= p.maxScrollExtent - 24;
    });
  }

  @override
  void didUpdateWidget(_Console old) {
    super.didUpdateWidget(old);
    if (old.console != widget.console) {
      old.console.removeListener(_grew);
      widget.console.addListener(_grew);
      // Outro console no mesmo lugar (o diff de outro arquivo): começa do
      // topo, e não na altura em que o anterior foi deixado.
      _following = widget.follow;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    widget.console.removeListener(_grew);
    _scroll.dispose();
    super.dispose();
  }

  void _grew() {
    if (!mounted) return;
    setState(() {});
    if (!_following || !widget.follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.console.lines;
    final style = TextStyle(fontFamily: Mx.mono, fontSize: widget.size - 2, height: 1.45);
    return Container(
      decoration: BoxDecoration(
        color: Mx.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: lines.isEmpty
          ? Center(
              child: Text(widget.empty, style: TextStyle(fontSize: 12, color: Mx.fgFaint)),
            )
          : SelectionArea(
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final l = lines[i];
                    final base = style.copyWith(
                      color: l.tone == null ? Mx.fg : widget.tone(l.tone),
                    );
                    final spans = l.spans;
                    if (spans == null) return Text(l.text, style: base);
                    return Text.rich(
                      TextSpan(
                        style: base,
                        children: [
                          for (final s in spans)
                            TextSpan(
                              text: s.text,
                              style: TextStyle(
                                color: s.tone == null ? null : widget.tone(s.tone),
                                fontWeight: s.bold ? FontWeight.w700 : null,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
}

class _ListRow extends StatefulWidget {
  const _ListRow({
    required this.item,
    required this.icon,
    required this.tone,
    required this.size,
    required this.onAction,
    required this.surface,
    this.dir,
    this.onTap,
    this.flat = false,
    this.tree = false,
    this.alwaysActions = false,
  });

  final Map<String, dynamic> item;

  /// A lista tem setas: a linha sem uma guarda o lugar dela.
  final bool tree;

  /// Os botões da linha sempre à vista, e não só com o mouse em cima: a lista
  /// do OrbStack, onde o ▶ e a lixeira de cada container estão sempre ali.
  final bool alwaysActions;

  /// A linha de uma lista `flat`: mais baixa, e o hover é um cartão
  /// arredondado em vez de uma faixa de borda a borda.
  final bool flat;
  final IconData? icon;
  final Color tone;
  final double size;
  final VoidCallback? onTap;

  /// A cor embaixo da linha, pro anel da bolinha do avatar.
  final Color surface;

  /// A pasta do plugin, de onde um `.svg` de avatar é lido.
  final String? dir;

  /// Os botões de `actions` do item: o preparar/descartar do lado do arquivo
  /// no controle de código do VS Code.
  final void Function(String action) onAction;

  @override
  State<_ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<_ListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final subtitle = item['subtitle'] as String?;
    final badge = item['badge'] as String?;
    final meta = item['meta'] as String?;
    final strong = item['strong'] == true;
    final dim = item['dim'] == true;
    final indent = (item['indent'] as num?)?.toDouble() ?? 0;
    final expanded = item['expanded'];
    final clickable = widget.onTap != null;
    final actions = [
      for (final a in PluginView.blocksFrom(item['actions']))
        if ((a['action'], pluginIcon(a['icon'])) case (final String action, final IconData icon))
          (action: action, icon: icon, tooltip: a['tooltip'] as String?, tone: a['tone']),
    ];
    final menu = PluginView.blocksFrom(item['menu']);
    final hovered = clickable && _hover;
    // A linha do que está aberto (`selected`): o fundo na cor de destaque, e
    // o texto na cor que se lê em cima dela.
    final selected = item['selected'] == true;
    final onAccent = ThemeData.estimateBrightnessForColor(Mx.accent) == Brightness.dark
        ? Colors.white
        : Mx.canvas;
    final background = selected
        ? Mx.accent.withValues(alpha: hovered ? 0.95 : 0.85)
        : hovered
        ? Mx.bgHover
        : Colors.transparent;
    final surface = selected
        ? Color.alphaBlend(Mx.accent.withValues(alpha: 0.85), widget.surface)
        : hovered
        ? Color.alphaBlend(Mx.bgHover, widget.surface)
        : widget.surface;
    final showActions = actions.isNotEmpty && (_hover || widget.alwaysActions);
    final avatarSize = widget.flat ? 26.0 : 30.0;
    // A seta de abrir e fechar (`expanded`): o clique nela manda `toggle`, ou
    // a ação da linha quando o plugin não separou as duas.
    final toggle = (item['toggle'] ?? item['action']) as String?;
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapDown: menu.isEmpty
            ? null
            : (d) => _pluginMenu(context, menu, d.globalPosition, widget.onAction),
        child: Container(
          decoration: BoxDecoration(
            color: background,
            borderRadius: widget.flat ? BorderRadius.circular(7) : null,
          ),
          padding: widget.flat
              ? EdgeInsets.fromLTRB(6 + indent * 16, 5, 6, 5)
              : EdgeInsets.fromLTRB(12 + indent * 18, 8, 12, 8),
          child: Row(
            children: [
              if (expanded is bool) ...[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: toggle == null ? null : () => widget.onAction(toggle),
                  child: AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: selected ? onAccent : Mx.fgFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
              ] else if (widget.tree)
                const SizedBox(width: 21),
              if (item['avatar'] != null) ...[
                _Avatar(
                  spec: item['avatar'],
                  dir: widget.dir,
                  size: avatarSize,
                  ring: surface,
                  dim: dim,
                  status: item['status'],
                ),
                const SizedBox(width: 10),
              ] else if (widget.icon case final icon?) ...[
                Icon(icon, size: 16, color: widget.tone),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item['title'] ?? ''}',
                      maxLines: widget.flat ? 1 : null,
                      overflow: widget.flat ? TextOverflow.ellipsis : null,
                      style: TextStyle(
                        fontSize: widget.size - 0.5,
                        fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
                        color: selected
                            ? onAccent
                            : dim
                            ? Mx.fgDim
                            : Mx.fg,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 1.5),
                      Text(
                        subtitle,
                        maxLines: widget.flat ? 1 : null,
                        overflow: widget.flat ? TextOverflow.ellipsis : null,
                        style: TextStyle(
                          fontSize: widget.size - 2,
                          color: selected
                              ? onAccent.withValues(alpha: 0.75)
                              : item['subtitleTone'] != null
                              ? _PluginPaneState._tone(item['subtitleTone'])
                              : dim
                              ? Mx.fgFaint
                              : Mx.fgDim,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Só com o mouse em cima, como no VS Code: numa lista de
              // quarenta arquivos, três ícones em cada linha viram ruído. O
              // `meta` (a porta de um container) sai pra dar lugar a eles.
              if (showActions)
                for (final a in actions)
                  IconButton(
                    tooltip: a.tooltip,
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                    style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: () => widget.onAction(a.action),
                    icon: Icon(
                      a.icon,
                      color: selected
                          ? onAccent
                          : a.tone == null
                          ? (dim && !_hover ? Mx.fgFaint : Mx.fgDim)
                          : _PluginPaneState._tone(a.tone),
                    ),
                  )
              else if (meta != null && meta.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    meta,
                    style: TextStyle(
                      fontSize: widget.size - 2,
                      color: item['metaTone'] == null
                          ? Mx.fgFaint
                          : _PluginPaneState._tone(item['metaTone']),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              if (badge != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: Mx.bgActive,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(badge, style: TextStyle(fontSize: 11, color: Mx.fgDim)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uma aba de um bloco `tabs`: a ativa sobe pro fundo do painel, como o
/// controle segmentado do macOS.
class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.size,
    this.count,
    this.icon,
    this.onTap,
  });

  final String label;
  final String? count;
  final IconData? icon;
  final bool active;
  final double size;
  final VoidCallback? onTap;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.active ? Mx.fg : (_hover ? Mx.fg : Mx.fgDim);
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: widget.active ? Mx.bg : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: widget.active
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon case final icon?) ...[
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: widget.size - 1,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
              if (widget.count case final count?) ...[
                const SizedBox(width: 6),
                Text(
                  count,
                  style: TextStyle(
                    fontSize: widget.size - 2,
                    color: Mx.fgFaint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A faixa de quando o plugin do outro lado caiu: os blocos na tela são do
/// último instante em que ele estava de pé, e nenhum botão vai ser atendido.
class _Stopped extends StatelessWidget {
  const _Stopped({required this.why, this.onRestart});

  final String why;
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Mx.red.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.power_off_outlined, size: 14, color: Mx.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(why, style: TextStyle(fontSize: 12, color: Mx.fg)),
          ),
          if (onRestart != null) TextButton(onPressed: onRestart, child: const Text('Reiniciar')),
        ],
      ),
    );
  }
}

/// O cabeçalho: o do leitor, com a peça de quebra-cabeça e só o fechar.
class _Header extends StatelessWidget {
  const _Header({required this.store, required this.tab, required this.dimmed});

  final AppStore store;
  final MxTab tab;
  final bool dimmed;

  Widget _faded(Widget child) => dimmed ? Opacity(opacity: 0.55, child: child) : child;

  @override
  Widget build(BuildContext context) {
    final index = store.tabs.indexWhere((t) => t.id == tab.id);
    return Container(
      height: 42,
      decoration: paneHeaderBox(store.tintOf(tab)),
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Row(
        children: [
          PluginGlyph(
            icon: store.plugins.byId(tab.view!.pluginId)?.manifest?.icon,
            dir: store.plugins.byId(tab.view!.pluginId)?.dir,
            size: 17,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  Flexible(
                    child: Text(tab.title, overflow: TextOverflow.ellipsis, style: paneTitleStyle),
                  ),
                  PaneKeyHint(index: index),
                  if (box.maxWidth >= 190) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: _faded(
                        Text(
                          tab.subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Mx.fgDim, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (store.plugins.byId(tab.view!.pluginId) case final plugin?
              when plugin.manifest?.settings.isNotEmpty ?? false)
            _faded(
              IconButton(
                tooltip: 'Configurar ${plugin.name}',
                iconSize: 15,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: () => showPluginSettings(context, store, plugin),
                icon: Icon(Icons.tune, color: Mx.fgDim),
              ),
            ),
          if (store.isPinned(tab) || store.paneCount > 1)
            _faded(
              PanePinButton(
                pinned: store.isPinned(tab),
                onPressed: () => store.togglePin(tab),
                iconSize: 15,
              ),
            ),
          _faded(
            IconButton(
              tooltip: 'Fechar esta janela',
              iconSize: 15,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => store.closeTab(tab),
              icon: Icon(Icons.close, color: Mx.fgDim),
            ),
          ),
        ],
      ),
    );
  }
}
