import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/hooks.dart';

/// A porta que vai gravada no `--settings` de uma sessão.
int portIn(String settings) {
  final url =
      (((jsonDecode(settings) as Map)['hooks'] as Map)['Stop'] as List).first as Map;
  final at = ((url['hooks'] as List).first as Map)['url'] as String;
  return Uri.parse(at).port;
}

void main() {
  group('HookServer', () {
    setUp(() {
      if (HookServer.portFile.existsSync()) HookServer.portFile.deleteSync();
    });
    tearDown(() {
      if (HookServer.portFile.existsSync()) HookServer.portFile.deleteSync();
    });

    test('a segunda execução volta na mesma porta da primeira', () async {
      final first = HookServer();
      await first.start();
      final was = first.port;
      expect(was, greaterThan(0));
      await first.stop();

      // Uma sessão lançada pela execução passada aponta pra `was` até morrer --
      // e o daemon do Claude Code respawna com os mesmos flags. Subir noutra
      // porta é o que a deixava batendo em ECONNREFUSED pelo resto da vida.
      final again = HookServer();
      await again.start();
      expect(again.port, was);
      expect(portIn(again.settingsFor('tab2')), was);
      await again.stop();
    });

    test('porta anotada ocupada: cai numa livre e passa a anotar essa', () async {
      final squatter = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      HookServer.portFile.parent.createSync(recursive: true);
      HookServer.portFile.writeAsStringSync('${squatter.port}\n');

      final server = HookServer();
      await server.start();
      expect(server.port, isNot(squatter.port));
      expect(HookServer.portFile.readAsStringSync().trim(), '${server.port}');
      await server.stop();
      await squatter.close(force: true);
    });

    test('anotação ilegível não impede a janela de abrir', () async {
      HookServer.portFile.parent.createSync(recursive: true);
      HookServer.portFile.writeAsStringSync('nem número\n');

      final server = HookServer();
      await server.start();
      expect(server.port, greaterThan(0));
      expect(HookServer.portFile.readAsStringSync().trim(), '${server.port}');
      await server.stop();
    });

    test('o hook chega ao painel pela porta anunciada', () async {
      final server = HookServer();
      await server.start();
      final seen = server.events.first;

      // Pela porta que o `--settings` anuncia, e não pela que o servidor diz
      // ter: é a anunciada que a sessão vai procurar.
      expect(portIn(server.settingsFor('tab7')), server.port);
      final client = HttpClient();
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/hook/tab7'),
      );
      req.write(jsonEncode({'hook_event_name': 'Stop', 'session_id': 's1'}));
      await (await req.close()).drain<void>();
      client.close();

      final event = await seen.timeout(const Duration(seconds: 5));
      expect(event.tabId, 'tab7');
      expect(event.name, 'Stop');
      await server.stop();
    });
  });
}
