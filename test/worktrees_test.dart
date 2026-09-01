import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// A folder with three worktrees: the main checkout, a live one, and one git
/// calls prunable — the folder is gone, the registration is not.
AppStore storeWith({required bool collapsed}) {
  final store = AppStore();
  store.folders.add(
    Folder(root: '/repo', name: 'meu-repo', worktreesCollapsed: collapsed)
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
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  group('worktree folder', () {
    testWidgets('folded, it is one line instead of five rows', (tester) async {
      await pumpSidebar(tester, storeWith(collapsed: true));
      expect(find.text('worktrees'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('TASK#47730'), findsNothing);
    });

    testWidgets('open, every worktree of the repo is in there', (tester) async {
      await pumpSidebar(tester, storeWith(collapsed: false));
      expect(find.text('TASK#47730'), findsOneWidget);
      expect(find.text('TASK#45371'), findsOneWidget);
      // The folder name twice: its header, and the main checkout's own row.
      expect(find.text('meu-repo'), findsNWidgets(2));
    });

    testWidgets('a worktree with no folder is not offered as somewhere to start', (tester) async {
      await pumpSidebar(tester, storeWith(collapsed: false));
      // Only the main checkout and the live worktree carry a ▶.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
      expect(find.text('a pasta não existe mais — só o registro no git'), findsOneWidget);
    });

    testWidgets('a repo folder is marked as one, and says its branch', (tester) async {
      await pumpSidebar(tester, storeWith(collapsed: true));
      expect(find.byType(RepoGlyph), findsOneWidget);
      expect(tester.widget<RepoGlyph>(find.byType(RepoGlyph)).isRepo, isTrue);
      expect(find.text('master'), findsOneWidget);
    });
  });

  group('fold state', () {
    test('survives a restart, folded by default', () {
      final fresh = Folder.fromJson({'root': '/repo', 'name': 'meu-repo'});
      expect(fresh.worktreesCollapsed, isTrue);
      expect(fresh.collapsed, isFalse);

      final open = Folder(root: '/repo', name: 'meu-repo', worktreesCollapsed: false);
      final back = Folder.fromJson(open.toJson());
      expect(back.worktreesCollapsed, isFalse);
    });
  });
}
