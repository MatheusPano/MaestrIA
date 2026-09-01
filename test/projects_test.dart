import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

AppStore storeWithFolder() {
  final store = AppStore();
  store.folders.add(
    Folder(root: '/repo', name: 'meu-repo')
      ..isRepo = true
      ..branch = 'master',
  );
  return store;
}

MxTab panel(AppStore store, String name, {Folder? folder, Project? project}) {
  final tab = MxTab(
    id: name,
    folder: folder ?? store.folders.first,
    kind: TabKind.claude,
    cwd: (folder ?? store.folders.first).root,
    branch: '',
    customLabel: name,
  );
  tab.projectId = project?.id;
  store.tabs.add(tab);
  return tab;
}

/// Wide enough that the add-row chips fit — see worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  group('a project', () {
    test('survives the config round trip', () {
      final store = storeWithFolder();
      final made = store.addProject(store.folders.first, 'permissão do google', brief: 'contexto');
      final back = Project.fromJson(made.toJson());
      expect(back.id, made.id);
      expect(back.name, 'permissão do google');
      expect(back.brief, 'contexto');
      expect(back.folderRoot, '/repo');
      store.dispose();
    });

    test('takes panels of its own folder and refuses the others', () {
      final store = storeWithFolder();
      final elsewhere = Folder(root: '/outro', name: 'outro-repo');
      store.folders.add(elsewhere);
      final project = store.addProject(store.folders.first, 'permissão do google');

      final mine = panel(store, 'aqui');
      final theirs = panel(store, 'longe', folder: elsewhere);

      store.assign(mine, project);
      store.assign(theirs, project);
      expect(mine.projectId, project.id);
      // A briefing describes a checkout the other session cannot see.
      expect(theirs.projectId, isNull);
      store.dispose();
    });

    // Dropping the label you put on a job is not deciding the job is over.
    test('dissolved, it sets its panels loose instead of closing them', () {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      final tab = panel(store, 'um', project: project);

      store.removeProject(project);
      expect(store.tabs, contains(tab));
      expect(tab.projectId, isNull);
      expect(store.projects, isEmpty);
      store.dispose();
    });

    // Concluding is the other end of the same distinction: here the job *is*
    // over, so the sessions end with it.
    test('concluded, it closes its panels and says how many', () {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      final mine = panel(store, 'um', project: project);
      final other = panel(store, 'dois', project: project);
      final loose = panel(store, 'fora');

      expect(store.completeProject(project), 2);
      expect(store.tabs, isNot(contains(mine)));
      expect(store.tabs, isNot(contains(other)));
      // Only its own: a panel that was never part of the job stays open.
      expect(store.tabs, contains(loose));
      expect(store.projects, isEmpty);
      store.dispose();
    });

    test('concluded with nothing open, it just goes', () {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      expect(store.completeProject(project), 0);
      expect(store.projects, isEmpty);
      store.dispose();
    });

    test('goes with the folder it hung under', () async {
      final store = storeWithFolder();
      store.addProject(store.folders.first, 'permissão do google');
      await store.removeFolder(store.folders.first);
      expect(store.projects, isEmpty);
      store.dispose();
    });

    // The list a panel lands in is the answer to which job it is part of.
    test('adopts a panel dragged in among its own', () {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      final inside = panel(store, 'dentro', project: project);
      final outside = panel(store, 'fora');

      store.moveTab(outside, inside);
      expect(outside.projectId, project.id);

      // And back out, dropping it on a panel that belongs to no project.
      final loose = panel(store, 'solto');
      store.moveTab(outside, loose);
      expect(outside.projectId, isNull);
      store.dispose();
    });
  });

  group('the sidebar', () {
    testWidgets('draws a project\'s panels inside it, and only there', (tester) async {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      panel(store, 'no projeto', project: project);
      panel(store, 'solto na pasta');

      await pumpSidebar(tester, store);
      expect(find.text('permissão do google'), findsOneWidget);
      // Once each: a panel drawn under the folder as well would be the same
      // session offered in two places.
      expect(find.text('no projeto'), findsOneWidget);
      expect(find.text('solto na pasta'), findsOneWidget);
      store.dispose();
    });

    testWidgets('folded, a project is one line instead of its panels', (tester) async {
      final store = storeWithFolder();
      final project = store.addProject(store.folders.first, 'permissão do google');
      panel(store, 'no projeto', project: project);

      store.toggleProjectCollapsed(project);
      await pumpSidebar(tester, store);
      expect(find.text('permissão do google'), findsOneWidget);
      expect(find.text('no projeto'), findsNothing);
      store.dispose();
    });
  });
}
