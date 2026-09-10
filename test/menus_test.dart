import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/dialogs.dart';
import 'package:maestria/ui/sidebar.dart';

/// O painel que uma linha de menu pediu.
class Pedido {
  Pedido(this.kind, this.cwd, {this.label, this.project, this.launcher});

  final String kind;
  final String cwd;
  final String? label;
  final String? project;
  final String? launcher;

  @override
  String toString() => '$kind em $cwd (nome $label, projeto $project, programa $launcher)';
}

/// Um store que anota o painel pedido em vez de abrir um.
///
/// [AppStore.openClaude] e [AppStore.openShell] de verdade sobem um pty. O que
/// está em teste aqui é o *pedido* que a linha do menu faz — em que pasta, com
/// que nome, dentro de que projeto —, não o terminal que atenderia a ele.
class NoPty extends AppStore {
  final List<Pedido> pedidos = [];

  Pedido get ultimo => pedidos.last;

  MxTab _fake(String cwd, {String? label, Launcher? launcher}) {
    final tab = MxTab(
      id: 'tab${pedidos.length}',
      folder: folders.isEmpty ? loose : folders.first,
      kind: launcher == null && label == null ? TabKind.claude : TabKind.shell,
      cwd: cwd,
      branch: '',
      customLabel: label,
      launcher: launcher,
    );
    tabs.add(tab);
    return tab;
  }

  @override
  MxTab openClaude(
    Folder f, {
    required String cwd,
    String? label,
    String? resumeId,
    Project? project,
    String? prompt,
  }) {
    pedidos.add(Pedido('claude', cwd, label: label, project: project?.name));
    return _fake(cwd, label: label);
  }

  @override
  MxTab openShell(
    Folder f, {
    String? cwd,
    String? command,
    Project? project,
    Launcher? launcher,
  }) {
    pedidos.add(
      Pedido('shell', cwd ?? f.root, project: project?.name, launcher: launcher?.name),
    );
    return _fake(cwd ?? f.root, launcher: launcher);
  }

  /// O documento pedido, anotado em vez de posto na tela: [AppStore.showDoc]
  /// agenda a escrita do config, e o que está em teste é de que lugar o leitor
  /// nasce -- o `cwd` do pedido -- e qual arquivo o painel nativo devolveu.
  @override
  MxTab? showFile(String path, {MxTab? from, Folder? folder, String? cwd, Project? project}) {
    pedidos.add(
      Pedido('leitor', cwd ?? folder?.root ?? from?.cwd ?? '?', label: path,
          project: project?.name),
    );
    return null;
  }
}

final folder = Folder(root: '/repo', name: 'meu-repo')
  ..isRepo = true
  ..branch = 'master';

final principal = WorktreeInfo(path: '/repo', branch: 'master', isMain: true);
final task = WorktreeInfo(
  path: '/repo/.claude/worktrees/TASK-47730',
  branch: 'feature/TASK#47730',
  isMain: false,
);

NoPty storeWith({Launcher? launcher}) {
  final store = NoPty();
  store.folders.add(folder);
  store.worktrees['/repo'] = [principal, task];
  if (launcher != null) store.launchers.add(launcher);
  return store;
}

/// Abre um menu pelo botão, que é o que a lateral faz ao ser clicada.
Future<void> openMenu(
  WidgetTester tester,
  Future<void> Function(BuildContext ctx) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(onPressed: () => open(ctx), child: const Text('abrir')),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

/// A lateral, larga o bastante pras linhas de cabeçalho caberem — ver
/// worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 700, child: Sidebar(store: store)),
    ),
  ),
);

/// O + de uma pasta, aberto: ele só existe com o ponteiro na linha dela, e o
/// ponteiro fica onde parou pro submenu poder ser apontado em seguida.
Future<TestGesture> openAddMenu(WidgetTester tester, AppStore store) async {
  await pumpSidebar(tester, store);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(find.text('meu-repo')));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('abrir algo nessa pasta'));
  await tester.pumpAndSettle();
  return mouse;
}

