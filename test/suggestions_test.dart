import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/task_mcp.dart';
import 'package:maestria/ui/notices.dart';
import 'package:maestria/ui/suggestions.dart';

/// Um store com uma sessão fora da vista, como em `notices_test.dart`.
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppStore como TaskDesk', () {
    test('a sugestão fica no painel e entra no sino', () {
      final (store, a) = storeWithOne();
      final queued = store.suggest('a', title: 'Converter SQL', tldr: 'resumo', prompt: 'faça');
      expect(queued, isNotNull);
      expect(queued!.task.id, matches(RegExp(r'^task_[0-9a-f]{8}$')));
      expect(a.hooks.suggestions, [queued.task]);
      expect(store.notices.single.kind, MxNoticeKind.suggested);
      expect(store.unreadNotices, 1);
      expect(a.toJson()['suggestions'], hasLength(1));
      store.dispose();
    });

    test('a sessão seguir trabalhando não apaga o aviso da sugestão', () {
      final (store, a) = storeWithOne();
      store.applyHook(HookEvent('a', 'UserPromptSubmit', const {}));
      store.applyHook(
        HookEvent('a', 'PreToolUse', const {'tool_name': 'mcp__maestria__suggest_task'}),
      );
      store.suggest('a', title: 'x', tldr: '', prompt: 'y');
      store.applyHook(HookEvent('a', 'PostToolUse', const {}));
      expect(store.notices.single.read, isFalse);
      store.dispose();
    });

    test('a sessão retira; a segunda tentativa ouve que já saiu', () {
      final (store, a) = storeWithOne();
      final id = store.suggest('a', title: 'x', tldr: '', prompt: 'y')!.task.id;
      expect(store.withdraw('a', id).withdrawn, isTrue);
      expect(a.hooks.suggestions, isEmpty);
      final again = store.withdraw('a', id);
      expect(again.withdrawn, isFalse);
      expect(again.already, SuggestionEnd.dismissed);
      store.dispose();
    });

    test('painel que não é sessão do claude não recebe sugestão', () {
      final (store, _) = storeWithOne();
      expect(store.suggest('nenhum', title: 'x', tldr: '', prompt: 'y'), isNull);
      store.dispose();
    });

    test('passado o teto, a mais velha sai', () {
      final (store, a) = storeWithOne();
      final first = store.suggest('a', title: '0', tldr: '', prompt: 'y')!.task;
      for (var i = 1; i < HookState.maxSuggestions; i++) {
        store.suggest('a', title: '$i', tldr: '', prompt: 'y');
      }
      final last = store.suggest('a', title: 'nova', tldr: '', prompt: 'y')!;
      expect(last.evicted, [first]);
      expect(a.hooks.suggestions, hasLength(HookState.maxSuggestions));
      store.dispose();
    });
  });

  group('o aviso da sugestão', () {
    test('sabe qual sugestão anuncia, enquanto ela está de pé', () {
      final (store, a) = storeWithOne();
      final task = store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'y')!.task;
      final notice = store.notices.single;
      expect(notice.suggestionId, task.id);
      expect(notice.detail, 'Converter SQL');
      expect(store.suggestionOf(notice), task);

      store.dismissSuggestion(a, task);
      // Resolvida, o aviso volta a ser só o caminho até o painel -- mas
      // continua dizendo o que foi sugerido.
      expect(store.suggestionOf(notice), isNull);
      expect(notice.detail, 'Converter SQL');
      store.dispose();
    });

    test('aviso que não é de sugestão não aponta pra nenhuma', () {
      final (store, a) = storeWithOne();
      store.applyHook(HookEvent('a', 'UserPromptSubmit', const {}));
      store.applyHook(HookEvent('a', 'Stop', const {}));
      expect(store.notices.single.kind, MxNoticeKind.finished);
      expect(store.suggestionOf(store.notices.single), isNull);
      store.dispose();
    });

    Future<void> pumpToast(WidgetTester tester, AppStore store) async {
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
    }

    testWidgets('o clique leva ao painel e abre o cartão da sugestão', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: 'O guia está em PostgreSQL.', prompt: 'y');
      await pumpToast(tester, store);

      expect(
        find.textContaining('sugeriu uma tarefa: Converter SQL', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('sugeriu uma tarefa', findRichText: true));
      await tester.pumpAndSettle();

      expect(store.focusedPaneId, a.id);
      expect(find.text('tarefa sugerida por implementa'), findsOneWidget);
      expect(find.text('O guia está em PostgreSQL.'), findsOneWidget);
      store.dispose();
    });

    testWidgets('com a sugestão resolvida, o clique só leva ao painel', (tester) async {
      final (store, a) = storeWithOne();
      final task = store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'y')!.task;
      await pumpToast(tester, store);
      store.withdraw('a', task.id);
      await tester.pump();

      await tester.tap(find.textContaining('sugeriu uma tarefa', findRichText: true));
      await tester.pumpAndSettle();

      expect(store.focusedPaneId, a.id);
      expect(find.byType(AlertDialog), findsNothing);
      store.dispose();
    });
  });

  group('cartão no canto do terminal', () {
    Future<void> pumpCard(
      WidgetTester tester,
      AppStore store,
      MxTab tab, {
      double width = 600,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: 400,
                child: ListenableBuilder(
                  listenable: store,
                  builder: (_, _) => Stack(
                    children: [
                      if (SuggestionCard.has(tab))
                        Positioned(
                          left: SuggestionCard.inset,
                          right: SuggestionCard.inset,
                          bottom: SuggestionCard.inset,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: SuggestionCard(store: store, tab: tab),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('mostra a mais nova, e as setas andam entre elas', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Primeira', tldr: 'a velha', prompt: 'y');
      store.suggest('a', title: 'Segunda', tldr: 'a nova', prompt: 'y');
      await pumpCard(tester, store, a);

      expect(find.text('Segunda'), findsOneWidget);
      expect(find.text('a nova'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      await tester.tap(find.byTooltip('a próxima'));
      await tester.pumpAndSettle();
      expect(find.text('Primeira'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
      store.dispose();
    });

    testWidgets('descartar tira a sugestão e o cartão some com a última', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'y');
      await pumpCard(tester, store, a);

      await tester.tap(find.byTooltip('descartar'));
      await tester.pumpAndSettle();
      expect(a.hooks.suggestions, isEmpty);
      expect(find.byType(SuggestionCard), findsNothing);
      store.dispose();
    });

    testWidgets('recolhido vira um selo, e uma sugestão nova o abre de novo', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Primeira', tldr: '', prompt: 'y');
      await pumpCard(tester, store, a);

      await tester.tap(find.byTooltip('recolher'));
      await tester.pumpAndSettle();
      expect(find.text('Primeira'), findsNothing);
      expect(find.text('1 sugestão'), findsOneWidget);

      store.suggest('a', title: 'Segunda', tldr: '', prompt: 'y');
      await tester.pumpAndSettle();
      expect(find.text('Segunda'), findsOneWidget);
      store.dispose();
    });

    testWidgets('detalhes abre o cartão inteiro, com o prompt e as outras saídas', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: 'resumo', prompt: 'y');
      await pumpCard(tester, store, a);

      await tester.tap(find.text('detalhes'));
      await tester.pumpAndSettle();
      expect(find.text('tarefa sugerida por implementa'), findsOneWidget);
      expect(find.text('fazer aqui'), findsOneWidget);
      store.dispose();
    });

    testWidgets('as três formas de iniciar estão no próprio cartão', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: '', prompt: 'faça');
      await pumpCard(tester, store, a);

      expect(find.text('iniciar com worktree'), findsOneWidget);
      await tester.tap(find.byTooltip('outras formas de iniciar'));
      await tester.pumpAndSettle();
      expect(find.text('iniciar localmente'), findsOneWidget);
      expect(find.text('fazer aqui'), findsOneWidget);

      // "fazer aqui" manda o prompt pra esta sessão e tira a sugestão da fila.
      await tester.tap(find.text('fazer aqui'));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(a.hooks.suggestions, isEmpty);
      expect(find.byType(SuggestionCard), findsNothing);
      store.dispose();
    });

    testWidgets('a seta abre as opções dentro do cartão, sem sair de baixo do ponteiro', (
      tester,
    ) async {
      final (store, a) = storeWithOne();
      store.suggest('a', title: 'Converter SQL', tldr: 'resumo', prompt: 'faça');
      await pumpCard(tester, store, a);

      Rect arrow() => tester.getRect(
        find.descendant(of: find.byTooltip(RegExp('formas')), matching: find.byType(FilledButton)),
      );
      final before = arrow();
      final card = tester.getRect(find.byType(SuggestionCard));
      await tester.tap(find.byTooltip('outras formas de iniciar'));
      await tester.pumpAndSettle();

      // Nenhuma camada por cima: as opções são do cartão, que cresceu pra
      // cima -- a base e a seta ficaram onde estavam.
      expect(find.byType(MenuAnchor), findsNothing);
      expect(arrow(), before);
      final grown = tester.getRect(find.byType(SuggestionCard));
      expect(grown.bottom, card.bottom);
      expect(grown.top, lessThan(card.top));

      final title = tester.getRect(find.text('Converter SQL'));
      final here = tester.getRect(find.text('fazer aqui'));
      expect(here.top, greaterThan(title.bottom));
      expect(here.bottom, lessThan(before.top));

      // A seta de novo fecha.
      await tester.tap(find.byTooltip('esconder as outras formas'));
      await tester.pumpAndSettle();
      expect(find.text('fazer aqui'), findsNothing);
      store.dispose();
    });

    testWidgets('nos avulsos a frente é iniciar localmente, e a seta só tem fazer aqui', (
      tester,
    ) async {
      final store = AppStore();
      final tab = MxTab(
        id: 'l',
        folder: store.loose,
        kind: TabKind.claude,
        cwd: '/tmp',
        branch: '',
      );
      store.tabs.add(tab);
      store.suggest('l', title: 'Converter SQL', tldr: '', prompt: 'faça');
      await pumpCard(tester, store, tab);

      expect(find.text('iniciar com worktree'), findsNothing);
      expect(find.text('iniciar localmente'), findsOneWidget);
      await tester.tap(find.byTooltip('outras formas de iniciar'));
      await tester.pumpAndSettle();
      expect(find.text('fazer aqui'), findsOneWidget);
      // Uma só: a da frente não se repete no menu.
      expect(find.text('iniciar localmente'), findsOneWidget);
      store.dispose();
    });

    testWidgets('num painel estreito o cartão encolhe em vez de estourar', (tester) async {
      final (store, a) = storeWithOne();
      store.suggest(
        'a',
        title: 'Um título comprido o bastante pra precisar de reticências no fim',
        tldr: 'um resumo que também não cabe numa linha só de um painel estreito',
        prompt: 'y',
      );
      await pumpCard(tester, store, a, width: 260);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SuggestionCard)).width, lessThanOrEqualTo(260 - 24));
      store.dispose();
    });
  });
}
