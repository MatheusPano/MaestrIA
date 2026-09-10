import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/store.dart';

/// A store with one Claude panel in one folder, nothing started.
(AppStore, MxTab) storeWithPanel() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
  store.folders.add(folder);
  store.tabs.add(panel(folder, 't1', 'implementa'));
  return (store, store.tabs.first);
}

MxTab panel(Folder folder, String id, String label) => MxTab(
  id: id,
  folder: folder,
  kind: TabKind.claude,
  cwd: '/repo',
  branch: '',
  customLabel: label,
);

FollowUp step(String text) => FollowUp(kind: FollowUpKind.keepGoing, text: text);

/// Fast-forward the silence a queue waits out. Nothing announces "still
/// nothing happening", so the wait is measured against the last event -- and
/// a test is not going to sit through it.
void silent(MxTab tab, {Duration? by}) =>
    tab.hooks.lastEventAt = DateTime.now().subtract(by ?? AppStore.flowQuiet);

/// One turn: a prompt, and the Stop that ends it.
void turn(AppStore store, MxTab tab) {
  store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
  store.applyHook(HookEvent(tab.id, 'Stop', {}));
}

void main() {
  // O aviso de ociosidade acende o badge do dock, e o dock é um
  // `MethodChannel`: sem binding ele estoura antes de o teste chegar na fila.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the queue', () {
    // The whole contract: a turn ending spends one step. A queue that emptied
    // itself on a single Stop would send a plan's third instruction before
    // its first had been read.
    test('one turn spends one step', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um'), step('dois')]);

      turn(store, tab);
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps.map((f) => f.text), ['dois']);

      turn(store, tab);
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // Claude Code can send more than one Stop for a turn, and the clock ticks
    // whether or not anything happened -- neither is a turn.
    test('a second Stop, and a second tick, spend nothing', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um'), step('dois')]);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      silent(tab);
      store.pumpFlows();
      store.pumpFlows();
      expect(tab.followUps.map((f) => f.text), ['dois']);
      store.dispose();
    });

    // The bug this whole gate exists for: a session that hands two agents the
    // work ends its turn immediately and sits there idle while they run. The
    // step used to go out over their shoulder.
    test('a turn that ends with agents still running holds the queue', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('revisa')]);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Agent'}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Agent'}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      silent(tab);

      expect(tab.status, ClaudeStatus.idle);
      expect(store.holdFor(tab), FlowHold.forks);
      store.pumpFlows();
      expect(tab.followUps, hasLength(1));

      // What a fork does while it works is not the session's status, and it
      // is not the fork finishing either.
      store.applyHook(HookEvent(tab.id, 'PostToolUse', {'agent_id': 'a1'}));
      store.applyHook(HookEvent(tab.id, 'SubagentStop', {'agent_id': 'a1'}));
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, hasLength(1), reason: 'ainda falta um agente');

      store.applyHook(HookEvent(tab.id, 'SubagentStop', {'agent_id': 'a2'}));
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // O aviso de ociosidade chega um minuto depois do `Stop` e reescreve o
    // estado da sessão. Uma fila segurada pelos agentes dela ainda está
    // esperando quando ele chega, e ele não pode ser o que a prende.
    test('the idle notice that lands mid-wait does not strand the queue', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('revisa')]);
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Agent'}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      store.applyHook(
        HookEvent(tab.id, 'Notification', {'notification_type': 'idle_prompt'}),
      );
      expect(tab.status, ClaudeStatus.waitingInput);

      store.applyHook(HookEvent(tab.id, 'SubagentStop', {'agent_id': 'a1'}));
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // A fork that never says goodbye cannot hold the queue for ever: a step
    // that silently never runs is worse than one that runs late.
    test('the wait for a silent agent gives up eventually', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('segue')]);
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      store.applyHook(HookEvent(tab.id, 'PreToolUse', {'tool_name': 'Task'}));
      store.applyHook(HookEvent(tab.id, 'Stop', {}));

      silent(tab, by: AppStore.flowPatience);
      expect(store.holdFor(tab), FlowHold.go);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // Idle for a blink is not idle: between two things a session is quiet the
    // same way it is quiet when it is done.
    test('a step waits out the silence before it goes', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um')]);
      turn(store, tab);

      expect(store.holdFor(tab), FlowHold.quiet);
      store.pumpFlows();
      expect(tab.followUps, hasLength(1));

      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // A step that happens somewhere else leaves this session exactly as it
    // was, so nothing would ever produce the turn the next step waited for.
    test('a step that does not hand the turn back lets the next one follow', () {
      final (store, tab) = storeWithPanel();
      final other = panel(tab.folder, 't2', 'revisa');
      store.tabs.add(other);
      store.queue(tab, [
        FollowUp(kind: FollowUpKind.handoff, text: 'assume', targetTabId: other.id),
        step('e me diz o que sobrou'),
      ]);

      turn(store, tab);
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps.map((f) => f.kind), [FollowUpKind.keepGoing]);
      expect(tab.armed, isTrue, reason: 'a fila segue andando sozinha');

      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // O painel que um passo abre é filho de quem o abriu: ele entra na lista
    // logo atrás do pai, que é a ordem da lateral e do ⌘1..9. Solto no fim
    // dela ele aparecia a cinco linhas do fluxo de que fazia parte.
    test('a step that opens a panel hangs it on the session it came from', () async {
      final (store, tab) = storeWithPanel();
      final avulso = panel(tab.folder, 't9', 'outra coisa');
      store.tabs.add(avulso);
      store.queue(tab, [
        FollowUp(kind: FollowUpKind.command, text: 'flutter analyze && flutter test'),
      ]);

      turn(store, tab);
      silent(tab);
      store.pumpFlows();

      // O pty recusa uma pasta que não existe e avisa por microtask -- ver
      // [TermSession._start]. Sem deixá-la correr, o aviso chega no store já
      // descartado, depois do fim do teste.
      await Future<void>.delayed(Duration.zero);

      final shell = store.tabs.firstWhere((t) => t.kind == TabKind.shell);
      expect(shell.bornOf, tab.id);
      expect(store.descendsFrom(shell, tab), isTrue);
      expect(store.tabs.indexOf(shell), store.tabs.indexOf(tab) + 1);
      expect(store.tabs.last, avulso, reason: 'o painel de fora não se mexeu');
      // Dois comandos do mesmo fluxo davam duas linhas chamadas "X ▸ depois".
      expect(
        shell.title,
        'flutter analyze && flutter…',
        reason: 'o nome do painel é o comando',
      );
      store.dispose();
    });

    test('an empty queue survives a turn ending', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      expect(tab.armed, isFalse);
      store.dispose();
    });

    test('arming a panel replaces whatever it was carrying', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('velho')]);
      store.queue(tab, [step('novo'), step('outro')]);
      expect(tab.followUps.map((f) => f.text), ['novo', 'outro']);
      store.dispose();
    });

    // Arming a session that has already stopped: the trigger it was waiting
    // for is in the past, so without this the queue would never go off.
    test('a queue armed on a session already stopped goes off by itself', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      silent(tab);

      store.queue(tab, [step('vai')]);
      store.pumpFlows();
      expect(tab.followUps, hasLength(1), reason: 'armar não é disparar');

      store.queue(tab, [step('vai')], now: true);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      store.dispose();
    });

    // Closing a panel must take its queue with it: the session it was
    // addressed to is gone.
    test('closing a panel drops the step it was about to run', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um')]);
      turn(store, tab);
      expect(tab.armed, isTrue);

      store.closeTab(tab);
      silent(tab);
      store.pumpFlows();
      expect(tab.armed, isFalse);
      expect(tab.followUps, hasLength(1), reason: 'ninguém pra receber');
      store.dispose();
    });

    // Marking a session done is a judgement about work that is over; a step
    // firing into it afterwards would be the app arguing with you.
    test('marking a session done drops the queue', () {
      final (store, tab) = storeWithPanel();
      store.queue(tab, [step('um'), step('dois')]);
      turn(store, tab);

      expect(store.setDone(tab, true), 2);
      silent(tab);
      store.pumpFlows();
      expect(tab.followUps, isEmpty);
      expect(tab.armed, isFalse);
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
