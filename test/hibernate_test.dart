import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// Uma pasta e uma sessão do claude com conversa pra retomar -- o mínimo que
/// [AppStore.canHibernate] pede.
(AppStore, MxTab) storeWithSession({String? sessionId = 'sess-1'}) {
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
  tab.sessionId = sessionId;
  store.tabs.add(tab);
  return (store, tab);
}

/// Um turno inteiro: o prompt e a parada. Deixa a sessão em repouso, com a
/// parada carimbada -- ver [MxTab.restedAt].
void turn(AppStore store, MxTab tab) {
  store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
  store.applyHook(HookEvent(tab.id, 'Stop', {}));
}

Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hibernar à mão', () {
    test('desliga a sessão e fica com a conversa', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      expect(store.canHibernate(tab), isTrue);

      store.hibernate(tab);

      expect(tab.hibernated, isTrue);
      expect(tab.exited, isTrue);
      // O id é o que faz a hibernação valer alguma coisa.
      expect(tab.resumable, isTrue);
      expect(tab.resumeId, 'sess-1');
      expect(tab.subtitle, contains('hibernada'));
      expect(tab.status, ClaudeStatus.ended);
      // Continua na lateral: hibernar não é fechar.
      expect(store.tabs, contains(tab));
      // E não dá pra hibernar duas vezes.
      expect(store.canHibernate(tab), isFalse);
    });

    test('uma sessão sem id não hiberna: não haveria o que retomar', () {
      final (store, tab) = storeWithSession(sessionId: null);
      addTearDown(store.dispose);
      expect(store.canHibernate(tab), isFalse);
      store.hibernate(tab);
      expect(tab.hibernated, isFalse);
      expect(tab.exited, isFalse);
    });

    test('só sessão do claude: um shell não tem conversa', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final folder = Folder(root: '/repo', name: 'meu-repo');
      store.folders.add(folder);
      final shell = MxTab(id: 's1', folder: folder, kind: TabKind.shell, cwd: '/repo', branch: '');
      store.tabs.add(shell);
      expect(store.canHibernate(shell), isFalse);
    });

    test('a fila armada é desarmada: ela era pra uma sessão que rodava', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      tab.armed = true;
      store.hibernate(tab);
      expect(tab.armed, isFalse);
    });
  });

  group('acordar', () {
    test('o clique na linha religa a sessão', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      store.hibernate(tab);

      store.select(tab);
      // O acordar espera o processo anterior; aqui não há nenhum, então é um
      // giro do event loop.
      await Future<void>.delayed(Duration.zero);

      expect(tab.hibernated, isFalse);
      expect(tab.subtitle, isNot(contains('hibernada')));
      // O `--resume` leva o id que ficou.
      expect(tab.resumeId, 'sess-1');
    });

    test('acordar quem não está hibernada não faz nada', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      final before = tab.hooks.status;
      await store.wake(tab);
      expect(tab.hooks.status, before);
      expect(tab.exited, isFalse);
    });
  });

  group('hibernar sozinho', () {
    final now = DateTime(2026, 9, 18, 12);

    test('a parada fora da tela há mais de meia hora hiberna', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(minutes: 31));
      expect(store.isOpen(tab), isFalse);

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isTrue);
    });

    test('ainda não deu o tempo: fica', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(minutes: 29));

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('a restaurada que ninguém tocou conta desde o launch', () {
      // Sem turno nenhum: status `ready` e `restedAt` nulo, que é o estado de
      // treze painéis restaurados com `--resume` e nunca tocados.
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      tab.hooks.status = ClaudeStatus.ready;
      expect(tab.restedAt, isNull);

      store.hibernateIdle(now: tab.startedAt.add(const Duration(minutes: 31)));

      expect(tab.hibernated, isTrue);
    });

    test('na tela, nunca: desligar o que você está olhando é nas suas costas', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(hours: 2));
      store.panes = PaneLeaf(tab.id);
      store.focusedPaneId = tab.id;

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('com pendência com você, não', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(hours: 2));
      tab.hooks.status = ClaudeStatus.waitingPermission;

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('trabalhando, não', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      tab.hooks.status = ClaudeStatus.working;
      tab.hooks.lastEventAt = now.subtract(const Duration(hours: 2));

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('com fila pra andar, não', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(hours: 2));
      tab.followUps.add(FollowUp(kind: FollowUpKind.keepGoing, text: 'segue'));

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('quem outra fila vai chamar fica acordada', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(hours: 2));
      final other = MxTab(id: 't2', folder: tab.folder, kind: TabKind.claude, cwd: '/repo', branch: '');
      other.followUps.add(FollowUp(kind: FollowUpKind.handoff, text: 'toma', targetTabId: tab.id));
      store.tabs.add(other);

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('desligada nas configurações, nada hiberna', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(days: 1));
      store.setHibernateMinutes(0);
      expect(store.autoHibernate, isFalse);

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isFalse);
    });

    test('o tempo escolhido vale', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      turn(store, tab);
      tab.restedAt = now.subtract(const Duration(minutes: 6));
      store.setHibernateMinutes(5);

      store.hibernateIdle(now: now);

      expect(tab.hibernated, isTrue);
    });
  });

  group('o que fica gravado', () {
    test('a hibernada vai pro layout como hibernada, com o id', () {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      store.hibernate(tab);

      final json = tab.toJson();
      expect(json['hibernated'], isTrue);
      expect(json['sessionId'], 'sess-1');
      // A receita de um grupo não leva: abrir um grupo é querer os painéis
      // dele rodando.
      expect(tab.recipe.containsKey('hibernated'), isFalse);
    });
  });

  group('na lateral', () {
    testWidgets('a linha hibernada mostra a lua e o que fazer', (tester) async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      store.hibernate(tab);

      await pumpSidebar(tester, store);
      await tester.pump();

      expect(find.byIcon(Icons.bedtime_outlined), findsOneWidget);
      expect(find.textContaining('hibernada'), findsOneWidget);
      // A gravação do config é debounced; deixa ela sair antes de desmontar.
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
