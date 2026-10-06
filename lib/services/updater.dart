/// A atualização sozinha: a release nova sai do GitHub e entra no lugar desta.
///
/// O caminho é o mesmo que a pessoa faria na mão -- a página de releases, o
/// anexo do sistema dela, instalar -- só que perguntado à API pública do repo.
/// Sem conta e sem token: o repo é público, e o limite anônimo (60 pedidos por
/// hora por IP) sobra pra uma pergunta a cada poucas horas, mesmo com o time
/// inteiro atrás do mesmo IP do escritório.
///
/// O que ela não faz é reiniciar por conta própria. Cada painel é uma sessão do
/// claude no meio de alguma coisa, e reiniciar é derrubar todas. Então a
/// release é baixada e conferida em segundo plano, fica pronta, e espera: no
/// Mac ela entra quando você fecha o app (ou no "reiniciar agora"); no Linux,
/// quando você pede -- trocar o pacote ali pede a senha de administrador, e
/// uma janela de senha surgindo depois que o app fechou não seria de ninguém.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'paths.dart';

/// A versão deste build, como o pubspec a escreve (`2.4.0`).
///
/// Vem de `--dart-define`, e quem passa são os empacotadores (`make-dmg.sh`,
/// `make-deb.sh`). Um `flutter run` não passa nada, e é de propósito: vazia, a
/// atualização fica desligada -- um build de desenvolvimento se substituindo
/// pela release publicada seria perder o que se estava testando.
const mxVersion = String.fromEnvironment('MAESTRIA_VERSION');

/// Onde a atualização está.
enum UpdateStage {
  /// Nada novo, ou ainda não perguntou.
  idle,

  /// Baixando e conferindo a release nova.
  fetching,

  /// Baixada, conferida, esperando a vez de entrar.
  ready,

  /// O pacote está sendo instalado (Linux: o apt com a senha pedida).
  installing,

  /// Instalada no disco; falta só reabrir pra estar valendo (Linux).
  installed,
}

/// `2.10.0` é maior que `2.9.1`: compara número a número, e não como texto.
/// Um `v` na frente (o da tag) é ignorado; o que não é número conta como zero.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[.+-]'))
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// O hash que o `SHA256SUMS` da release diz para [file], ou null se ele não
/// estiver lá. O formato é o do `sha256sum`: `<hash>  <nome>`, um por linha
/// (com `*` antes do nome quando gerado em modo binário).
String? expectedSum(String sums, String file) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2)!.trim() == file) return m.group(1)!.toLowerCase();
  }
  return null;
}

/// Uma release, reduzida ao que a atualização usa.
class MxRelease {
  const MxRelease({
    required this.version,
    required this.asset,
    required this.assetUrl,
    required this.sumsUrl,
  });

  final String version;

  /// O nome do anexo deste sistema (`maestria_2.5.0-1_macos.dmg`).
  final String asset;
  final String assetUrl;

  /// O `SHA256SUMS` anexado junto. Sem ele a release não é instalada: o
  /// arquivo baixado não teria contra o que ser conferido.
  final String? sumsUrl;

  /// A release mais nova lida da resposta de `releases/latest`, se ela tiver
  /// o anexo que [suffix] procura.
  static MxRelease? fromJson(Map<String, dynamic> j, String suffix) {
    final tag = j['tag_name'] as String?;
    if (tag == null) return null;
    String? asset, assetUrl, sumsUrl;
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is! Map) continue;
      final name = a['name'] as String? ?? '';
      final url = a['browser_download_url'] as String?;
      if (name == 'SHA256SUMS') sumsUrl = url;
      if (name.endsWith(suffix)) {
        asset = name;
        assetUrl = url;
      }
    }
    if (asset == null || assetUrl == null) return null;
    return MxRelease(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      asset: asset,
      assetUrl: assetUrl,
      sumsUrl: sumsUrl,
    );
  }
}

class Updater extends ChangeNotifier {
  Updater({this.current = mxVersion});

  static const repo = 'MatheusPano/MaestrIA';

  /// De quanto em quanto tempo perguntar. Release sai de semana em semana; um
  /// app que fica aberto dias seguidos ainda fica sabendo no mesmo dia.
  static const every = Duration(hours: 6);

  /// A primeira pergunta espera o app assentar: a abertura já tem sessões
  /// subindo, plugins e git pra ler.
  static const firstDelay = Duration(seconds: 30);

  final String current;

  UpdateStage stage = UpdateStage.idle;

  /// A release baixada, quando [stage] é [UpdateStage.ready] ou depois.
  MxRelease? release;

  Timer? _timer;
  String? _etag;
  bool _relaunch = false;

