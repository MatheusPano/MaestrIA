import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/store.dart';

/// A store with one Claude panel in one folder, nothing started.
(AppStore, MxTab) storeWithPanel() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
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

FollowUp step(String text) => FollowUp(kind: FollowUpKind.keepGoing, text: text);

void main() {
  group('the queue', () {
    // The whole contract: a turn ending spends one step. A queue that emptied
    // itself on a single Stop would send a plan's third instruction before
    // its first had been read.
    test('one turn spends one step', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um'), step('dois')]);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.followUps.map((f) => f.text), ['dois']);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // Claude Code can send more than one Stop for a turn. Watching the edge
    // instead of the state is what keeps the second one from costing a step.
    test('a second Stop on a session already quiet spends nothing', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um'), step('dois')]);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.followUps.map((f) => f.text), ['dois']);
      store.dispose();
    });

    test('an empty queue survives a turn ending', () {
      final (store, tab) = storeWithPanel();
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    test('arming a panel replaces whatever it was carrying', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('velho')]);
      store.queue(tab, [step('novo'), step('outro')]);
      expect(tab.followUps.map((f) => f.text), ['novo', 'outro']);
      store.dispose();
    });

    // Closing a panel inside the delay must take its step with it: the
    // session it was addressed to is gone.
    test('closing a panel cancels the step it was about to run', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um')]);
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(tab.pendingFollowUp?.isActive, isTrue);
      store.closeTab(tab);
      expect(tab.pendingFollowUp?.isActive, isFalse);
      store.dispose();
    });
  });

  group('the handoff message', () {
    test('carries the closing message across whole, and the note with it', () {
      final (store, tab) = storeWithPanel();
      tab.hooks.lastMessageFull =
          'Troquei o endpoint pra /v2/permissions.\nFalta o refresh token.';

      final text = AppStore.handoffText(tab, 'Pega daqui e termina o refresh.');
      expect(text, contains('"implementa"'));
      expect(text, contains('Falta o refresh token.'));
      expect(text, contains('Pega daqui e termina o refresh.'));
      store.dispose();
    });

    // A session that ended without saying anything still hands over: the note
    // alone is a whole instruction.
    test('works with nothing said, and with no note', () {
      final (store, tab) = storeWithPanel();
      expect(AppStore.handoffText(tab, 'assume'), contains('assume'));

      tab.hooks.lastMessageFull = 'pronto';
      final bare = AppStore.handoffText(tab, '');
      expect(bare, contains('pronto'));
      expect(bare.trim(), endsWith('"""'));
      store.dispose();
    });
  });
}
