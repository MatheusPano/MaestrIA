import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/flow.dart';
import 'package:maestria/ui/sidebar.dart';

/// A sessão que o fluxo pediu, anotada em vez de aberta.
///
/// [AppStore.openClaude] de verdade sobe um pty com o `claude` da máquina. O
/// que está em teste é o *pedido* -- a pasta, o nome e o prompt de abertura --
/// e a fila que fica pendurada no painel que ele devolve.
class NoPty extends AppStore {
  final List<Map<String, String?>> abertas = [];

  @override
  MxTab openClaude(
    Folder f, {
    required String cwd,
    String? label,
    String? resumeId,
    Project? project,
    String? prompt,
  }) {
    abertas.add({'cwd': cwd, 'label': label, 'prompt': prompt});
    final tab = MxTab(
      id: 'novo${abertas.length}',
      folder: f,
      kind: TabKind.claude,
      cwd: cwd,
      branch: '',
      customLabel: label,
    );
    tabs.add(tab);
    return tab;
  }
}

final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;

(NoPty, MxTab) storeWithPanel() {
  final store = NoPty();
  store.folders.add(folder);
  final tab = MxTab(
    id: 't1',
    folder: folder,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'implementa',
  );
  store.tabs.add(tab);
  return (store, tab);
}

/// Abre o diálogo pelo botão, que é o que um menu faz.
Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) show) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(onPressed: () => show(ctx), child: const Text('abrir')),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

/// A lateral, larga o bastante pras linhas caberem -- ver worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  group('a ninhada de um fluxo', () {
    // Os painéis que um fluxo abre eram linhas soltas, às vezes com o mesmo
    // nome, e nada dizia que eram uma coisa só acontecendo.
    testWidgets('entra um degrau adentro, embaixo de quem a abriu', (tester) async {
      final (store, tab) = storeWithPanel();
      final filho = MxTab(
        id: 't2',
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: 'flutter test',
      )..bornOf = tab.id;
      final avulso = MxTab(
        id: 't3',
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: 'outra coisa',
      );
      store.tabs.addAll([filho, avulso]);

      await pumpSidebar(tester, store);
      final pai = tester.getTopLeft(find.text('implementa')).dx;
      expect(tester.getTopLeft(find.text('flutter test')).dx, greaterThan(pai));
      expect(
        tester.getTopLeft(find.text('outra coisa')).dx,
        pai,
        reason: 'quem não é do fluxo não recua',
      );
    });

    // Arrastar uma linha pra outro lugar é dizer que ela vale sozinha: a
    // lateral não guarda um vínculo que a lista já desmentiu.
    testWidgets('desfeita quando a linha sai de trás do pai', (tester) async {
      final (store, tab) = storeWithPanel();
      final meio = MxTab(
        id: 't2',
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: 'outra coisa',
      );
      final filho = MxTab(
        id: 't3',
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: 'flutter test',
      )..bornOf = tab.id;
      store.tabs.addAll([meio, filho]);

      await pumpSidebar(tester, store);
      expect(
        tester.getTopLeft(find.text('flutter test')).dx,
        tester.getTopLeft(find.text('implementa')).dx,
      );
    });
  });

  group('o editor de fluxo', () {
    testWidgets('arma o painel com o passo escrito', (tester) async {
      final (store, tab) = storeWithPanel();
      await open(tester, (ctx) => showFlow(ctx, store, tab));

      expect(find.text('quando essa sessão terminar'), findsOneWidget);
      expect(find.text('por onde o fluxo começa?'), findsOneWidget);

      // Com a lista vazia as quatro ofertas são a única coisa com esse nome
      // na tela; depois do primeiro passo elas dividem o nome com a ficha de
      // tipo do cartão, que é a mesma palavra.
      await tester.tap(find.text('continuar'));
      await tester.pumpAndSettle();
      expect(find.text('e depois?'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'agora roda os testes');
      await tester.pumpAndSettle();
      await tester.tap(find.text('armar'));
      await tester.pumpAndSettle();

      expect(tab.followUps.single.kind, FollowUpKind.keepGoing);
      expect(tab.followUps.single.text, 'agora roda os testes');
      store.dispose();
    });

    // A fila armada sobre uma sessão que já parou não tem gatilho pela frente:
    // o botão diz o que vai acontecer, e o que vai acontecer é agora.
    testWidgets('sobre uma sessão já parada, o botão dispara', (tester) async {
      final (store, tab) = storeWithPanel();
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));

      await open(tester, (ctx) => showFlow(ctx, store, tab));
      await tester.tap(find.text('comando'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'make test');
      await tester.pumpAndSettle();

      expect(find.text('disparar'), findsOneWidget);
      await tester.tap(find.text('disparar'));
      await tester.pumpAndSettle();
      expect(tab.armed, isTrue);
      store.dispose();
    });

    // O caso que fazia o fluxo sair cedo, dito na cara do gatilho: a sessão
    // está ociosa e mesmo assim ninguém vai disparar nada.
    testWidgets('diz que está esperando os agentes da sessão', (tester) async {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [FollowUp(kind: FollowUpKind.keepGoing, text: 'segue')]);
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Agent'}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Agent'}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));

      await open(tester, (ctx) => showFlow(ctx, store, tab));
      expect(find.textContaining('2 agentes rodando'), findsOneWidget);
      expect(find.textContaining('esperando os agentes que ela abriu'), findsOneWidget);
      store.dispose();
    });

    // O fluxo que não precisa de painel nenhum pra existir.
    testWidgets('sem sessão nenhuma, abre a primeira com o fluxo pendurado', (tester) async {
      final store = NoPty()..folders.add(folder);
      await open(tester, (ctx) => showNewFlow(ctx, store, folder: folder));

      expect(find.text('abre uma sessão em meu-repo'), findsOneWidget);
      // Sem prompt não há fluxo: o primeiro passo é a sessão.
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(0), 'refatorar o store');
      await tester.enterText(find.byType(TextField).at(1), 'quebra o store em dois');
      await tester.pumpAndSettle();
      await tester.tap(find.text('outra sessão'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('abrir e armar'));
      await tester.pumpAndSettle();

      expect(store.abertas.single['prompt'], 'quebra o store em dois');
      expect(store.abertas.single['label'], 'refatorar o store');
      expect(store.abertas.single['cwd'], '/repo');
      final tab = store.tabs.single;
      expect(tab.followUps.single.kind, FollowUpKind.newSession);
      expect(tab.followUps.single.text, contains('git diff'));
      store.dispose();
    });
  });
}
