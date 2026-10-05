import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/notices.dart';

(AppStore, MxTab, MxTab) storeWithTwo() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
  store.folders.add(folder);
  MxTab make(String id, String label) => MxTab(
    id: id,
    folder: folder,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: label,
  );
  final a = make('a', 'implementa');
  final b = make('b', 'revisa');
  store.tabs.addAll([a, b]);
  // Olhando pro b: o que o a faz acontece fora da sua vista.
  store.panes = PaneLeaf(b.id);
  store.focusedPaneId = b.id;
  return (store, a, b);
}

void hook(AppStore store, MxTab tab, String name, [Map<String, dynamic> payload = const {}]) =>
    store.applyHook(HookEvent(tab.id, name, payload));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('um turno que termina fora da vista entra no sino como não lido', () {
    final (store, a, _) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');

    expect(store.notices, hasLength(1));
    expect(store.notices.first.kind, MxNoticeKind.finished);
    expect(store.notices.first.tabId, a.id);
    expect(store.unreadNotices, 1);

    // O segundo Stop não é uma segunda parada.
    hook(store, a, 'Stop');
    expect(store.notices, hasLength(1));
    store.dispose();
  });

  test('uma pergunta e um pedido de aprovação entram cada um com o seu tipo', () {
    final (store, a, b) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': {}});
    store.panes = PaneLeaf(a.id);
    store.focusedPaneId = a.id;
    hook(store, b, 'UserPromptSubmit');
    hook(store, b, 'PreToolUse', {'tool_name': 'Bash', 'tool_input': {}});
    hook(store, b, 'Notification', {'notification_type': 'permission_prompt'});

    expect(store.notices.map((n) => n.kind), [MxNoticeKind.permission, MxNoticeKind.question]);
    // Aprovado, ele volta a trabalhar e o pedido deixa de estar pendente.
    hook(store, b, 'PostToolUse');
    expect(store.notices.first.read, isTrue);
    store.dispose();
  });

  test('o que termina na sua frente entra já lido', () {
    final (store, _, b) = storeWithTwo();
    hook(store, b, 'UserPromptSubmit');
    hook(store, b, 'Stop');
    expect(store.notices, hasLength(1));
    expect(store.unreadNotices, 0);
    store.dispose();
  });

  test('clicar no aviso leva ao painel e dá o aviso por lido', () {
    final (store, a, _) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');
    store.noticesOpen = true;

    store.openNotice(store.notices.first);

    expect(store.focusedPaneId, a.id);
    expect(store.unreadNotices, 0);
    expect(store.noticesOpen, isFalse);
    store.dispose();
  });

  test('voltar a trabalhar aposenta o aviso de antes', () {
    final (store, a, _) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');
    hook(store, a, 'UserPromptSubmit');
    expect(store.unreadNotices, 0);
    expect(store.notices, hasLength(1));
    store.dispose();
  });

  testWidgets('a linha diz o nome de agora do painel, não o da hora do aviso', (tester) async {
    final (store, a, _) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');
    a.customLabel = 'novo nome';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: NoticeCenter(store: store),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('novo nome', findRichText: true), findsOneWidget);
    expect(find.textContaining('terminou o trabalho', findRichText: true), findsOneWidget);
    store.dispose();
  });

  testWidgets('a barra de status conta as sessões e o sino abre a lista', (tester) async {
    final (store, a, _) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedBuilder(
              animation: store,
              builder: (_, _) => StatusBar(store: store),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('2 sessões', findRichText: true), findsOneWidget);
    // O número ao lado do sino é o do que você não viu.
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.notifications_outlined));
    await tester.pump();
    expect(store.noticesOpen, isTrue);
    store.dispose();
  });

  test('a lista das sessões e a do sino não ficam abertas juntas', () {
    final (store, _, _) = storeWithTwo();
    store.toggleNotices();
    store.toggleSessions();
    expect(store.sessionsOpen, isTrue);
    expect(store.noticesOpen, isFalse);
    store.toggleNotices();
    expect(store.noticesOpen, isTrue);
    expect(store.sessionsOpen, isFalse);
    store.dispose();
  });

  testWidgets('o resumo da barra abre a lista das sessões, e a linha leva à sessão', (
    tester,
  ) async {
    final (store, a, b) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'PreToolUse', {'tool_name': 'AskUserQuestion', 'tool_input': {}});
    expect(a.status.needsHuman, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: store,
            builder: (_, _) => Column(
              children: [
                if (store.sessionsOpen) SessionList(store: store),
                const Spacer(),
                StatusBar(store: store),
              ],
            ),
          ),
        ),
      ),
    );

    // O alvo é o texto, não a barra inteira até o sino.
    final summary = find.textContaining('2 sessões', findRichText: true);
    final target = find.ancestor(of: summary, matching: find.byType(GestureDetector)).first;
    expect(tester.getSize(target).width, lessThan(tester.getSize(summary).width + 20));

    await tester.tap(summary);
    // Sem `pumpAndSettle`: o avatar de quem pergunta pulsa enquanto espera.
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.sessionsOpen, isTrue);
    // A que espera você vem no bloco dela, e a outra no das abertas.
    expect(find.text('Esperando você  1'), findsOneWidget);
    expect(find.text('Abertas  1'), findsOneWidget);
    expect(find.text(b.title), findsOneWidget);

    await tester.tap(find.text(a.title));
    await tester.pump();
    expect(store.sessionsOpen, isFalse);
    expect(store.focusedPaneId, a.id);
    store.dispose();
  });

  group('na tela', () {
    test('o que chega fora da vista sobe num cartão; o da sua frente, não', () {
      final (store, a, b) = storeWithTwo();
      hook(store, b, 'UserPromptSubmit');
      hook(store, b, 'Stop');
      expect(store.toasts, isEmpty);

      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      expect(store.toasts, [store.notices.first]);
      store.dispose();
    });

    test('tirar o cartão da tela deixa a linha no sino', () {
      final (store, a, _) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');

      store.dismissToast(store.toasts.single);

      expect(store.toasts, isEmpty);
      expect(store.notices, hasLength(1));
      expect(store.unreadNotices, 1);
      store.dispose();
    });

    test('voltar a trabalhar tira o cartão, como apaga o ponto', () {
      final (store, a, _) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      hook(store, a, 'UserPromptSubmit');
      expect(store.toasts, isEmpty);
      store.dispose();
    });

    test('não perturbe: entra no sino, não sobe na tela', () {
      final (store, a, b) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      expect(store.toasts, hasLength(1));

      // Ligar cala o que já estava na tela.
      store.setDoNotDisturb(true);
      expect(store.toasts, isEmpty);

      store.panes = PaneLeaf(a.id);
      store.focusedPaneId = a.id;
      hook(store, b, 'UserPromptSubmit');
      hook(store, b, 'Stop');
      expect(store.toasts, isEmpty);
      expect(store.unreadNotices, 2);
      store.dispose();
    });

    test('abrir a lista tira os cartões', () {
      final (store, a, _) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      store.toggleNotices();
      expect(store.toasts, isEmpty);
      store.dispose();
    });

    testWidgets('o cartão sai sozinho, mas não com o ponteiro em cima', (tester) async {
      final (store, a, _) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      final n = store.toasts.single;

      store.holdToast(n, true);
      await tester.pump(AppStore.toastLife * 2);
      expect(store.toasts, [n]);

      store.holdToast(n, false);
      await tester.pump(AppStore.toastLife);
      expect(store.toasts, isEmpty);
      store.dispose();
    });

    testWidgets('o cartão leva ao painel', (tester) async {
      final (store, a, _) = storeWithTwo();
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: NoticeToast(store: store, notice: store.toasts.single),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('terminou o trabalho', findRichText: true));
      expect(store.focusedPaneId, a.id);
      expect(store.toasts, isEmpty);
      expect(store.unreadNotices, 0);
      store.dispose();
    });

    testWidgets('o cartão entra deslizando e sai pelo mesmo lado', (tester) async {
      final (store, a, _) = storeWithTwo();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(alignment: Alignment.bottomRight, child: NoticeToasts(store: store)),
          ),
        ),
      );
      hook(store, a, 'UserPromptSubmit');
      hook(store, a, 'Stop');
      await tester.pump();
      final card = find.byType(NoticeToast);
      expect(card, findsOneWidget);

      await tester.pumpAndSettle();
      final rest = tester.getTopLeft(card).dx;
      // Parado no canto direito, não esticado até a esquerda.
      expect(tester.getTopRight(card).dx, 800);
      expect(tester.getSize(card).width, NoticeCenter.width);

      store.dismissToast(store.notices.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      // No meio da saída: ainda na tela, e mais pra direita que parado.
      expect(card, findsOneWidget);
      expect(tester.getTopLeft(find.byType(Container).last).dx, greaterThan(rest));

      await tester.pumpAndSettle();
      expect(card, findsNothing);
      store.dispose();
    });
  });

  testWidgets('limpar tudo faz as linhas saírem antes de esvaziar o sino', (tester) async {
    final (store, a, b) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');
    hook(store, b, 'UserPromptSubmit');
    hook(store, b, 'Stop');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: AnimatedBuilder(
              animation: store,
              builder: (_, _) => NoticeCenter(store: store),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final height = tester.getSize(find.byType(NoticeCenter)).height;

    await tester.tap(find.byIcon(Icons.clear_all_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    // Saindo, mas ainda no sino -- e sem fechar o vão: o cartão só encolhe
    // quando a cascata acaba.
    expect(store.notices, hasLength(2));
    expect(tester.getSize(find.byType(NoticeCenter)).height, height);

    await tester.pumpAndSettle();
    expect(store.notices, isEmpty);
    expect(find.textContaining('Nenhuma notificação'), findsOneWidget);
    expect(tester.getSize(find.byType(NoticeCenter)).height, lessThan(height));
    store.dispose();
  });

  testWidgets('fechar o sino no meio do limpar tudo ainda limpa', (tester) async {
    final (store, a, b) = storeWithTwo();
    hook(store, a, 'UserPromptSubmit');
    hook(store, a, 'Stop');
    hook(store, b, 'UserPromptSubmit');
    hook(store, b, 'Stop');

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: NoticeCenter(store: store))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.clear_all_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(store.notices, isEmpty);
    store.dispose();
  });
}
