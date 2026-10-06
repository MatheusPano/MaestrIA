/// O catálogo de plugins, e as versões novas dos que você instalou.
///
/// Um catálogo é um `catalog.json` publicado por um repositório de plugins --
/// o oficial é o `maestria-plugins`, que solta cada plugin numa release própria
/// e refaz o catálogo a cada versão nova. Cada entrada é um plugin: o que ele é
/// e pede (pra tela mostrar antes de baixar), e de onde baixá-lo -- um `.zip`
/// com o sha256 dele, ou um repositório de git de outra pessoa.
///
/// As versões novas vêm de onde o plugin veio (ver [PluginOrigin]): o catálogo
/// em que ele estava, ou o repositório de git de onde foi clonado. Elas entram
/// sozinhas quando o interruptor está ligado, menos quando a versão nova pede
/// mais do que a instalada pedia -- uma permissão nova, ou um programa onde só
/// havia declarações. Essa espera o seu "confio", como na instalação.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'plugins.dart';
import 'shell.dart';
import 'updater.dart' show compareVersions;

/// O catálogo oficial: os plugins do repositório `maestria-plugins`.
const mxOfficialCatalog =
    'https://github.com/MatheusPano/maestria-plugins/releases/download/catalog/catalog.json';

/// Um plugin do catálogo, do jeito que ele se apresenta antes de ser baixado.
class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.api = mxPluginApi,
    this.permissions = const [],
    this.icon,
    this.url,
    this.sha256,
    this.git,
    this.ref,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;

  /// A versão da API que ele pede (o `maestria` do manifesto).
  final int api;

  /// Os ids de [PluginPermission], como o manifesto os escreve.
  final List<String> permissions;

  /// A URL de um `.svg`.
  final String? icon;

  /// O `.zip` e o sha256 dele, pra um plugin do próprio repositório do
  /// catálogo.
  final String? url;
  final String? sha256;

  /// O repositório, pra um plugin que mora em outro lugar.
  final String? git;
  final String? ref;

  /// Se esta MaestrIA consegue rodá-lo.
  bool get fits => api <= mxPluginApi;

  static CatalogEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], version = j['version'];
    if (id is! String || version is! String) return null;
    final url = j['url'] as String?, sha = j['sha256'] as String?, git = j['git'] as String?;
    // Um .zip sem o hash não tem contra o que ser conferido.
    if (!(url != null && sha != null) && git == null) return null;
    return CatalogEntry(
      id: id,
      name: j['name'] as String? ?? id,
      version: version,
      description: j['description'] as String? ?? '',
      author: j['author'] as String? ?? '',
      api: (j['maestria'] as num?)?.toInt() ?? mxPluginApi,
      permissions: (j['permissions'] as List? ?? const []).whereType<String>().toList(),
      icon: j['icon'] as String?,
      url: git == null ? url : null,
      sha256: git == null ? sha?.toLowerCase() : null,
      git: git,
      ref: j['ref'] as String?,
    );
  }
}

class PluginCatalog {
  const PluginCatalog(this.url, this.plugins);

  final String url;
  final List<CatalogEntry> plugins;

  CatalogEntry? byId(String id) => plugins.firstWhereOrNull((e) => e.id == id);

  /// Lê o `catalog.json`. As entradas que não leem ficam de fora, e não
  /// derrubam as outras: um catálogo com um plugin mal escrito ainda serve.
  static PluginCatalog parse(String url, String body) {
    final j = jsonDecode(body);
    if (j is! Map || j['plugins'] is! List) throw const FormatException('não é um catálogo');
    return PluginCatalog(url, [
      for (final e in j['plugins'] as List)
        if (CatalogEntry.fromJson(e) case final entry?) entry,
    ]);
  }
}

/// Uma versão nova de um plugin instalado, ou outro lugar de onde recebê-las.
class PluginUpdate {
  const PluginUpdate({
    required this.id,
    required this.from,
    required this.to,
    required this.origin,
    this.entry,
    this.asksMore = false,
  });

  final String id;

  /// A versão instalada e a que vem.
  final String from;
  final String to;

  /// De onde ela vem -- e de onde as próximas vão vir depois dela.
  final PluginOrigin origin;

  /// A entrada do catálogo, quando ela vem de um.
  final CatalogEntry? entry;

  /// Pede uma permissão nova, ou roda um programa onde não rodava: não entra
  /// sem o seu "confio".
  final bool asksMore;

  bool get newer => compareVersions(to, from) > 0;

  PluginUpdate _asking() =>
      PluginUpdate(id: id, from: from, to: to, origin: origin, entry: entry, asksMore: true);
}

class PluginUpdates extends ChangeNotifier {
  PluginUpdates(this.plugins, {required this.install, this.catalogs = const [mxOfficialCatalog]});

  final Plugins plugins;

  /// Instala o que foi baixado. É o da store, que fecha as janelas da versão
  /// antiga e guarda o config.
  final Future<MxPlugin> Function(StagedPlugin staged) install;

  /// Os catálogos que a tela mostra e onde se procura versão nova.
  final List<String> catalogs;

