import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/store.dart';

Map<String, dynamic> status({Object? used = 58.4, Object? usage, int? size = 200000}) => {
  'context_window': {
    'used_percentage': used,
    if (size != null) 'context_window_size': size,
    'current_usage': usage ??
        {
          'input_tokens': 10,
          'cache_creation_input_tokens': 1000,
          'cache_read_input_tokens': 115000,
          'output_tokens': 300,
        },
  },
};

Future<void> post(HookServer server, String path, Object body) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}$path'));
  req.write(jsonEncode(body));
  await (await req.close()).drain<void>();
  client.close();
}

void main() {
  group('ContextUsage.fromStatusLine', () {
    test('lê percentual arredondado, tokens sem a saída e a janela', () {
      final c = ContextUsage.fromStatusLine(status())!;
      expect(c.percent, 58);
      expect(c.tokens, 116010);
      expect(c.window, 200000);
    });

    test('sem número agora vira null', () {
      expect(ContextUsage.fromStatusLine(status(used: null)), isNull);
      final noUsage = status();
      (noUsage['context_window'] as Map)['current_usage'] = null;
      expect(ContextUsage.fromStatusLine(noUsage), isNull);
      expect(ContextUsage.fromStatusLine({'model': 'x'}), isNull);
      expect(ContextUsage.fromStatusLine('nada'), isNull);
      expect(ContextUsage.fromStatusLine(status(size: null)), isNull);
      expect(ContextUsage.fromStatusLine(status(size: 0)), isNull);
    });
  });

  group('HookServer /status', () {
    test('status sai em statuses e hook continua em events', () async {
      final server = HookServer();
      await server.start();
      final seenStatus = server.statuses.first;
      final hooks = <HookEvent>[];
      final sub = server.events.listen(hooks.add);

      await post(server, '/hook/tab9', {'hook_event_name': 'Stop'});
      await post(server, '/status/tab9', status());

      final e = await seenStatus.timeout(const Duration(seconds: 5));
      expect(e.tabId, 'tab9');
      expect(e.payload['context_window'], isA<Map>());
      expect(hooks.map((h) => h.name), ['Stop']);
      await sub.cancel();
      await server.stop();
    });
  });

  group('AppStore.applyStatus', () {
    MxTab tab() => MxTab(
      id: 't1',
      folder: Folder(root: '/repo', name: 'repo'),
      kind: TabKind.claude,
      cwd: '/repo',
      branch: '',
    );

    test('grava, limpa e ignora painel inexistente', () {
      final store = AppStore();
      final t = tab();
      store.tabs.add(t);

      store.applyStatus(StatusEvent('t1', status()));
      expect(t.context?.percent, 58);
      expect(t.context?.tokens, 116010);
      expect(t.context?.window, 200000);

      final cleared = status();
      (cleared['context_window'] as Map)['current_usage'] = null;
      store.applyStatus(StatusEvent('t1', cleared));
      expect(t.context, isNull);

      store.applyStatus(StatusEvent('nope', status()));
      store.dispose();
    });
  });
}
