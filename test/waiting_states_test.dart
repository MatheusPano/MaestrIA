import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// Two sessions stopped for a human, for two different reasons. The whole
/// point of the pair is that the sidebar must not draw them the same way.
AppStore storeWaiting() {
  final store = AppStore();
  store.folders.add(Folder(root: '/repo', name: 'meu-repo')..isRepo = true);
  final asking = MxTab(
    id: 'asking',
    folder: store.folders.first,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'melhor ui',
  );
  asking.hooks
    ..status = ClaudeStatus.waitingAnswer
    ..question = 'Receitas'
    ..questions = 1;
  final gated = MxTab(
    id: 'gated',
    folder: store.folders.first,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'finalizar projeto',
  );
  gated.hooks
    ..status = ClaudeStatus.waitingPermission
    ..activeTool = 'Bash';
  store.tabs.addAll([asking, gated]);
  return store;
}

Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  testWidgets('a question and a permission prompt do not look alike', (tester) async {
    final store = storeWaiting();
    await pumpSidebar(tester, store);

    // What each row says it wants. Neither says "AskUserQuestion".
    expect(find.text('pergunta: Receitas'), findsOneWidget);
    expect(find.text('quer aprovação pra Bash'), findsOneWidget);
    expect(find.textContaining('AskUserQuestion'), findsNothing);

    // And how each is stamped: one lock in the whole sidebar, on the row that
    // is actually gating something, plus one question mark on the other.
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(find.byIcon(Icons.question_mark_rounded), findsOneWidget);

    store.dispose();
  });

  testWidgets('the count pill takes the colour of what it is counting', (tester) async {
    final store = storeWaiting();
    await pumpSidebar(tester, store);

    final pills = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.child is Text && (c.child as Text).data == '1')
        .map((c) => (c.decoration as BoxDecoration).color)
        .toList();
    // One per waiting row, and not the same colour twice: red is the lock's
    // alone, and a question must not borrow it.
    expect(pills, hasLength(2));
    expect(pills.first, isNot(pills.last));

    store.dispose();
  });
}