/// O botão direito no cabeçalho de uma pasta -- a outra porta do mesmo bloco.
Future<void> openFolderMenu(WidgetTester tester, AppStore store) async {
  await pumpSidebar(tester, store);
  await tester.tap(find.text('meu-repo'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

/// O painel nativo de escolher arquivo, atendido: devolve [picked] e anota em
/// que pasta ele teria aberto, que é o que a linha do menu tem pra dizer.
List<String?> mockPicker(String picked) {
  const dock = MethodChannel('maestria/dock');
  final startIn = <String?>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(dock, (call) async {
    if (call.method != 'chooseMarkdown') return null;
    startIn.add(call.arguments as String?);
    return picked;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(dock, null));
  return startIn;
}

/// Fecha o menu que está aberto. Um submenu de pé no fim do teste é uma
/// [OverlayEntry] sendo removida no meio da desmontagem da árvore.
Future<void> closeMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  group('abrir algo aqui', () {
    // A oferta é a mesma nos três menus porque é escrita uma vez, e a ordem é
    // a das chances de você ter vindo por ela. Ver `openHereItems`.
    testWidgets('a ordem é sessão, terminal, retomar', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final project = store.addProject(folder, 'permissão do google');

      await openMenu(tester, (ctx) => showProjectMenu(ctx, store, folder, project, Offset.zero));

      final sessao = tester.getTopLeft(find.text('sessão do claude')).dy;
      final terminal = tester.getTopLeft(find.text('terminal')).dy;
      final retomar = tester.getTopLeft(find.text('retomar conversa…')).dy;
      expect(sessao, lessThan(terminal));
      expect(terminal, lessThan(retomar));
      // E o que é do menu de baixo vem depois do risco, não no meio da oferta.
      expect(retomar, lessThan(tester.getTopLeft(find.text('renomear')).dy));
      await closeMenu(tester);
    });

    testWidgets('escolher a sessão abre na pasta, sem nome nenhum', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      await openAddMenu(tester, store);

      await tester.tap(find.text('sessão do claude'));
      await tester.pumpAndSettle();

      expect(store.ultimo.kind, 'claude');
      expect(store.ultimo.cwd, '/repo');
      // Sem apelido: o painel se chama pela pasta, que é a regra de sempre.
      expect(store.ultimo.label, isNull);
    });

    // A linha que não é do bloco cai no menu que o embutiu -- é o `false` do
    // `openHereChoice` que faz o switch de lá continuar existindo.
    testWidgets('a escolha que não é do bloco fica pro menu de baixo', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final project = store.addProject(folder, 'permissão do google');

      await openMenu(tester, (ctx) => showProjectMenu(ctx, store, folder, project, Offset.zero));
      await tester.tap(find.text('renomear'));
      await tester.pumpAndSettle();

      expect(find.text('renomear projeto'), findsOneWidget);
      expect(store.pedidos, isEmpty);
    });

    // A terceira porta: o botão direito numa pasta. Antes ele não abria nada
    // -- pra abrir uma sessão você tinha que mirar num + de 18 pixels que só
    // existe com o ponteiro em cima da linha. Ver `showFolderMenu`.
    testWidgets('o botão direito da pasta faz a mesma oferta do + dela', (tester) async {
      final store = storeWith(launcher: Launcher(id: 'lch1', name: 'btop', command: 'btop -t'));
      addTearDown(store.dispose);
      await openFolderMenu(tester, store);

      expect(find.text('sessão do claude'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      // 'conversas de antes…' era esta linha, dita com outro nome só aqui.
      expect(find.text('retomar conversa…'), findsOneWidget);
      expect(find.text('conversas de antes…'), findsNothing);
      expect(find.text('meus programas'), findsOneWidget);
      // E o que sempre foi deste menu continua nele, depois do bloco.
      expect(find.text('worktrees'), findsOneWidget);
      expect(find.text('remover pasta'), findsOneWidget);
      await closeMenu(tester);
    });

    // Ler um `.md` era uma linha do menu do painel, e um markdown não é de uma
    // sessão -- é de uma pasta. Ver `openHereItems` e [AppStore.openMarkdown].
    testWidgets('o markdown é oferecido pelo lugar, e abre na pasta dele', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final startIn = mockPicker('/repo/docs/NOTAS.md');

      await openFolderMenu(tester, store);
      await tester.tap(find.text('abrir um markdown…'));
      await tester.pumpAndSettle();

      // O painel nativo abre na pasta em que se clicou, e não na do painel que
      // por acaso estava em foco.
      expect(startIn, ['/repo']);
      expect(store.ultimo.kind, 'leitor');
      expect(store.ultimo.label, '/repo/docs/NOTAS.md');
      expect(store.ultimo.cwd, '/repo');
    });

    // Na worktree ele abre no checkout dela: o `.md` que se quer ler ali é o
    // daquela pasta, não o do repo-mãe com o mesmo nome.
    testWidgets('e na worktree, no checkout dela', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final startIn = mockPicker('${task.path}/PLANO.md');

      await openMenu(tester, (ctx) => showWorktreeMenu(ctx, store, folder, task, Offset.zero));
      await tester.tap(find.text('abrir um markdown…'));
      await tester.pumpAndSettle();

      expect(startIn, [task.path]);
      expect(store.ultimo.cwd, task.path);
    });

    // E saiu do menu do painel, que é onde ela estava: as linhas de lá são
    // sobre a sessão, e um arquivo do disco não é uma delas.
    testWidgets('o menu do painel não oferece mais markdown', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final tab = MxTab(id: 'tab1', folder: folder, kind: TabKind.claude, cwd: '/repo', branch: '');
      store.tabs.add(tab);

      await openMenu(tester, (ctx) => showPanelMenu(ctx, store, tab, Offset.zero));

      expect(find.text('abrir um markdown…'), findsNothing);
      // O resto do bloco continua lá -- o que saiu é uma linha, não o menu.
      expect(find.text('renomear…'), findsOneWidget);
      expect(find.text('ver o plano'), findsOneWidget);
      await closeMenu(tester);
    });

    testWidgets('e a sessão pedida por ele abre na pasta, solta', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      await openFolderMenu(tester, store);

      await tester.tap(find.text('sessão do claude'));
      await tester.pumpAndSettle();

      expect(store.ultimo.kind, 'claude');
      expect(store.ultimo.cwd, '/repo');
      // Numa pasta e em projeto nenhum: o menu do projeto é o da linha dele.
      expect(store.ultimo.project, isNull);
    });

    testWidgets('no projeto, o painel nasce grudado nele', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);
      final project = store.addProject(folder, 'permissão do google');

      await openMenu(tester, (ctx) => showProjectMenu(ctx, store, folder, project, Offset.zero));
      await tester.tap(find.text('terminal'));
      await tester.pumpAndSettle();

      expect(store.ultimo.kind, 'shell');
      expect(store.ultimo.project, 'permissão do google');
    });
  });

  group('o menu de uma worktree', () {
    testWidgets('a sessão abre na pasta dela, com o nome do branch', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);

      await openMenu(tester, (ctx) => showWorktreeMenu(ctx, store, folder, task, Offset.zero));
      await tester.tap(find.text('sessão do claude'));
      await tester.pumpAndSettle();

      // A pasta da worktree, não a raiz do repo: é o que distingue este painel
      // dos da pasta-mãe -- e abrir na raiz seria abrir em outro checkout.
      expect(store.ultimo.cwd, '/repo/.claude/worktrees/TASK-47730');
      expect(store.ultimo.label, 'TASK#47730');
    });

    testWidgets('o terminal também', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);

      await openMenu(tester, (ctx) => showWorktreeMenu(ctx, store, folder, task, Offset.zero));
      await tester.tap(find.text('terminal'));
      await tester.pumpAndSettle();

      expect(store.ultimo.kind, 'shell');
      expect(store.ultimo.cwd, '/repo/.claude/worktrees/TASK-47730');
    });

    // O checkout principal já se chama pelo nome da pasta na lateral: dar a
    // ele o nome do branch seria batizar de "master" o painel de sempre.
    testWidgets('o checkout principal não ganha nome de branch', (tester) async {
      final store = storeWith();
      addTearDown(store.dispose);

      await openMenu(
        tester,
        (ctx) => showWorktreeMenu(ctx, store, folder, principal, Offset.zero),
      );
      await tester.tap(find.text('sessão do claude'));
      await tester.pumpAndSettle();

      expect(store.ultimo.cwd, '/repo');
      expect(store.ultimo.label, isNull);
    });

    testWidgets('copiar caminho continua sendo do menu de lá', (tester) async {
      final store = storeWith();
      final copiado = <String?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiado.add((call.arguments as Map)['text'] as String?);
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await openMenu(tester, (ctx) => showWorktreeMenu(ctx, store, folder, task, Offset.zero));
      await tester.tap(find.text('copiar caminho'));
      await tester.pumpAndSettle();

      expect(copiado, ['/repo/.claude/worktrees/TASK-47730']);
      expect(store.pedidos, isEmpty);
      expect(store.banner, 'caminho copiado');
      // Antes do fim do teste: o recado tem um prazo de verdade correndo, e um
      // timer de pé é o que o `testWidgets` reclama com a árvore já desmontada.
      store.dispose();
    });
  });

  group('o submenu dos programas', () {
    final btop = Launcher(id: 'lch1', name: 'btop', command: 'btop -t');

    testWidgets('escolher um programa nele abre o painel dele', (tester) async {
      final store = storeWith(launcher: btop);
      addTearDown(store.dispose);
      final mouse = await openAddMenu(tester, store);

      await mouse.moveTo(tester.getCenter(find.text('meus programas')));
      await tester.pumpAndSettle();
      // A linha do submenu, não a do menu: a de cima é 'meus programas'.
      await tester.tap(find.text('btop'));
      await tester.pumpAndSettle();

      // Escolher no submenu fecha o menu de baixo com o valor de lá -- pra
      // quem chamou o `showMenu`, o segundo menu não existiu.
      expect(store.ultimo.launcher, 'btop');
      expect(store.ultimo.cwd, '/repo');
      expect(find.text('meus programas'), findsNothing);
    });

    // Um ponteiro que veio pelo teclado ou por um trackpad de um toque não
    // passou por cima da linha: uma seta que não faz nada ao ser clicada
    // parece quebrada.
    testWidgets('clicar na linha abre o submenu como o hover', (tester) async {
      final store = storeWith(launcher: btop);
      addTearDown(store.dispose);
      await openAddMenu(tester, store);

      expect(find.text('outro programa…'), findsNothing);
      await tester.tap(find.text('meus programas'));
      await tester.pumpAndSettle();

      expect(find.text('outro programa…'), findsOneWidget);
      await closeMenu(tester);
    });

    // O menu de cima indo embora leva o submenu com ele: `dispose` só chega
    // depois da animação de saída, e um submenu flutuando sozinho por um
    // décimo de segundo depois do menu sumir se vê.
    testWidgets('vai embora com o menu que o abriu', (tester) async {
      final store = storeWith(launcher: btop);
      addTearDown(store.dispose);
      final mouse = await openAddMenu(tester, store);

      await mouse.moveTo(tester.getCenter(find.text('meus programas')));
      await tester.pumpAndSettle();
      expect(find.text('outro programa…'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      // Um único frame depois do ⎋: o menu ainda está saindo, e é justamente
      // aí que o submenu não pode estar mais na tela.
      await tester.pump();
      expect(find.text('outro programa…'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('meus programas'), findsNothing);
      expect(store.pedidos, isEmpty);
    });
  });
}
