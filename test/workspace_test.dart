import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/workspace.dart';
import 'package:maestria/ui/dialogs.dart';
import 'package:maestria/ui/sidebar.dart';

CodeWorkspace? parse(String source, {String path = '/repos/cefis.code-workspace'}) =>
    CodeWorkspace.parse(source, path: path);

void main() {
  final home = Platform.environment['HOME'] ?? '';

  group('reconhecer um workspace', () {
    // Por dentro o arquivo é um json qualquer: a extensão é tudo que o campo
    // de adicionar pasta tem pra decidir por onde mandar o que foi digitado.
    test('é a extensão, e ela não é sensível a caixa nem a espaço', () {
      expect(CodeWorkspace.looksLikeOne('/repos/cefis.code-workspace'), isTrue);
      expect(CodeWorkspace.looksLikeOne('  /repos/Cefis.Code-Workspace  '), isTrue);
      expect(CodeWorkspace.looksLikeOne('/repos/cefis'), isFalse);
      expect(CodeWorkspace.looksLikeOne('/repos/settings.json'), isFalse);
    });
  });

  group('ler o arquivo', () {
    test('as pastas saem na ordem, e o nome é o do arquivo', () {
      final ws = parse('''
        { "folders": [ {"path": "/a"}, {"path": "/b"} ] }
      ''');
      expect(ws, isNotNull);
      expect(ws!.name, 'cefis');
      expect(ws.folders.map((f) => f.path), ['/a', '/b']);
    });

    // Relativo é o caso comum, e relativo ao *arquivo*: contra o cwd de uma
    // .app um `../api` aponta pra dentro do bundle.
    test('caminho relativo é resolvido contra a pasta do arquivo', () {
      final ws = parse(
        '{"folders": [{"path": "api"}, {"path": "../outro/web"}, {"path": "./aqui"}]}',
        path: '/Volumes/repos/cefis/tudo.code-workspace',
      );
      expect(ws!.folders.map((f) => f.path), [
        '/Volumes/repos/cefis/api',
        '/Volumes/repos/outro/web',
        '/Volumes/repos/cefis/aqui',
      ]);
    });

    test('absoluto passa, e o `..` do meio some antes de virar identidade', () {
      final ws = parse('{"folders": [{"path": "/a/b/../b/./c"}, {"path": "/../x"}]}');
      expect(ws!.folders.map((f) => f.path), ['/a/b/c', '/x']);
    });

    // Licença nossa: o VS Code não expande `~` em `folders`, mas o arquivo é
    // editado à mão e um `~/repos/api` escrito ali é uma pasta que existe.
    test('o ~ de um arquivo escrito à mão vira o HOME', () {
      final ws = parse('{"folders": [{"path": "~/repos/api"}]}');
      expect(ws!.folders.single.path, '$home/repos/api');
    });

    test('o apelido do vscode vem junto quando existe', () {
      final ws = parse('{"folders": [{"path": "/a", "name": "API"}, {"path": "/b"}]}');
      expect(ws!.folders.first.name, 'API');
      expect(ws.folders.last.name, isNull);
    });

    test('entrada sem path é ignorada em vez de derrubar o arquivo', () {
      final ws = parse('{"folders": [{"name": "só nome"}, {"path": ""}, {"path": "/b"}]}');
      expect(ws!.folders.map((f) => f.path), ['/b']);
    });

    test('sem folders é um workspace sem pasta, não um erro', () {
      expect(parse('{"settings": {}}')!.folders, isEmpty);
    });

    test('json quebrado e json que não é objeto viram nulo', () {
      expect(parse('{"folders": ['), isNull);
      expect(parse('[1, 2]'), isNull);
      expect(parse(''), isNull);
    });
  });

  // O VS Code escreve as duas coisas sozinho, e o jsonDecode não aceita
  // nenhuma: sem isto o import mais comum de todos -- o arquivo que a pessoa
  // vem editando há meses -- responde "não consegui ler".
  group('o json com as liberdades do vscode', () {
    test('comentário de linha, de bloco e vírgula sobrando', () {
      final ws = parse('''
        {
          // as pastas do cliente
          "folders": [
            {"path": "/a"}, /* o de sempre */
            {"path": "/b"},
          ],
          "settings": {},
        }
      ''');
      expect(ws!.folders.map((f) => f.path), ['/a', '/b']);
    });

    test('as barras de uma url dentro de string não são comentário', () {
      final ws = parse('''
        {"folders": [{"path": "/a", "name": "http://x/y"}],
         "settings": {"u": "https://exemplo.com//x"}}
      ''');
      expect(ws!.folders.single.name, 'http://x/y');
    });

    test('a vírgula e a chave dentro de string ficam onde estão', () {
      final ws = parse('{"folders": [{"path": "/a", "name": "b, }"}]}');
      expect(ws!.folders.single.name, 'b, }');
    });

    test('a barra invertida escapada não engole a aspas seguinte', () {
      final ws = parse(r'{"folders": [{"path": "/a", "name": "c:\\"}, {"path": "/b"}]}');
      expect(ws!.folders.map((f) => f.path), ['/a', '/b']);
    });
  });

  group('importar um workspace', () {
    /// Um workspace de verdade no disco, com as pastas que ele lista.
    Future<(String, List<String>)> onDisk(
      List<String> names, {
      List<String> alsoListed = const [],
      String Function(String name)? entry,
    }) async {
      final dir = Directory.systemTemp.createTempSync('maestria-ws-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final made = <String>[];
      for (final name in names) {
        Directory('${dir.path}/$name').createSync(recursive: true);
        made.add('${dir.path}/$name');
      }
      final listed = [...names, ...alsoListed]
          .map((n) => entry?.call(n) ?? '{"path": "$n"}')
          .join(',');
      final file = File('${dir.path}/cefis.code-workspace');
      file.writeAsStringSync('{"folders": [$listed]}');
      return (file.path, made);
    }

    test('adiciona todas as pastas de uma vez e carimba de onde vieram', () async {
      final (path, made) = await onDisk(['api', 'web']);
      final store = AppStore();
      addTearDown(store.dispose);

      final result = await store.importWorkspace(path);

      expect(result, isNotNull);
      expect(result!.added.length, 2);
      expect(store.folders.map((f) => f.root), containsAll(made));
      expect(store.folders.every((f) => f.workspace == path), isTrue);
      expect(store.banner, 'workspace "cefis": 2 pastas adicionadas');
    });

    test('o apelido do arquivo vira o nome da pasta na lateral', () async {
      final (path, _) = await onDisk(
        ['api'],
        entry: (n) => '{"path": "$n", "name": "API do cefis"}',
      );
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);

      expect(store.folders.single.name, 'API do cefis');
    });

    // O caso do monorepo: duas pastas do arquivo resolvem pro mesmo checkout
    // principal e viram uma só na lateral. O que não pode é sumir calada.
    test('a pasta repetida entra na conta em vez de sumir', () async {
      final (path, made) = await onDisk(['api'], alsoListed: ['api']);
      final store = AppStore();
      addTearDown(store.dispose);

      final result = await store.importWorkspace(path);

      expect(store.folders.length, 1);
      expect(store.folders.single.root, made.single);
      expect(result!.added.length, 1);
      expect(result.already.length, 1);
      expect(store.banner, 'workspace "cefis": 1 pasta adicionada, 1 já estava aqui');
    });

    test('a pasta que o disco não tem é contada, e a tarja fica parada', () async {
      final (path, _) = await onDisk(['api'], alsoListed: ['sumiu']);
      final store = AppStore();
      addTearDown(store.dispose);

      final result = await store.importWorkspace(path);

      expect(result!.added.length, 1);
      expect(result.missing.single, endsWith('/sumiu'));
      expect(result.sticky, isTrue);
      expect(store.banner, 'workspace "cefis": 1 pasta adicionada, 1 não existe no disco');
    });

    test('importar duas vezes não duplica nem repete o carimbo', () async {
      final (path, _) = await onDisk(['api', 'web']);
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);
      final again = await store.importWorkspace(path);

      expect(store.folders.length, 2);
      expect(again!.added, isEmpty);
      expect(again.already.length, 2);
      expect(store.banner, 'workspace "cefis": 2 já estavam aqui');
    });

    // Uma pasta que já veio de outro arquivo continua daquele: o workspace
    // mais recente não é mais verdadeiro que o primeiro, e trocar por baixo
    // mudaria o que o "abrir no vscode" dela faz.
    test('o segundo workspace não rouba a pasta do primeiro', () async {
      final (path, made) = await onDisk(['api']);
      final outro = File('${File(path).parent.path}/outro.code-workspace')
        ..writeAsStringSync('{"folders": [{"path": "${made.single}"}]}');
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);
      await store.importWorkspace(outro.path);

      expect(store.folders.single.workspace, path);
    });

    test('arquivo que não está lá e workspace sem pasta viram tarja', () async {
      final store = AppStore();
      addTearDown(store.dispose);

      expect(await store.importWorkspace('/nao/existe.code-workspace'), isNull);
      expect(store.banner, startsWith('não consegui ler esse workspace'));

      final dir = Directory.systemTemp.createTempSync('maestria-ws-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final vazio = File('${dir.path}/vazio.code-workspace')
        ..writeAsStringSync('{"folders": []}');

      expect(await store.importWorkspace(vazio.path), isNull);
      expect(store.banner, 'o workspace "vazio" não lista nenhuma pasta');
      expect(store.folders, isEmpty);
    });

    // Sem tocar no disco de propósito: um caminho que não existe já prova por
    // onde o que foi digitado saiu -- só o import responde essa tarja, e
    // `addFolder` responderia "pasta não encontrada".
    testWidgets('o campo de adicionar pasta manda um .code-workspace pro import', (
      tester,
    ) async {
      final store = AppStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showAddFolder(ctx, store),
                child: const Text('+'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('+'));
      await tester.pumpAndSettle();
      expect(find.text('escolher workspace…'), findsOneWidget);
      expect(
        find.text('um .code-workspace adiciona todas as pastas dele de uma vez.'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), '/nao/existe.code-workspace');
      await tester.tap(find.text('adicionar'));
      await tester.pumpAndSettle();

      expect(store.banner, startsWith('não consegui ler esse workspace'));
      expect(store.folders, isEmpty);
    });

    // O `FlutterMethodNotImplemented` do lado nativo chega como resposta nula
    // no canal, e é dela que sai o `MissingPluginException` -- que é o estado
    // de um hot reload por cima do binário de antes. O clique tem que dizer
    // alguma coisa em vez de não fazer nada.
    testWidgets('o seletor que não abre diz que não abriu', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler('maestria/dock', (_) async => null);
      addTearDown(() => messenger.setMockMessageHandler('maestria/dock', null));
      final store = AppStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showAddFolder(ctx, store),
                child: const Text('+'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('+'));
      await tester.pumpAndSettle();
      expect(
        find.text('um .code-workspace adiciona todas as pastas dele de uma vez.'),
        findsOneWidget,
      );

      await tester.tap(find.text('escolher workspace…'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'não consegui abrir o seletor — cole aí em cima o caminho do .code-workspace',
        ),
        findsOneWidget,
      );
    });

    testWidgets('e o que o seletor escolhe cai no campo', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('maestria/dock'),
        (call) async => call.method == 'chooseWorkspace' ? '/repos/cefis.code-workspace' : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(const MethodChannel('maestria/dock'), null),
      );
      final store = AppStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showAddFolder(ctx, store),
                child: const Text('+'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('+'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('escolher workspace…'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '/repos/cefis.code-workspace',
      );
    });

    test('o import cria a seção da lateral', () async {
      final (path, _) = await onDisk(['api', 'web']);
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);

      expect(store.workspaces.single.path, path);
      expect(store.workspaces.single.name, 'cefis');
      expect(store.foldersOf(store.workspaces.single).length, 2);
    });

    // Um arquivo cujas pastas todas sumiram não vira cabeçalho sobre coisa
    // nenhuma.
    test('sem pasta que entre não há seção', () async {
      final (path, _) = await onDisk([], alsoListed: ['sumiu']);
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);

      expect(store.workspaces, isEmpty);
    });

    test('o carimbo sobrevive à ida e volta do config', () {
      final folder = Folder(root: '/repo', name: 'api', workspace: '/repos/x.code-workspace');
      final back = Folder.fromJson(folder.toJson());
      expect(back.workspace, '/repos/x.code-workspace');
      // E a pasta de sempre continua sem campo nenhum a mais no arquivo.
      expect(Folder(root: '/repo', name: 'api').toJson().containsKey('workspace'), isFalse);
    });

    test('e a seção também, dobrada como estava', () {
      final ws = Workspace(path: '/repos/x.code-workspace', name: 'cefis', collapsed: true);
      final back = Workspace.fromJson(ws.toJson())!;
      expect(back.path, '/repos/x.code-workspace');
      expect(back.name, 'cefis');
      expect(back.collapsed, isTrue);
      // Aberta é o normal, e o normal não ocupa espaço no arquivo.
      expect(Workspace(path: '/x', name: 'x').toJson().containsKey('collapsed'), isFalse);
      // E o registro que não desenharia nada não volta.
      expect(Workspace.fromJson({'path': '/x'}), isNull);
      expect(Workspace.fromJson('nada'), isNull);
    });
  });

  group('a seção na lateral', () {
    /// Duas pastas de um workspace, uma solta no meio e uma depois.
    AppStore storeWith() {
      final store = AppStore();
      const ws = '/repos/cefis.code-workspace';
      store.folders.addAll([
        Folder(root: '/repo/api', name: 'api', workspace: ws)..isRepo = true,
        Folder(root: '/repo/solta', name: 'solta')..isRepo = true,
        Folder(root: '/repo/web', name: 'web', workspace: ws)..isRepo = true,
      ]);
      store.workspaces.add(Workspace(path: ws, name: 'cefis'));
      return store;
    }

    /// Como a janela de verdade monta a lateral: dentro de um
    /// [AnimatedBuilder] que escuta o store -- ver `main.dart`. Sem ele, dobrar
    /// a seção muda o estado e não redesenha nada.
    Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 660,
            height: 700,
            child: AnimatedBuilder(
              animation: store,
              builder: (_, _) => Sidebar(store: store),
            ),
          ),
        ),
      ),
    );

    // A seção entra no lugar da *primeira* pasta dela e leva a outra junto: a
    // ordem das pastas por baixo continua sendo a que está no config.
    test('a ordem da lateral põe a seção onde a primeira pasta dela estava', () {
      final store = storeWith();
      addTearDown(store.dispose);

      final rows = store.sidebarRows;

      expect(rows.length, 2);
      expect((rows.first as Workspace).name, 'cefis');
      expect((rows.last as Folder).name, 'solta');
      expect(store.foldersOf(rows.first as Workspace).map((f) => f.name), ['api', 'web']);
    });

    testWidgets('desenha o nome, a conta e as pastas dentro', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);

      await pumpSidebar(tester, store);

      expect(find.text('cefis'), findsOneWidget);
      expect(find.text('2 pastas'), findsOneWidget);
      expect(find.text('api'), findsOneWidget);
      expect(find.text('web'), findsOneWidget);
      expect(find.text('solta'), findsOneWidget);
    });

    testWidgets('dobrada, some com as pastas e continua dizendo quantas', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      await pumpSidebar(tester, store);

      await tester.tap(find.text('cefis'));
      await tester.pumpAndSettle();

      expect(find.text('api'), findsNothing);
      expect(find.text('web'), findsNothing);
      expect(find.text('cefis'), findsOneWidget);
      expect(find.text('2 pastas'), findsOneWidget);
      // E a pasta que não é do workspace não some junto.
      expect(find.text('solta'), findsOneWidget);
    });

    testWidgets('a busca abre a seção dobrada e esconde a que não achou nada', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final api = store.folders.firstWhere((f) => f.name == 'api');
      store.tabs.add(
        MxTab(
          id: 'tab1',
          folder: api,
          kind: TabKind.claude,
          cwd: api.root,
          branch: '',
          customLabel: 'permissão do google',
        ),
      );
      store.workspaces.single.collapsed = true;

      store.setQuery('google');
      await pumpSidebar(tester, store);

      // Dobrada, ela esconderia justamente o que a busca acabou de achar.
      expect(find.text('cefis'), findsOneWidget);
      expect(find.text('permissão do google'), findsOneWidget);

      store.setQuery('nada disso');
      await tester.pumpAndSettle();
      expect(find.text('cefis'), findsNothing);
    });

    test('tirar a última pasta desfaz a seção', () async {
      final store = storeWith();
      addTearDown(store.dispose);

      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'api'));
      expect(store.workspaces.length, 1);

      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'web'));
      expect(store.workspaces, isEmpty);
    });

    // O config de quem importou antes desta seção existir: pastas carimbadas e
    // nenhuma lista de workspace. Sem isto o bloco só apareceria reimportando.
    test('a pasta carimbada sem seção ganha uma', () {
      final store = AppStore();
      addTearDown(store.dispose);
      store.folders.add(
        Folder(root: '/repo/api', name: 'api', workspace: '/repos/cefis.code-workspace'),
      );

      store.reconcileWorkspaces();

      expect(store.workspaces.single.name, 'cefis');
      expect(store.workspaces.single.path, '/repos/cefis.code-workspace');
    });

    test('e a seção sem pasta nenhuma some', () {
      final store = AppStore();
      addTearDown(store.dispose);
      store.workspaces.add(Workspace(path: '/repos/orfa.code-workspace', name: 'orfa'));

      store.reconcileWorkspaces();

      expect(store.workspaces, isEmpty);
    });
  });

  // A volta do import: ele põe as pastas, isto tira. Nada toca o disco.
  group('fechar um workspace', () {
    AppStore storeWith() {
      final store = AppStore();
      const ws = '/repos/cefis.code-workspace';
      store.folders.addAll([
        Folder(root: '/repo/api', name: 'api', workspace: ws)..isRepo = true,
        Folder(root: '/repo/solta', name: 'solta')..isRepo = true,
        Folder(root: '/repo/web', name: 'web', workspace: ws)..isRepo = true,
      ]);
      store.workspaces.add(Workspace(path: ws, name: 'cefis'));
      return store;
    }

    test('leva as pastas dele e a seção, e não encosta nas outras', () async {
      final store = storeWith();
      addTearDown(store.dispose);

      await store.closeWorkspace(store.workspaces.single);

      expect(store.workspaces, isEmpty);
      expect(store.folders.map((f) => f.name), ['solta']);
      expect(store.banner, 'workspace "cefis" fechado — 2 pastas saíram da lateral');
    });

    // Os painéis das pastas fecham junto -- é o que [removeFolder] faz --, e é
    // por isso que o diálogo conta quantos são antes de perguntar.
    test('as sessões das pastas fecham junto', () async {
      final store = storeWith();
      addTearDown(store.dispose);
      final api = store.folders.firstWhere((f) => f.name == 'api');
      final solta = store.folders.firstWhere((f) => f.name == 'solta');
      for (final (id, folder) in [('tab1', api), ('tab2', solta)]) {
        store.tabs.add(
          MxTab(id: id, folder: folder, kind: TabKind.claude, cwd: folder.root, branch: ''),
        );
      }

      await store.closeWorkspace(store.workspaces.single);

      // A da pasta que não era do workspace continua onde estava.
      expect(store.tabs.map((t) => t.id), ['tab2']);
    });

    testWidgets('o menu da seção oferece fechar, e o diálogo conta o que vai', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      store.tabs.add(
        MxTab(
          id: 'tab1',
          folder: store.folders.first,
          kind: TabKind.claude,
          cwd: '/repo/api',
          branch: '',
          // Parada, e não `starting`: uma sessão subindo desenha um indicador
          // que gira, e um `pumpAndSettle` sobre uma animação que não acaba
          // não volta.
        )..hooks.status = ClaudeStatus.idle,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 660,
              height: 700,
              child: AnimatedBuilder(
                animation: store,
                builder: (_, _) => Sidebar(store: store),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('cefis'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('fechar workspace…'), findsOneWidget);

      await tester.tap(find.text('fechar workspace…'));
      await tester.pumpAndSettle();

      // Os dois fatos que decidem a resposta, e o que o diálogo *não* faz.
      expect(find.text('fechar cefis?'), findsOneWidget);
      expect(find.text('2 pastas saem da lateral'), findsOneWidget);
      expect(find.text('1 sessão aberta é encerrada'), findsOneWidget);
      expect(
        find.text('nada é apagado do disco — nem os repos, nem o .code-workspace'),
        findsOneWidget,
      );

      // E cancelar não fecha nada.
      await tester.tap(find.text('cancelar'));
      await tester.pumpAndSettle();
      expect(store.workspaces, hasLength(1));
      expect(store.folders, hasLength(3));
    });

    testWidgets('confirmado, a seção sai da lateral', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 660,
              height: 700,
              child: AnimatedBuilder(
                animation: store,
                builder: (_, _) => Sidebar(store: store),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('cefis'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('fechar workspace…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('fechar workspace'));
      await tester.pumpAndSettle();

      expect(find.text('cefis'), findsNothing);
      expect(find.text('api'), findsNothing);
      expect(find.text('solta'), findsOneWidget);

      // A tarja do "fechado" sai sozinha depois de [AppStore.bannerLife], e o
      // teste tem que esperar por ela: um timer de pé quando a árvore morre é
      // erro no `flutter test`.
      await tester.pump(AppStore.bannerLife);
    });
  });
}