  /// O que já está no disco esperando: o `.app` desempacotado (Mac) ou o
  /// `.deb` (Linux).
  String? _staged;

  Directory get _dir => Directory('$mxStateDir/update');

  /// Mac e Linux instalados pelo pacote da release. Fora disso não há o que
  /// trocar: um build de desenvolvimento ([mxVersion] vazio), um `.deb` que
  /// não mora em `/opt/maestria`, ou uma arquitetura que a release não tem.
  bool get enabled {
    if (current.isEmpty) return false;
    if (Platform.isMacOS) return _bundle != null;
    if (Platform.isLinux) {
      // A release só tem o `.deb` amd64.
      return Platform.resolvedExecutable.startsWith('/opt/maestria/') &&
          Platform.version.contains('linux_x64');
    }
    return false;
  }

  /// O `.app` que está rodando, onde quer que ele tenha sido posto -- não
  /// necessariamente o `/Applications`.
  String? get _bundle {
    final exe = Platform.resolvedExecutable;
    final i = exe.lastIndexOf('.app/Contents/MacOS/');
    return i < 0 ? null : exe.substring(0, i + 4);
  }

  String get _suffix => Platform.isMacOS ? '_macos.dmg' : '_amd64.deb';

  /// No Mac a troca é na saída, sem pedir nada. No Linux é um clique, com a
  /// senha.
  bool get installsOnQuit => Platform.isMacOS;

  void start() {
    if (!enabled) return;
    _cleanup();
    _timer = Timer(firstDelay, () {
      check();
      _timer = Timer.periodic(every, (_) => check());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _set(UpdateStage s) {
    stage = s;
    notifyListeners();
  }

  /// Pergunta ao GitHub, e baixa o que for novo.
  ///
  /// Falha de rede, release sem anexo, hash que não bate: tudo isso volta ao
  /// [UpdateStage.idle] em silêncio e é tentado de novo na próxima volta. A
  /// atualização é uma conveniência, e um aviso de erro a cada seis horas no
  /// Wi-Fi do aeroporto não seria.
  Future<void> check() async {
    if (!enabled || stage != UpdateStage.idle) return;
    try {
      final latest = await _latest();
      if (latest == null || compareVersions(latest.version, current) <= 0) return;
      _set(UpdateStage.fetching);
      _staged = await _fetch(latest);
      release = latest;
      _set(UpdateStage.ready);
    } catch (e) {
      debugPrint('updater: $e');
      _staged = null;
      if (stage == UpdateStage.fetching) _set(UpdateStage.idle);
    }
  }

  Future<MxRelease?> _latest() async {
    final client = HttpClient()..userAgent = 'maestria/$current';
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      );
      req.headers.set('Accept', 'application/vnd.github+json');
      // Uma resposta 304 não conta no limite da API: quase toda pergunta é
      // "ainda a mesma?", e a resposta quase sempre é sim.
      if (_etag != null) req.headers.set('If-None-Match', _etag!);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 304) return null;
      if (res.statusCode != 200) throw 'releases/latest: HTTP ${res.statusCode}';
      _etag = res.headers.value('etag');
      return MxRelease.fromJson(jsonDecode(body) as Map<String, dynamic>, _suffix);
    } finally {
      client.close();
    }
  }

  /// Baixa e confere o anexo; no Mac, já desempacota o `.app` do `.dmg`.
  /// Devolve o caminho do que vai ser instalado.
  Future<String> _fetch(MxRelease r) async {
    if (r.sumsUrl == null) throw '${r.version} sem SHA256SUMS';
    // Um `.app` numa pasta em que não dá pra escrever não tem como ser trocado
    // na saída. Melhor não oferecer do que oferecer e não cumprir.
    if (Platform.isMacOS) await _run('test', ['-w', File(_bundle!).parent.path]);
    if (await _dir.exists()) await _dir.delete(recursive: true);
    await _dir.create(recursive: true);

    final sums = await _download(r.sumsUrl!, '${_dir.path}/SHA256SUMS');
    final want = expectedSum(await File(sums).readAsString(), r.asset);
    if (want == null) throw '${r.asset} não está no SHA256SUMS';

    final file = await _download(r.assetUrl, '${_dir.path}/${r.asset}');
    final got = await _sha256(file);
    if (got != want) throw '${r.asset}: sha256 $got, esperado $want';

    if (!Platform.isMacOS) return file;

    // O `.dmg` vira um `.app` agora, e não na saída: na saída o tempo é curto e
    // não há mais janela pra contar que algo deu errado.
    final mnt = '${_dir.path}/mnt';
    final app = '${_dir.path}/maestria.app';
    await _run('hdiutil', ['attach', '-nobrowse', '-readonly', '-mountpoint', mnt, file]);
    try {
      await _run('ditto', ['$mnt/maestria.app', app]);
    } finally {
      await _run('hdiutil', ['detach', mnt, '-force']);
    }
    await File(file).delete();
    await _run('codesign', ['--verify', '--deep', app]);
    // Baixado pelo próprio app, nada aqui vem marcado de quarentena -- é isso
    // que poupa a atualização do "não foi possível verificar" do Gatekeeper.
    // A linha só garante.
    await Process.run('xattr', ['-dr', 'com.apple.quarantine', app]);
    return app;
  }

