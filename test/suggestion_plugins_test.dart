import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/suggestions.dart';

/// Um plugin em sh que atende o `suggestion.start` como o do Wiboor: responde
/// na hora e, em seguida, conta que criou a tarefa (`suggestion.created`) --
/// o que devolve a vez à Maestria pra fazer o que foi escolhido no cartão. O `id` da janela é o único `"id":` seguido de número --
/// o da sugestão também se chama `id`, mas é texto.
const _taker = r'''#!/bin/sh
idof() { echo "$1" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":{}}" ;;
    *'"method":"suggestion.start"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":null}"
      echo '{"jsonrpc":"2.0","id":"p1","method":"suggestion.created","params":{"suggestionId":"task_00000001","ref":"TASK#1","intro":"Vamos trabalhar na TASK#1","branch":"feature/TASK#1","dir":"TASK-1"}}' ;;
    *'"method":"shutdown"'*)
      exit 0 ;;
  esac
done
''';

Map<String, dynamic> manifest({Object? suggestions = const {'label': 'criar a task no Wiboor'}}) =>
    {
      'id': 'tracker',
      'version': '1',
      'main': ['./plugin.sh'],
      'permissions': ['sessions.create'],
      'contributes': {'suggestions': ?suggestions},
    };

(AppStore, MxTab) storeWithOne() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
  store.folders.add(folder);
  final a = MxTab(
    id: 'a',
    folder: folder,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'implementa',
  );
  final b = MxTab(id: 'b', folder: folder, kind: TabKind.claude, cwd: '/repo', branch: '');
  store.tabs.addAll([a, b]);
  store.panes = PaneLeaf(b.id);
  store.focusedPaneId = b.id;
  return (store, a);
}

