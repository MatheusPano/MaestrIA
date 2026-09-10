import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// A folder with three worktrees: the main checkout, a live one, and one git
/// calls prunable — the folder is gone, the registration is not.
AppStore storeWith() {
  final store = AppStore();
  store.folders.add(
    Folder(root: '/repo', name: 'meu-repo')
      ..isRepo = true
      ..branch = 'master',
  );
  store.worktrees['/repo'] = [
    WorktreeInfo(path: '/repo', branch: 'master', isMain: true),
    WorktreeInfo(
      path: '/repo/.claude/worktrees/TASK-47730',
      branch: 'feature/TASK#47730',
      isMain: false,
    ),
    WorktreeInfo(
      path: '/repo/.claude/worktrees/TASK-45371',
      branch: 'feature/TASK#45371',
      isMain: false,
      prunable: true,
    ),
  ];
  return store;
}

/// Wider than the real sidebar on purpose: the test font is one square em per
/// character, so a row of branch names and counts needs room it never needs on
/// screen.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 700, child: Sidebar(store: store)),
    ),
  ),
);

/// The gesture the worktrees now live behind: right-click the repo header.
Future<void> openFolderMenu(WidgetTester tester) async {
  await tester.tap(find.text('meu-repo'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  group('the sidebar itself', () {
    testWidgets('says nothing about worktrees — the tree is what is running', (tester) async {
      await pumpSidebar(tester, storeWith());
      expect(find.text('worktrees'), findsNothing);
      expect(find.text('TASK#47730'), findsNothing);
      expect(find.text('meu-repo'), findsOneWidget);
    });

    testWidgets('keeps the one worktree warning on the surface', (tester) async {
      await pumpSidebar(tester, storeWith());
      // The ghost chip on the header: a registration git would prune is the
      // only part of the list that asks for anything.
      expect(find.byIcon(Icons.link_off), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a repo folder is marked as one, and says its branch', (tester) async {
      await pumpSidebar(tester, storeWith());
      expect(find.byType(RepoGlyph), findsOneWidget);
      expect(tester.widget<RepoGlyph>(find.byType(RepoGlyph)).isRepo, isTrue);
      expect(find.text('master'), findsOneWidget);
    });
  });

  group('right-clicking the repo', () {
    testWidgets('offers the worktrees, with how many there are', (tester) async {
      await pumpSidebar(tester, storeWith());
      await openFolderMenu(tester);
      expect(find.text('worktrees'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('remover pasta'), findsOneWidget);
    });

    testWidgets('says nothing about worktrees when there is only the checkout', (tester) async {
      final store = storeWith();
      store.worktrees['/repo'] = [WorktreeInfo(path: '/repo', branch: 'master', isMain: true)];
      await pumpSidebar(tester, store);
      await openFolderMenu(tester);
      // A list whose one entry is the folder you just right-clicked.
      expect(find.text('worktrees'), findsNothing);
      expect(find.text('remover pasta'), findsOneWidget);
    });

    testWidgets('opens onto every worktree of the repo', (tester) async {
      await pumpSidebar(tester, storeWith());
      await openFolderMenu(tester);
      await tester.tap(find.text('worktrees'));
      await tester.pumpAndSettle();

      expect(find.text('TASK#47730'), findsOneWidget);
      expect(find.text('TASK#45371'), findsOneWidget);
      expect(find.text('sem pasta no disco'), findsOneWidget);
      // The main checkout goes by the folder's name, in the list and nowhere
      // else now: the header behind it is the second one on screen.
      expect(find.text('meu-repo'), findsNWidgets(2));
      // Cleaning up the ghosts is about the list, so it sits in the list.
      expect(find.text('limpar worktrees fantasmas'), findsOneWidget);
    });

    testWidgets('picking one opens what you can do to it', (tester) async {
      await pumpSidebar(tester, storeWith());
      await openFolderMenu(tester);
      await tester.tap(find.text('worktrees'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TASK#47730'));
      await tester.pumpAndSettle();

      // O mesmo bloco de abrir do + da pasta -- menos retomar conversa, que
      // é o histórico de outra pasta. Ver `openHereItems`.
      expect(find.text('sessão do claude'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      expect(find.text('retomar conversa…'), findsNothing);
      expect(find.text('abrir no vscode'), findsOneWidget);
      expect(find.text('excluir worktree…'), findsOneWidget);
    });
  });

  group('folder state', () {
    test('a config written before the move still loads', () {
      // The fold state of the old worktree drawer went away with the drawer.
      final legacy = Folder.fromJson({
        'root': '/repo',
        'name': 'meu-repo',
        'collapsed': true,
        'worktreesCollapsed': false,
      });
      expect(legacy.name, 'meu-repo');
      expect(legacy.collapsed, isTrue);
      expect(Folder.fromJson({'root': '/repo', 'name': 'meu-repo'}).collapsed, isFalse);
    });
  });
}
