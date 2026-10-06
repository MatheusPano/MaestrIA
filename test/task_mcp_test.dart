import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/task_mcp.dart';

/// Uma fila de mentira, no lugar do store: o que se testa aqui é o protocolo.
class _Desk implements TaskDesk {
  final pending = <SuggestedTask>[];
  final ended = <String, SuggestionEnd>{};
  var seq = 0;

  @override
  SuggestionQueued? suggest(
    String tabId, {
    required String title,
    required String tldr,
    required String prompt,
  }) {
    if (tabId != 'tab1') return null;
    final task = SuggestedTask(
      id: 'task_0000000${seq++}',
      title: title,
      tldr: tldr,
      prompt: prompt,
    );
    pending.add(task);
    return SuggestionQueued(task, pending: List.of(pending));
  }

  @override
  ({bool withdrawn, SuggestionEnd? already}) withdraw(String tabId, String taskId) {
    final before = pending.length;
    pending.removeWhere((t) => t.id == taskId);
    if (pending.length < before) {
      ended[taskId] = SuggestionEnd.dismissed;
      return (withdrawn: true, already: null);
    }
    return (withdrawn: false, already: ended[taskId]);
  }
}

Map<String, dynamic> call(String tool, Map<String, dynamic> args, {int id = 1}) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': 'tools/call',
  'params': {'name': tool, 'arguments': args},
};

String textOf(Object? response) {
  final result = (response as Map)['result'] as Map;
  return ((result['content'] as List).first as Map)['text'] as String;
}

void main() {
  group('TaskMcp', () {
    test('o initialize ecoa a versão do cliente e se apresenta', () {
      final r =
          TaskMcp.handle(
                {
                  'jsonrpc': '2.0',
                  'id': 0,
                  'method': 'initialize',
                  'params': {'protocolVersion': '2025-03-26', 'capabilities': {}},
                },
                'tab1',
                _Desk(),
              )
              as Map;
      final result = r['result'] as Map;
      expect(result['protocolVersion'], '2025-03-26');
      expect((result['serverInfo'] as Map)['name'], 'maestria');
      expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
      expect(result['instructions'], contains('suggest_task'));
    });

    test('notificação não tem resposta', () {
      final r = TaskMcp.handle(
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        'tab1',
        _Desk(),
      );
      expect(r, isNull);
    });

    test('lista as duas ferramentas com o que cada uma exige', () {
      final r =
          TaskMcp.handle({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, 'tab1', _Desk())
              as Map;
      final tools = ((r['result'] as Map)['tools'] as List).cast<Map>();
      expect(tools.map((t) => t['name']), ['suggest_task', 'dismiss_task']);
      expect((tools.first['inputSchema'] as Map)['required'], ['title', 'tldr', 'prompt']);
    });

    test('uma sugestão vai pra fila e volta com o id pra retirar depois', () {
      final desk = _Desk();
      final r = TaskMcp.handle(
        call('suggest_task', {
          'title': 'Converter os exemplos SQL',
          'tldr': 'O guia está em PostgreSQL.',
          'prompt': '  Reescreva as seções 3 e 5 em MySQL.  ',
        }),
        'tab1',
        desk,
      );
      expect(desk.pending.single.prompt, 'Reescreva as seções 3 e 5 em MySQL.');
      expect(textOf(r), contains('task_00000000'));
      expect(textOf(r), contains('dismiss_task'));
    });

    test('prompt vazio é erro da ferramenta, não do protocolo', () {
      final desk = _Desk();
      final r =
          TaskMcp.handle(call('suggest_task', {'title': 'x', 'prompt': ' '}), 'tab1', desk) as Map;
      expect((r['result'] as Map)['isError'], isTrue);
      expect(desk.pending, isEmpty);
    });

    test('prompt acima do teto é recusado', () {
      final r =
          TaskMcp.handle(
                call('suggest_task', {'title': 'x', 'prompt': 'a' * (TaskMcp.maxPrompt + 1)}),
                'tab1',
                _Desk(),
              )
              as Map;
      expect((r['result'] as Map)['isError'], isTrue);
    });

    test('sem painel, a sessão ouve que não há onde mostrar', () {
      final r =
          TaskMcp.handle(call('suggest_task', {'title': 'x', 'prompt': 'y'}), 'tab9', _Desk())
              as Map;
      expect((r['result'] as Map)['isError'], isTrue);
    });

    test('retirar uma vez retira; a segunda diz que já saiu', () {
      final desk = _Desk();
      TaskMcp.handle(call('suggest_task', {'title': 'x', 'prompt': 'y'}), 'tab1', desk);
      final first = TaskMcp.handle(
        call('dismiss_task', {'task_id': 'task_00000000'}),
        'tab1',
        desk,
      );
      expect(textOf(first), contains('withdrawn'));
      expect(desk.pending, isEmpty);
      final again = TaskMcp.handle(
        call('dismiss_task', {'task_id': 'task_00000000'}),
        'tab1',
        desk,
      );
      expect(textOf(again), contains('already dismissed'));
    });

    test('um task_id fora do formato é recusado', () {
      final r = TaskMcp.handle(call('dismiss_task', {'task_id': 'abc'}), 'tab1', _Desk()) as Map;
      expect((r['result'] as Map)['isError'], isTrue);
    });

    test('método desconhecido é erro JSON-RPC', () {
      final r =
          TaskMcp.handle({'jsonrpc': '2.0', 'id': 3, 'method': 'resources/list'}, 'tab1', _Desk())
              as Map;
      expect((r['error'] as Map)['code'], -32601);
    });
  });

  group('HookServer /mcp', () {
    late HookServer server;
    late _Desk desk;

    setUp(() async {
      if (HookServer.portFile.existsSync()) HookServer.portFile.deleteSync();
      server = HookServer();
      desk = _Desk();
      server.desk = desk;
      await server.start();
    });
    tearDown(() async {
      await server.stop();
      if (HookServer.portFile.existsSync()) HookServer.portFile.deleteSync();
    });

    Future<(int, String)> post(String path, Object body) async {
      final client = HttpClient();
      try {
        final req = await client.post('127.0.0.1', server.port, path);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final res = await req.close();
        return (res.statusCode, await utf8.decoder.bind(res).join());
      } finally {
        client.close();
      }
    }

    test('o painel da URL é o painel que recebe a sugestão', () async {
      final (status, body) = await post(
        '/mcp/tab1',
        call('suggest_task', {'title': 'x', 'prompt': 'y'}),
      );
      expect(status, 200);
      expect(textOf(jsonDecode(body)), contains('Noted'));
      expect(desk.pending, hasLength(1));
    });

    test('notificação recebe 202 sem corpo', () async {
      final (status, body) = await post('/mcp/tab1', {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(status, 202);
      expect(body, isEmpty);
    });

    test('o --mcp-config e a permissão apontam pro mesmo servidor', () {
      final config = jsonDecode(server.mcpConfigFor('tab1')) as Map;
      final entry = (config['mcpServers'] as Map)[TaskMcp.server] as Map;
      expect(entry['type'], 'http');
      expect(entry['url'], 'http://127.0.0.1:${server.port}/mcp/tab1');
      expect(entry['alwaysLoad'], isTrue);

      final settings = jsonDecode(server.settingsFor('tab1')) as Map;
      expect((settings['permissions'] as Map)['allow'], [
        'mcp__maestria__suggest_task',
        'mcp__maestria__dismiss_task',
      ]);
    });
  });
}