void main() {
  group('contributes.suggestions', () {
    test('o label vira o texto do switch', () {
      final m = PluginManifest.parse(manifest());
      expect(m.suggestions, 'criar a task no Wiboor');
      expect(m.warnings, isEmpty);
    });

    test('sem processo não há quem receba a sugestão', () {
      expect(
        () => PluginManifest.parse({...manifest(), 'main': null}),
        throwsA(isA<FormatException>()),
      );
    });

    test('um formato que não é {label} é recusado', () {
      expect(
        () => PluginManifest.parse(manifest(suggestions: true)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PluginManifest.parse(manifest(suggestions: {'label': ' '})),
        throwsA(isA<FormatException>()),
      );
    });

    test('quem não declara não se oferece', () {
      final m = PluginManifest.parse(manifest(suggestions: null));
      expect(m.suggestions, isNull);
    });
  });

  group('suggestion.start num processo de verdade', () {
    late Directory tmp;
    late Plugins plugins;
    final calls = <String>[];

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mx-suggest-');
      final dir = Directory('${tmp.path}/tracker')..createSync();
      File('${dir.path}/$mxManifestName').writeAsStringSync(jsonEncode(manifest()));
      File('${dir.path}/plugin.sh').writeAsStringSync(_taker);
      Process.runSync('chmod', ['+x', '${dir.path}/plugin.sh']);
      calls.clear();
      plugins = Plugins(root: tmp.path)
        ..onCall = (plugin, method, params) async {
          calls.add('$method ${jsonEncode(params)}');
          return {'tabId': 'nova'};
        }
        ..scan();
    });
    tearDown(() async {
      await plugins.stopAll();
      tmp.deleteSync(recursive: true);
    });

    test('a sugestão chega, e o plugin devolve a tarefa que criou', () async {
      expect(plugins.suggestionTakers.map((p) => p.id), ['tracker']);
      await plugins.offerSuggestion(plugins.byId('tracker')!, {
        'suggestion': {'id': 'task_00000001', 'title': 't', 'tldr': '', 'prompt': 'p'},
        'choice': 'here',
        'origin': {'tabId': 'a', 'root': '/repo', 'isRepo': true},
      });
      for (var i = 0; i < 100 && calls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(calls, hasLength(1));
      expect(calls.single, startsWith('suggestion.created'));
      expect(calls.single, contains('"suggestionId":"task_00000001"'));
      expect(calls.single, contains('"ref":"TASK#1"'));
    });

    test('de ponta a ponta: criada a tarefa, "fazer aqui" manda o pedido com ela', () async {
      final (store, a) = storeWithOne();
      store.plugins.all.addAll(plugins.all);
      store.plugins.onCall = PluginApi(store).handle;
      // O id que o plugin de mentira devolve é fixo: a sugestão tem que ser ela.
      final task = SuggestedTask(id: 'task_00000001', title: 'x', tldr: '', prompt: 'o pedido');
      a.hooks.suggestions.add(task);
      // Sem pty no teste: o que a sessão receberia é o que o terminal manda.
      final sent = StringBuffer();
      a.term.terminal.onOutput = sent.write;

      await store.startSuggestionInPlugin(store.suggestionTaker!, a, task, SuggestionChoice.here);
      for (var i = 0; i < 100 && a.hooks.suggestions.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(a.hooks.suggestions, isEmpty);
      // O que foi pro prompt da sessão: a linha do tracker e o pedido.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sent.toString(), contains('Vamos trabalhar na TASK#1'));
      expect(sent.toString(), contains('o pedido'));
      await store.plugins.stopAll();
      store.dispose();
    });

    test('desligado, ele não se oferece', () {
      plugins.byId('tracker')!.enabled = false;
      expect(plugins.suggestionTakers, isEmpty);
    });
  });

  group('o fim do caminho no store', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    MxPlugin taker([String id = 'tracker']) =>
        MxPlugin(dir: '/p', manifest: PluginManifest.parse({...manifest(), 'id': id}));

    test('sem o plugin de pé, a entrega falha e a sugestão segue no cartão', () async {
      final (store, a) = storeWithOne();
      final task = store.suggest('a', title: 'x', tldr: '', prompt: 'y')!.task;
      await store.startSuggestionInPlugin(taker(), a, task, SuggestionChoice.here);
      expect(a.hooks.suggestions, [task]);
      store.dispose();
    });

    test('uma resposta pra sugestão que ninguém entregou é ignorada', () async {
      final (store, a) = storeWithOne();
      final task = store.suggest('a', title: 'x', tldr: '', prompt: 'y')!.task;
      final tab = await store.suggestionTracked(taker(), suggestionId: task.id, ref: 'TASK#1');
      expect(tab, isNull);
      expect(a.hooks.suggestions, [task]);
      store.dispose();
    });
  });

  group('o switch no cartão', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    Future<void> pumpCard(WidgetTester tester, AppStore store, MxTab tab) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: store,
              builder: (_, _) => Align(
                alignment: Alignment.bottomRight,
                child: SuggestionCard(store: store, tab: tab),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    MxPlugin taker() => MxPlugin(dir: '/p', manifest: PluginManifest.parse(manifest()));

    testWidgets('sem plugin que leve a sugestão, não há switch', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'y');
      await pumpCard(tester, store, a);
      expect(find.byType(Switch), findsNothing);
      store.dispose();
    });

    testWidgets('com ele, o switch aparece com o texto do plugin e fica lembrado', (tester) async {
      final (store, a) = storeWithOne();
      store.plugins.all.add(taker());
      store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'y');
      await pumpCard(tester, store, a);

      expect(find.text('criar a task no Wiboor'), findsOneWidget);
      expect(store.suggestionsToPlugin, isFalse);
      // A linha inteira liga, não só a bolinha.
      await tester.tap(find.text('criar a task no Wiboor'));
      await tester.pumpAndSettle();
      expect(store.suggestionsToPlugin, isTrue);
      expect(find.byTooltip(RegExp('^cria a tarefa no tracker, a worktree dela')), findsOneWidget);
      store.dispose();
    });

    testWidgets('nos avulsos o switch vale pras saídas sem worktree', (tester) async {
      final store = AppStore();
      store.plugins.all.add(taker());
      final tab = MxTab(
        id: 'l',
        folder: store.loose,
        kind: TabKind.claude,
        cwd: '/tmp',
        branch: '',
      );
      store.tabs.add(tab);
      store.suggest('l', title: 'Converter SQL', tldr: '', prompt: 'y');
      store.setSuggestionsToPlugin(true);
      await pumpCard(tester, store, tab);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('iniciar com worktree'), findsNothing);
      expect(
        find.byTooltip('cria a tarefa no tracker e abre a sessão nesta pasta'),
        findsOneWidget,
      );
      store.dispose();
    });
  });
}
