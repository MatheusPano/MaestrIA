import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

(AppStore, Folder) storeWithFolder() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
  store.folders.add(folder);
  return (store, folder);
}

MxTab panel(AppStore store, Folder folder, String name, {Project? project}) {
  final tab = MxTab(
    id: name,
    folder: folder,
    kind: TabKind.claude,
    cwd: folder.root,
    branch: '',
    customLabel: name,
  );
  tab.projectId = project?.id;
  store.tabs.add(tab);
  return tab;
}

FollowUp step(String text) => FollowUp(kind: FollowUpKind.keepGoing, text: text);

Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  group('a session marked done', () {
    test('stays open — the mark is not a close', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');

      store.setDone(tab, true);
      expect(tab.done, isTrue);
      // The whole point: the conversation is still there to reread.
      expect(store.tabs, contains(tab));
      store.dispose();
    });

    test('survives the config round trip', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      expect(tab.toJson()['done'], isNull);

      store.setDone(tab, true);
      expect(tab.toJson()['done'], isTrue);
      store.dispose();
    });

    // A queued step firing into a session you just called finished would be
    // the app disagreeing with you out loud.
    test('drops its queue, and says how much of it there was', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      store.queue(tab, [step('um'), step('dois')]);

      expect(store.setDone(tab, true), 2);
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    test('marked twice, the second time is a no-op', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      store.setDone(tab, true);
      expect(store.setDone(tab, true), 0);
      expect(tab.done, isTrue);
      store.dispose();
    });

    test('stops asking for a human, in the folder and in the project', () {
      final (store, folder) = storeWithFolder();
      final project = store.addProject(folder, 'permissão do google');
      final tab = panel(store, folder, 'essa funcionou', project: project);
      tab.hooks.status = ClaudeStatus.waitingPermission;

      expect(store.needingHuman(folder), 1);
      expect(store.needingHumanIn(project), 1);

      store.setDone(tab, true);
      expect(store.needingHuman(folder), 0);
      expect(store.needingHumanIn(project), 0);
      store.dispose();
    });

    // Asked for more, it is not finished any more.
    test('loses the mark the moment a prompt is sent', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      store.setDone(tab, true);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      expect(tab.done, isFalse);
      store.dispose();
    });

    // A turn ending is not a judgement about it: `idle` says the session
    // stopped, and that is what it said before the mark existed too.
    test('does not appear on its own when a turn ends', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.hooks.status, ClaudeStatus.idle);
      expect(tab.done, isFalse);
      store.dispose();
    });

    // O menu diz "limpar encerrados e concluídos": marcar não fecha, mas
    // pedir a varrida fecha o que foi marcado -- senão sobraria fechar um a
    // um justamente os painéis já declarados resolvidos.
    test('is swept away when the folder is cleared, and the pending stay', () {
      final (store, folder) = storeWithFolder();
      final feito = panel(store, folder, 'essa funcionou');
      final pendente = panel(store, folder, 'essa ainda roda');
      store.setDone(feito, true);

      store.closeSettled(folder);
      expect(store.tabsOf(folder), [pendente]);
      store.dispose();
    });

    test('taken back, it is pending again', () {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      tab.hooks.status = ClaudeStatus.waitingPermission;

      store.setDone(tab, true);
      expect(store.setDone(tab, false), 0);
      expect(tab.done, isFalse);
      expect(store.needingHuman(folder), 1);
      store.dispose();
    });
  });

  group('the sidebar', () {
    testWidgets('ticks the row, and stops spending its alert badge', (tester) async {
      final (store, folder) = storeWithFolder();
      final tab = panel(store, folder, 'essa funcionou');
      tab.hooks.status = ClaudeStatus.waitingPermission;

      await pumpSidebar(tester, store);
      final tick = find.byIcon(Icons.task_alt);
      expect(tick, findsNothing);
      // Three "1" on screen: the folder's panel count, the folder's alert
      // badge, and the row's. Counted rather than named because the badge is
      // private to the sidebar.
      expect(find.text('1'), findsNWidgets(3));

      store.setDone(tab, true);
      // Pumped again, not `pump()`: only the app listens to the store, and
      // the sidebar under test is not the app.
      await pumpSidebar(tester, store);
      expect(tick, findsOneWidget);
      // Both badges gone; the panel is still one panel in the folder.
      expect(find.text('1'), findsOneWidget);
      store.dispose();
    });
  });
}