  /// De quanto em quanto tempo procurar. Plugin muda mais que o app, mas
  /// nada aqui é urgente.
  static const every = Duration(hours: 6);

  /// A primeira procura espera o app assentar, como a do app (ver [Updater]).
  static const firstDelay = Duration(seconds: 45);

  Timer? _timer;

  final Map<String, PluginCatalog> _loaded = {};

  /// As versões novas, por id do plugin.
  final Map<String, PluginUpdate> available = {};

  /// Plugins instalados de outro jeito que estão num catálogo: dá pra passar a
  /// recebê-los de lá. Ver [prepare].
  final Map<String, PluginUpdate> offers = {};

  /// Os que estão sendo baixados ou trocados agora.
  final Set<String> busy = {};

  /// O último commit visto de cada plugin de git, e o que se concluiu dele:
  /// clonar de novo só quando o repositório andou.
  final Map<String, (String, PluginUpdate?)> _gitSeen = {};

  DateTime? checkedAt;
  bool checking = false;

  /// O que deu errado na última procura, pra tela contar.
  String? error;

  PluginCatalog? loaded(String url) => _loaded[url];

  void start() {
    _timer?.cancel();
    _timer = Timer(firstDelay, () {
      check();
      _timer = Timer.periodic(every, (_) => check());
    });
  }

  /// Baixa o catálogo de novo.
  Future<PluginCatalog> load(String url) async {
    final catalog = PluginCatalog.parse(url, await _get(url));
    _loaded[url] = catalog;
    notifyListeners();
    return catalog;
  }

