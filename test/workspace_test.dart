import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/workspace.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/dialogs.dart';
import 'package:maestria/ui/sidebar.dart';

CodeWorkspace? parse(String source, {String path = '/repos/cefis.code-workspace'}) =>
    CodeWorkspace.parse(source, path: path);

/// O config que o store acabou de gravar. O save é debounced, então a leitura
/// espera o arquivo aparecer.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

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
      expect(store.foldersOf(store.workspaces.single).map((f) => f.root), made);
      expect(store.workspaces.single.codeWorkspacePath, path);
      expect(store.banner, 'Workspace "cefis": 2 pastas adicionadas');
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
      expect(store.banner, 'Workspace "cefis": 1 pasta adicionada, 1 já estava aqui');
    });

    test('a pasta que o disco não tem é contada, e a tarja fica parada', () async {
      final (path, _) = await onDisk(['api'], alsoListed: ['sumiu']);
      final store = AppStore();
      addTearDown(store.dispose);

      final result = await store.importWorkspace(path);

      expect(result!.added.length, 1);
      expect(result.missing.single, endsWith('/sumiu'));
      expect(result.sticky, isTrue);
      expect(store.banner, 'Workspace "cefis": 1 pasta adicionada, 1 não existe no disco');
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
      expect(store.banner, 'Workspace "cefis": 2 já estavam aqui');
    });

    // Com o espelho, a pasta que os dois arquivos listam fica nos dois.
    test('a pasta que dois arquivos listam fica nos dois workspaces', () async {
      final (path, made) = await onDisk(['api']);
      final outro = File('${File(path).parent.path}/outro.code-workspace')
        ..writeAsStringSync('{"folders": [{"path": "${made.single}"}]}');
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);
      await store.importWorkspace(outro.path);

      expect(store.folders.length, 1);
      expect(store.workspaces.length, 2);
      expect(store.workspacesOf(store.folders.single).length, 2);
    });

    test('arquivo que não está lá e workspace sem pasta viram tarja', () async {
      final store = AppStore();
      addTearDown(store.dispose);

      expect(await store.importWorkspace('/nao/existe.code-workspace'), isNull);
      expect(store.banner, startsWith('Não consegui ler esse workspace'));

      final dir = Directory.systemTemp.createTempSync('maestria-ws-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final vazio = File('${dir.path}/vazio.code-workspace')
        ..writeAsStringSync('{"folders": []}');

      expect(await store.importWorkspace(vazio.path), isNull);
      expect(store.banner, 'O workspace "vazio" não lista nenhuma pasta');
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
      expect(find.text('Escolher workspace…'), findsOneWidget);
      expect(
        find.text('Um .code-workspace adiciona todas as pastas dele de uma vez.'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), '/nao/existe.code-workspace');
      await tester.tap(find.text('Adicionar'));
      await tester.pumpAndSettle();

      expect(store.banner, startsWith('Não consegui ler esse workspace'));
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
        find.text('Um .code-workspace adiciona todas as pastas dele de uma vez.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Escolher workspace…'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Não consegui abrir o seletor — cole aí em cima o caminho do .code-workspace',
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
      await tester.tap(find.text('Escolher workspace…'));
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

      expect(store.workspaces.single.codeWorkspacePath, path);
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

    test('o workspace sobrevive à ida e volta do config', () {
      final ws = Workspace(
        id: 'ws1',
        name: 'atrium',
        collapsed: true,
        codeWorkspacePath: '/repos/atrium.code-workspace',
        folderRoots: ['/repos/a', '/repos/b'],
        collapsedFolders: {'/repos/b'},
      )..tint = MxTint.cyan;
      final back = Workspace.fromJson(ws.toJson())!;

      expect(back.id, 'ws1');
      expect(back.name, 'atrium');
      expect(back.collapsed, isTrue);
      expect(back.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(back.folderRoots, ['/repos/a', '/repos/b']);
      expect(back.collapsedFolders, {'/repos/b'});
      expect(back.tint, MxTint.cyan);
      // Sem arquivo é o caso comum agora, e o que não existe não vai pro json.
      final plain = Workspace(id: 'ws2', name: 'uplii').toJson();
      expect(plain.containsKey('codeWorkspacePath'), isFalse);
      expect(plain.containsKey('collapsed'), isFalse);
      // E o registro que não desenharia nada não volta.
      expect(Workspace.fromJson({'id': 'x'}), isNull);
      expect(Workspace.fromJson('nada'), isNull);
    });

    test('o workspace da 2.4.0 ganha id e guarda o arquivo de onde veio', () {
      final back = Workspace.fromJson({
        'path': '/repos/atrium.code-workspace',
        'name': 'atrium',
        'collapsed': true,
      })!;

      expect(back.id, isNotEmpty);
      expect(back.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(back.collapsed, isTrue);
      expect(back.folderRoots, isEmpty);
    });
  });

  group('a seção na lateral', () {
    /// Duas pastas de um workspace, uma solta no meio e uma depois.
    AppStore storeWith() {
      final store = AppStore();
      store.folders.addAll([
        Folder(root: '/repo/api', name: 'api')..isRepo = true,
        Folder(root: '/repo/solta', name: 'solta')..isRepo = true,
        Folder(root: '/repo/web', name: 'web')..isRepo = true,
      ]);
      store.workspaces.add(
        Workspace(
          id: 'ws1',
          name: 'cefis',
          codeWorkspacePath: '/repos/cefis.code-workspace',
          folderRoots: ['/repo/api', '/repo/web'],
        ),
      );
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

    // Um workspace criado na mão não some porque ficou vazio: seria perder o
    // ATRIUM ao tirar o último repo dele.
    test('tirar a última pasta deixa a seção vazia, e não a desfaz', () async {
      final store = storeWith();
      addTearDown(store.dispose);

      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'api'));
      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'web'));

      expect(store.workspaces.single.folderRoots, isEmpty);
      expect(store.sidebarRows.whereType<Workspace>().single.name, 'cefis');
    });
  });

  // A volta do import: ele põe as pastas, isto tira. Nada toca o disco.
  group('fechar um workspace', () {
    AppStore storeWith() {
      final store = AppStore();
      store.folders.addAll([
        Folder(root: '/repo/api', name: 'api')..isRepo = true,
        Folder(root: '/repo/solta', name: 'solta')..isRepo = true,
        Folder(root: '/repo/web', name: 'web')..isRepo = true,
      ]);
      store.workspaces.add(
        Workspace(
          id: 'ws1',
          name: 'cefis',
          codeWorkspacePath: '/repos/cefis.code-workspace',
          folderRoots: ['/repo/api', '/repo/web'],
        ),
      );
      return store;
    }

    test('leva as pastas dele e a seção, e não encosta nas outras', () async {
      final store = storeWith();
      addTearDown(store.dispose);

      await store.closeWorkspace(store.workspaces.single);

      expect(store.workspaces, isEmpty);
      expect(store.folders.map((f) => f.name), ['solta']);
      expect(store.banner, 'Workspace "cefis" fechado — 2 pastas saíram da lateral');
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
      expect(find.text('Fechar workspace…'), findsOneWidget);

      await tester.tap(find.text('Fechar workspace…'));
      await tester.pumpAndSettle();

      // Os dois fatos que decidem a resposta, e o que o diálogo *não* faz.
      expect(find.text('Fechar cefis?'), findsOneWidget);
      expect(find.text('2 pastas saem da lateral'), findsOneWidget);
      expect(find.text('1 sessão aberta é encerrada'), findsOneWidget);
      expect(
        find.text('Nada é apagado do disco — nem os repos, nem o .code-workspace'),
        findsOneWidget,
      );

      // E cancelar não fecha nada.
      await tester.tap(find.text('Cancelar'));
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
      await tester.tap(find.text('Fechar workspace…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fechar workspace'));
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

  group('migrar o config da 2.4.0', () {
    Map<String, dynamic> fixture() =>
        jsonDecode(File('test/fixtures/config-2.4.0.json').readAsStringSync())
            as Map<String, dynamic>;

    test('as pastas carimbadas entram no workspace do arquivo delas', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      final atrium = store.workspaces.firstWhere((w) => w.name == 'atrium');
      expect(atrium.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(atrium.folderRoots, ['/repos/atrium-backend', '/repos/atrium-frontend']);
      expect(atrium.collapsed, isTrue);
    });

    // A 2.4.0 recriava a seção a partir do carimbo quando a lista de
    // workspaces não a tinha. A migração faz o mesmo, com o nome do arquivo.
    test('o carimbo sem seção vira um workspace com o nome do arquivo', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      final uplii = store.workspaces.firstWhere((w) => w.name == 'uplii');
      expect(uplii.codeWorkspacePath, '/repos/uplii.code-workspace');
      expect(uplii.folderRoots, ['/repos/uplii-ai']);
    });

    test('a lateral fica na mesma ordem e as features nas mesmas pastas', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      expect(
        store.sidebarRows.map((r) => r is Workspace ? 'ws:${r.name}' : (r as Folder).name),
        ['ws:atrium', 'solta', 'ws:uplii'],
      );
      expect(store.featuresOrHotfixes.single.folderRoot, '/repos/atrium-backend');
    });

    test('a pasta carimbada dobrada continua dobrada dentro do workspace', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      // O `collapsed` da 2.4.0 era um só por pasta; dentro de um workspace ele
      // passa a valer pra aparição naquele workspace.
      final atrium = store.workspaces.firstWhere((w) => w.name == 'atrium');
      final front = store.folders.firstWhere((f) => f.name == 'atrium-frontend');
      expect(store.isFolderCollapsed(front, within: atrium), isTrue);
    });
  });

  group('montar workspaces na mão', () {
    AppStore three() {
      final store = AppStore();
      for (final n in ['atrium-api', 'atrium-web', 'infra']) {
        store.folders.add(Folder(root: '/repos/$n', name: n));
      }
      return store;
    }

    Folder folder(AppStore s, String name) => s.folders.firstWhere((f) => f.name == name);

    test('criar com nome e pastas, sem arquivo nenhum', () {
      final store = three();
      addTearDown(store.dispose);

      final w = store.createWorkspace(
        ' ATRIUM ',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );

      expect(w.name, 'ATRIUM');
      expect(w.codeWorkspacePath, isNull);
      expect(store.foldersOf(w).map((f) => f.name), ['atrium-api', 'atrium-web']);
      expect(store.standsAlone(folder(store, 'infra')), isTrue);
      expect(store.standsAlone(folder(store, 'atrium-api')), isFalse);
    });

    test('a mesma pasta em dois workspaces aparece nos dois', () {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      final uplii = store.createWorkspace('UPLII');

      store.addToWorkspace(folder(store, 'infra'), uplii);

      expect(store.workspacesOf(folder(store, 'infra')), [atrium, uplii]);
      expect(store.foldersOf(uplii).single.name, 'infra');
    });

    test('adicionar duas vezes não repete', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('ATRIUM');

      store.addToWorkspace(folder(store, 'infra'), w);
      store.addToWorkspace(folder(store, 'infra'), w);

      expect(w.folderRoots, ['/repos/infra']);
    });

    test('entrar antes de uma pasta põe na vaga dela', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );

      store.addToWorkspace(folder(store, 'infra'), w, before: folder(store, 'atrium-web'));

      expect(store.foldersOf(w).map((f) => f.name), ['atrium-api', 'infra', 'atrium-web']);
    });

    test('tirar do último workspace devolve a pasta pra raiz, no lugar pedido', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('ATRIUM', folders: [folder(store, 'atrium-api')]);

      store.removeFromWorkspace(folder(store, 'atrium-api'), w, at: folder(store, 'infra'));

      expect(store.foldersOf(w), isEmpty);
      expect(
        store.sidebarRows.map((r) => r is Workspace ? 'ws:${r.name}' : (r as Folder).name),
        ['atrium-web', 'atrium-api', 'infra', 'ws:ATRIUM'],
      );
    });

    test('tirar de um de dois workspaces não a solta na raiz', () {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      store.removeFromWorkspace(folder(store, 'infra'), atrium);

      expect(store.standsAlone(folder(store, 'infra')), isFalse);
      expect(store.sidebarRows.whereType<Folder>().map((f) => f.name), ['atrium-api', 'atrium-web']);
    });

    test('desfazer devolve as pastas pra raiz no lugar da seção, sem fechar nada', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );
      store.tabs.add(
        MxTab(
          id: 't1',
          folder: folder(store, 'atrium-api'),
          kind: TabKind.shell,
          cwd: '/repos/atrium-api',
          branch: '',
        ),
      );

      store.dissolveWorkspace(w);

      expect(store.workspaces, isEmpty);
      expect(store.tabs.length, 1);
      expect(store.sidebarRows.map((r) => (r as Folder).name), ['infra', 'atrium-api', 'atrium-web']);
    });

    test('fechar leva as pastas só dele e deixa a espelhada no outro', () async {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'infra')],
      );
      final uplii = store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      expect(store.closingWith(atrium).map((f) => f.name), ['atrium-api']);
      await store.closeWorkspace(atrium);

      expect(store.folders.map((f) => f.name), ['atrium-web', 'infra']);
      expect(store.workspaces, [uplii]);
      expect(store.foldersOf(uplii).single.name, 'infra');
    });

    test('remover a pasta tira ela de todos os workspaces', () async {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      final uplii = store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      await store.removeFolder(folder(store, 'infra'));

      expect(atrium.folderRoots, isEmpty);
      expect(uplii.folderRoots, isEmpty);
    });

    test('remover a pasta tira o seu lugar no rootOrder, pra re-adicionar no fim', () async {
      final store = three();
      store.dispose();

      // Popula rootOrder criando um workspace
      store.createWorkspace('W');

      // Remove a pasta
      await store.removeFolder(folder(store, 'atrium-api'));

      // Re-adiciona a pasta com a mesma raiz
      store.folders.add(Folder(root: '/repos/atrium-api', name: 'atrium-api'));

      // Verifica que a pasta aparece no fim
      expect(
        store.sidebarRows.map((r) => r is Workspace ? 'ws:${r.name}' : (r as Folder).name),
        ['atrium-web', 'infra', 'ws:W', 'atrium-api'],
      );
    });

    test('cada aparição dobra por conta própria', () {
      final store = three();
      addTearDown(store.dispose);
      final infra = folder(store, 'infra');
      final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
      final uplii = store.createWorkspace('UPLII', folders: [infra]);

      store.toggleFolderCollapsed(infra, within: atrium);

      expect(store.isFolderCollapsed(infra, within: atrium), isTrue);
      expect(store.isFolderCollapsed(infra, within: uplii), isFalse);
      expect(infra.collapsed, isFalse);
    });

    test('um nome vazio não cria workspace', () {
      final store = three();
      addTearDown(store.dispose);
      expect(() => store.createWorkspace('   '), throwsArgumentError);
      expect(store.workspaces, isEmpty);
    });

    test('renomear, pintar e associar um arquivo', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('atrium');

      store.renameWorkspace(w, '  ATRIUM ');
      store.setWorkspaceTint(w, MxTint.red);
      store.linkCodeWorkspace(w, '/repos/atrium.code-workspace');

      expect(w.name, 'ATRIUM');
      expect(w.tint, MxTint.red);
      expect(w.codeWorkspacePath, '/repos/atrium.code-workspace');

      store.linkCodeWorkspace(w, null);
      expect(w.codeWorkspacePath, isNull);
    });

    test('o painel sem cor pega a do primeiro workspace da pasta', () {
      final store = three();
      addTearDown(store.dispose);
      final infra = folder(store, 'infra');
      store.createWorkspace('ATRIUM', folders: [infra]).tint = MxTint.red;
      store.createWorkspace('UPLII', folders: [infra]).tint = MxTint.cyan;
      final tab = MxTab(id: 't1', folder: infra, kind: TabKind.shell, cwd: infra.root, branch: '');
      store.tabs.add(tab);

      expect(store.chosenTintOf(tab), MxTint.red);
      // E a cor da pasta, quando ela tem uma, vence a do workspace.
      store.setFolderTint(infra, MxTint.green);
      expect(store.chosenTintOf(tab), MxTint.green);
    });

    test('o config grava o workspace novo e a ordem da raiz', () async {
      final store = three();
      addTearDown(store.dispose);
      final file = File(store.configPath);
      if (file.existsSync()) file.deleteSync();

      store.createWorkspace('ATRIUM', folders: [folder(store, 'atrium-api')]);
      final saved = await savedConfig(store);

      final ws = (saved['workspaces'] as List).single as Map;
      expect(ws['name'], 'ATRIUM');
      expect(ws['folderRoots'], ['/repos/atrium-api']);
      expect(saved['rootOrder'], ['folder:/repos/atrium-web', 'folder:/repos/infra', 'workspace:${ws['id']}']);
      expect((saved['folders'] as List).every((f) => !(f as Map).containsKey('workspace')), isTrue);
    });
  });
}
