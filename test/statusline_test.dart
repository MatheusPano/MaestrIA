import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/shell.dart';

/// O `statusLine` que o `--settings` de uma sessão manda pro Claude Code.
Map<String, dynamic> statusLineIn(String settings) =>
    (jsonDecode(settings) as Map<String, dynamic>)['statusLine'] as Map<String, dynamic>;

/// Os argumentos do comando como o shell os entende -- e não como o texto
/// parece: é o shell do Claude Code que vai ler este comando.
Future<List<String>> argsOf(String command) async {
  final r = await Process.run('sh', ['-c', 'f() { for a in "\$@"; do printf "%s\\0" "\$a"; done; }; f $command']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final out = r.stdout as String;
  return out.substring(0, out.length - 1).split('\u0000');
}

void main() {
  late Directory tmp;
  late Directory cwd;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('statusline-test');
    cwd = Directory('${tmp.path}/proj')..createSync();
    home = Directory('${tmp.path}/home')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void settingsAt(Directory base, String name, String body) {
    final f = File('${base.path}/.claude/$name');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  String line(String command) => jsonEncode({
    'statusLine': {'type': 'command', 'command': command},
  });

  group('userStatusLine', () {
    test('o settings.local.json do projeto vence o settings.json, que vence o do home', () {
      settingsAt(home, 'settings.json', line('home'));
      expect(HookServer.userStatusLine(cwd.path, home: home.path)?['command'], 'home');
      settingsAt(cwd, 'settings.json', line('projeto'));
      expect(HookServer.userStatusLine(cwd.path, home: home.path)?['command'], 'projeto');
      settingsAt(cwd, 'settings.local.json', line('local'));
      expect(HookServer.userStatusLine(cwd.path, home: home.path)?['command'], 'local');
    });

    test('json inválido é pulado', () {
      settingsAt(cwd, 'settings.local.json', '{ isto não é json');
      settingsAt(home, 'settings.json', line('home'));
      expect(HookServer.userStatusLine(cwd.path, home: home.path)?['command'], 'home');
    });

    test('statusLine que não é do tipo command é ignorado', () {
      settingsAt(cwd, 'settings.json', jsonEncode({
        'statusLine': {'type': 'outro', 'command': 'x'},
      }));
      expect(HookServer.userStatusLine(cwd.path, home: home.path), isNull);
    });

    test('nada em lugar nenhum dá null', () {
      expect(HookServer.userStatusLine(cwd.path, home: home.path), isNull);
      expect(HookServer.userStatusLine(null, home: home.path), isNull);
    });
  });

  group('settingsFor', () {
    late HookServer server;
    setUp(() async {
      server = HookServer();
      await server.start();
    });
    tearDown(() => server.stop());

    test('sem statusLine do usuário: o script do app com o terceiro argumento vazio', () async {
      final settings = server.settingsFor('t1', cwd: cwd.path, home: home.path);
      final status = statusLineIn(settings);
      expect(status['type'], 'command');
      expect(status.containsKey('padding'), isFalse);
      final args = await argsOf(status['command'] as String);
      expect(args, [
        'sh',
        HookServer.statusLineFile.path,
        'http://127.0.0.1:${server.port}/status/t1',
        '',
      ]);
      expect((status['command'] as String).endsWith(" ''"), isTrue);
      // Os hooks não mudam por causa da linha de status.
      final hooks = (jsonDecode(settings) as Map)['hooks'] as Map;
      expect(hooks.keys, containsAll(['SessionStart', 'Stop', 'PreToolUse', 'SubagentStop']));
      final stop = ((hooks['Stop'] as List).first as Map)['hooks'] as List;
      expect((stop.first as Map)['url'], 'http://127.0.0.1:${server.port}/hook/t1');
    });

    test('com statusLine do usuário: o comando vai em base64 e o padding junto', () async {
      const user = r'echo "$HOME" | tr a-z A-Z';
      settingsAt(cwd, 'settings.json', jsonEncode({
        'statusLine': {'type': 'command', 'command': user, 'padding': 2},
      }));
      final status = statusLineIn(server.settingsFor('t1', cwd: cwd.path, home: home.path));
      expect(status['padding'], 2);
      final args = await argsOf(status['command'] as String);
      expect(args[3], base64.encode(utf8.encode(user)));
    });

    test('o script é gravado ao subir o servidor', () {
      expect(HookServer.statusLineFile.readAsStringSync(), HookServer.statusLineScript);
    });

    test('passa inteiro pelas duas camadas de aspas até o shell do Claude Code', () async {
      // `--settings ${Sh.q(json)}` na linha de comando: o shell do pty tira uma
      // camada, o Claude Code lê o json e roda o `command` noutro shell.
      const user = "printf '%s' \"it's \$x\" | tr a-z A-Z";
      settingsAt(cwd, 'settings.json', line(user));
      final settings = server.settingsFor('t1', cwd: cwd.path, home: home.path);
      final r = await Process.run('sh', ['-c', 'printf "%s" ${Sh.q(settings)}']);
      expect(r.stdout, settings);
      final args = await argsOf(statusLineIn(r.stdout as String)['command'] as String);
      expect(utf8.decode(base64.decode(args[3])), user);
    });
  });

  group('o script', () {
    late File script;
    setUp(() {
      script = File('${tmp.path}/statusline.sh')..writeAsStringSync(HookServer.statusLineScript);
    });

    const json = '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}';
    String b64(String s) => base64.encode(utf8.encode(s));
    const closed = 'http://127.0.0.1:1/status/t1';

    Future<ProcessResult> run(String url, String user, {Map<String, String>? env}) => Process.run(
      '/bin/sh',
      ['-c', "printf '%s' ${Sh.q(json)} | /bin/sh ${Sh.q(script.path)} ${Sh.q(url)} ${Sh.q(user)}"],
      environment: env,
      includeParentEnvironment: env == null,
    );

    test('com o comando do usuário `cat`, a saída é o json recebido', () async {
      final r = await run(closed, b64('cat'));
      expect(r.stdout, json);
      expect(r.exitCode, 0);
    });

    test('sem comando do usuário, a saída é vazia e o código é 0', () async {
      final r = await run(closed, '');
      expect(r.stdout, '');
      expect(r.exitCode, 0);
    });

    test('aspas simples, \$ e pipe no comando do usuário saem como rodando direto', () async {
      const user = "printf \"%s\" 'a\$b' | tr a b";
      final direct = await Process.run('/bin/sh', ['-c', user]);
      final r = await run(closed, b64(user));
      expect(direct.stdout, 'b\$b');
      expect(r.stdout, direct.stdout);
    });

    test('o json chega no servidor da URL', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final got = Completer<String>();
      http.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        if (!got.isCompleted) got.complete(body);
        req.response.statusCode = 200;
        await req.response.close();
      });
      await run('http://127.0.0.1:${http.port}/status/t1', b64('cat'));
      expect(await got.future.timeout(const Duration(seconds: 2)), json);
      await http.close(force: true);
    });

    test('porta fechada: termina rápido e a saída do usuário sai igual', () async {
      final watch = Stopwatch()..start();
      final r = await run(closed, b64('cat'));
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1500));
      expect(r.stdout, json);
    });

    test('sem curl no PATH: nada no stderr e a saída do usuário sai igual', () async {
      // Um PATH só com o que o script precisa além do curl. O `sh` que roda o
      // script é chamado por caminho absoluto; o de dentro (`sh -c "$cmd"`) e
      // os utilitários vêm desta pasta.
      final bin = Directory('${tmp.path}/bin')..createSync();
      for (final tool in ['sh', 'cat', 'base64', 'tr', 'printf']) {
        final found = await Process.run('/bin/sh', ['-c', 'command -v $tool']);
        final path = (found.stdout as String).trim();
        if (path.startsWith('/')) Link('${bin.path}/$tool').createSync(path);
      }
      expect(File('${bin.path}/curl').existsSync(), isFalse);
      final r = await run(closed, b64('cat'), env: {'PATH': bin.path});
      expect(r.stdout, json);
      expect(r.stderr, '');
      expect(r.exitCode, 0);
    });
  });
}
