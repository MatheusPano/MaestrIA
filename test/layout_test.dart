import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';

MxTab tab({
  TabKind kind = TabKind.claude,
  String cwd = '/repo/.claude/worktrees/TASK-47730',
  String branch = 'feature/TASK#47730',
  String? label,
}) =>
    MxTab(
      id: 'tab1',
      folder: Folder(root: '/repo', name: 'meu-repo'),
      kind: kind,
      cwd: cwd,
      branch: branch,
      customLabel: label,
    );

void main() {
  group('panel title', () {
    test('a name you typed wins over everything', () {
      expect(tab(label: 'refatorar auth').title, 'refatorar auth');
    });

    test('otherwise the task id in the branch', () {
      expect(tab().title, 'TASK#47730');
    });

    test('and for a plain folder, the folder', () {
      expect(tab(kind: TabKind.shell, cwd: '/repo/api', branch: '').title, 'api');
    });

    test('in the main checkout, the folder name beats the trunk', () {
      expect(tab(cwd: '/repo', branch: 'master').title, 'meu-repo');
    });
  });

  group('layout round trip', () {
    test('a claude panel carries what it needs to be resumed', () {
      final t = tab(label: 'TASK#47730');
      t.sessionId = 'abc-123';
      expect(t.toJson(), {
        'folderRoot': '/repo',
        'kind': 'claude',
        'cwd': '/repo/.claude/worktrees/TASK-47730',
        'label': 'TASK#47730',
        'sessionId': 'abc-123',
      });
    });

    test('a shell panel never claims a session', () {
      final t = tab(kind: TabKind.shell, branch: '');
      t.sessionId = 'leftover';
      expect(t.toJson().containsKey('sessionId'), isFalse);
    });
  });

  group('sidebar width', () {
    test('a drag past either end stops at the end', () {
      final store = AppStore();
      store.setSidebarWidth(2000);
      expect(store.sidebarWidth, AppStore.maxSidebar);
      store.setSidebarWidth(-40);
      expect(store.sidebarWidth, AppStore.minSidebar);
    });

    test('and is remembered alongside the panels', () {
      final store = AppStore();
      store.setSidebarWidth(420);
      expect(store.sidebarWidth, 420);
    });
  });
}