  Future<String> _download(String url, String to) async {
    final client = HttpClient()..userAgent = 'maestria/$current';
    try {
      // O anexo responde com um redirecionamento pro armazenamento do GitHub,
      // e o `HttpClient` segue sozinho.
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) throw '$url: HTTP ${res.statusCode}';
      await res.pipe(File(to).openWrite());
      return to;
    } finally {
      client.close();
    }
  }

  Future<String> _sha256(String path) async {
    final r = Platform.isMacOS
        ? await Process.run('shasum', ['-a', '256', path])
        : await Process.run('sha256sum', [path]);
    if (r.exitCode != 0) throw 'sha256: ${r.stderr}';
    return (r.stdout as String).split(RegExp(r'\s')).first.toLowerCase();
  }

  Future<void> _run(String exe, List<String> args) async {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) throw '$exe ${args.first}: ${(r.stderr as String).trim()}';
  }

  /// Sobras de uma atualização que já entrou: o app que abriu é a versão nova,
  /// ou a pasta está ali de uma tentativa que não foi até o fim.
  Future<void> _cleanup() async {
    try {
      if (await _dir.exists()) await _dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Linux: instala o `.deb` agora, pedindo a senha pelo `pkexec`.
  ///
  /// Trocar os arquivos com o app aberto é seguro ali: o processo segue com os
  /// que já carregou, e a versão nova vale da próxima abertura. Devolve o erro,
  /// ou null se instalou.
  Future<String?> install() async {
    if (Platform.isMacOS || stage != UpdateStage.ready || _staged == null) return null;
    _set(UpdateStage.installing);
    final r = await Process.run('pkexec', ['apt-get', 'install', '-y', _staged!]);
    if (r.exitCode == 0) {
      _set(UpdateStage.installed);
      return null;
    }
    _set(UpdateStage.ready);
    // 126: a janela da senha foi cancelada. Não é erro, é "agora não".
    if (r.exitCode == 126) return 'Instalação cancelada';
    final why = '${r.stderr}'.trim().split('\n').last;
    return 'Não deu pra instalar ($why). No terminal: sudo apt install $_staged';
  }

  /// Pede pra reabrir o app depois que a saída terminar. Ver [onQuit].
  void relaunchAfterQuit() => _relaunch = true;

  /// O último passo da saída, depois que as sessões já foram encerradas.
  ///
  /// Quem faz a troca é um `sh` solto, que sobrevive a este processo: ele
  /// espera o pid sumir, troca o `.app` (Mac) e reabre se foi pedido. Os
  /// caminhos vão como argumentos, não colados no script.
  Future<void> onQuit() async {
    final mac = Platform.isMacOS && stage == UpdateStage.ready && _staged != null;
    final linux = Platform.isLinux && stage == UpdateStage.installed && _relaunch;
    if (!mac && !linux) return;
    final script = mac ? _swapScript : _relaunchScript;
    final target = mac ? _bundle! : Platform.resolvedExecutable;
    await Process.start('/bin/sh', [
      '-c',
      script,
      'maestria-update',
      '$pid',
      target,
      _staged ?? '',
      _relaunch ? '1' : '',
    ], mode: ProcessStartMode.detached);
  }

  /// `$1` o pid, `$2` o `.app` instalado, `$3` o novo, `$4` reabrir.
  ///
  /// O antigo sai pro lado antes do novo entrar, e volta se a cópia falhar: o
  /// pior caso é continuar na versão de antes, nunca ficar sem app.
  static const _swapScript = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
old="$2.old"
rm -rf "$old"
if mv "$2" "$old"; then
  if ditto "$3" "$2"; then
    rm -rf "$old" "$(dirname "$3")"
  else
    rm -rf "$2"; mv "$old" "$2"
  fi
fi
if [ -n "$4" ]; then open "$2"; fi
''';

  /// `$1` o pid, `$2` o executável. O pacote já foi trocado pelo apt.
  static const _relaunchScript = r'''
while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
setsid "$2" >/dev/null 2>&1 < /dev/null &
''';
}