  /// Procura versão nova de tudo que veio de um catálogo ou de git, e instala
  /// as que podem entrar sozinhas.
  Future<void> check() async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      for (final url in catalogs) {
        try {
          await load(url);
        } catch (e) {
          error = 'Não deu pra ler o catálogo: $e';
        }
      }
      final found = <String, PluginUpdate>{}, offered = <String, PluginUpdate>{};
      for (final p in [...plugins.all]) {
        final m = p.manifest;
        if (m == null || p.linked) continue;
        try {
          if (await _lookup(p, m) case final u?) found[p.id] = u;
        } catch (e) {
          p.note('procurar versão nova: $e');
        }
        if (_offer(p, m) case final o?) offered[p.id] = o;
      }
      available
        ..clear()
        ..addAll(found);
      offers
        ..clear()
        ..addAll(offered);
      checkedAt = DateTime.now();
    } finally {
      checking = false;
      notifyListeners();
    }
    for (final u in available.values.toList()) {
      if (entersAlone(u)) await _quietly(u);
    }
  }

  /// Se [u] pode entrar sem perguntar.
  bool entersAlone(PluginUpdate u) =>
      plugins.autoUpdate && !plugins.manualUpdate.contains(u.id) && !u.asksMore && u.newer;

  Future<PluginUpdate?> _lookup(MxPlugin p, PluginManifest m) async {
    final origin = plugins.origins[p.id];
    if (origin?.catalog case final url?) {
      final e = _loaded[url]?.byId(p.id);
      if (e == null || !e.fits || compareVersions(e.version, m.version) <= 0) return null;
      return PluginUpdate(
        id: p.id,
        from: m.version,
        to: e.version,
        origin: origin!,
        entry: e,
        asksMore: e.permissions.any((id) => !m.permissions.any((perm) => perm.id == id)),
      );
    }
    if (origin?.git case final git?) {
      final head = await _head(git, origin!.ref);
      if (head == null) return null;
      if (_gitSeen[p.id] case (final seen, final u) when seen == head) return u;
      final staged = await plugins.stage(git, ref: origin.ref);
      try {
        final next = staged.manifest;
        final u = next.id == p.id && compareVersions(next.version, m.version) > 0
            ? PluginUpdate(
                id: p.id,
                from: m.version,
                to: next.version,
                origin: origin,
                asksMore: asksMore(m, next),
              )
            : null;
        _gitSeen[p.id] = (head, u);
        return u;
      } finally {
        await plugins.discard(staged);
      }
    }
    return null;
  }

  /// Um plugin que não veio de catálogo nenhum, mas está num: dá pra passar a
  /// recebê-lo de lá. Só quando a versão de lá não é mais velha que a sua.
  PluginUpdate? _offer(MxPlugin p, PluginManifest m) {
    if (plugins.origins[p.id]?.catalog != null) return null;
    for (final url in catalogs) {
      final e = _loaded[url]?.byId(p.id);
      if (e == null || !e.fits || compareVersions(e.version, m.version) < 0) continue;
      return PluginUpdate(
        id: p.id,
        from: m.version,
        to: e.version,
        origin: PluginOrigin.catalog(url),
        entry: e,
      );
    }
    return null;
  }

  /// Se [next] pede mais do que [old] pedia: uma permissão que não tinha, ou um
  /// programa onde só havia declarações.
  static bool asksMore(PluginManifest old, PluginManifest next) =>
      next.permissions.difference(old.permissions).isNotEmpty ||
      (!old.hasProcess && next.hasProcess);

  /// Baixa um plugin do catálogo [catalog] e o deixa no rascunho, conferido.
  Future<StagedPlugin> stageEntry(CatalogEntry e, String catalog) async {
    final origin = PluginOrigin.catalog(catalog);
    if (e.git case final git?) {
      final staged = await plugins.stage(git, ref: e.ref, origin: origin);
      return _sameId(staged, e.id);
    }
    final base = Directory('${plugins.root}/.staging');
    await base.create(recursive: true);
    final tmp = await base.createTemp('dl');
    try {
      final file = '${tmp.path}/${e.id}.zip';
      await _download(e.url!, file);
      final got = await _sha256(file);
      if (got != e.sha256) {
        throw PluginInstallError('O pacote de ${e.name} não confere (sha256 $got)');
      }
      final staged = await plugins.stage(file, origin: origin);
      return await _sameId(
        StagedPlugin(
          staging: staged.staging,
          dir: staged.dir,
          manifest: staged.manifest,
          source: e.url!,
          origin: origin,
          replacing: staged.replacing,
        ),
        e.id,
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// O catálogo diz que é um plugin, e o pacote não pode ser outro.
  Future<StagedPlugin> _sameId(StagedPlugin staged, String id) async {
    if (staged.manifest.id == id) return staged;
    await plugins.discard(staged);
    throw PluginInstallError('O pacote é de "${staged.manifest.id}", e não de "$id"');
  }

  /// Baixa [u] pro rascunho, pra quem vai mostrar o "confio" antes.
  Future<StagedPlugin> stageUpdate(PluginUpdate u) {
    if (u.entry case final e?) return stageEntry(e, u.origin.catalog!);
    return plugins.stage(u.origin.git!, ref: u.origin.ref);
  }

  /// Instala o que foi baixado -- por [stageUpdate], pelo catálogo ou por uma
  /// URL -- e esquece a versão nova que estava esperando: ela acabou de entrar,
  /// ou foi trocada por outra.
  Future<MxPlugin> finish(StagedPlugin staged) async {
    final plugin = await install(staged);
    available.remove(plugin.id);
    offers.remove(plugin.id);
    _gitSeen.remove(plugin.id);
    notifyListeners();
    return plugin;
  }

  /// [stageUpdate] pra quem pediu pela tela: o plugin fica marcado como
  /// ocupado enquanto baixa. Serve também pra uma das [offers] -- baixar a
  /// versão do catálogo é o que passa a recebê-lo de lá.
  Future<StagedPlugin> prepare(PluginUpdate u) async {
    if (!busy.add(u.id)) throw const PluginInstallError('Já está baixando');
    notifyListeners();
    try {
      return await stageUpdate(u);
    } finally {
      busy.remove(u.id);
      notifyListeners();
    }
  }

  /// A atualização sem pergunta. O pacote é conferido de novo depois de
  /// baixado: o catálogo pode ter dito menos do que o manifesto pede.
  Future<void> _quietly(PluginUpdate u) async {
    final p = plugins.byId(u.id);
    final old = p?.manifest;
    if (p == null || old == null || !busy.add(u.id)) return;
    notifyListeners();
    try {
      final staged = await stageUpdate(u);
      if (asksMore(old, staged.manifest)) {
        await plugins.discard(staged);
        available[u.id] = u._asking();
        return;
      }
      final plugin = await finish(staged);
      plugin.note('atualizado sozinho de ${u.from} pra ${u.to}');
    } catch (e) {
      p.note('atualizar pra ${u.to}: $e');
    } finally {
      busy.remove(u.id);
      notifyListeners();
    }
  }

  /// O commit pra onde [ref] (ou o ramo padrão) aponta agora, sem clonar.
  Future<String?> _head(String git, String? ref) async {
    // Sem o prompt de senha: um repositório privado sem credencial falha, e
    // não fica esperando alguém digitar num terminal que não existe.
    final r = await Sh.run(
      'GIT_TERMINAL_PROMPT=0 git ls-remote ${Sh.q(git)} ${Sh.q(ref ?? 'HEAD')}',
    );
    if (!r.ok) return null;
    final first = r.stdout.trim().split(RegExp(r'\s')).first;
    return first.isEmpty ? null : first;
  }

  Future<String> _get(String url) async {
    final client = HttpClient()..userAgent = 'maestria';
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      return body;
    } finally {
      client.close();
    }
  }

  Future<void> _download(String url, String to) async {
    final client = HttpClient()..userAgent = 'maestria';
    try {
      // O anexo de uma release responde com um redirecionamento pro
      // armazenamento do GitHub, e o `HttpClient` segue sozinho.
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) throw PluginInstallError('$url: HTTP ${res.statusCode}');
      await res.pipe(File(to).openWrite());
    } finally {
      client.close();
    }
  }

  static Future<String> _sha256(String path) async {
    final r = Platform.isMacOS
        ? await Process.run('shasum', ['-a', '256', path])
        : await Process.run('sha256sum', [path]);
    if (r.exitCode != 0) throw PluginInstallError('sha256: ${r.stderr}');
    return (r.stdout as String).split(RegExp(r'\s')).first.toLowerCase();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
