import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/services/plugins.dart';
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
      expect(tab.subtitle, contains('Hibernada'));
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
      expect(tab.subtitle, isNot(contains('Hibernada')));
      // O `--resume` leva o id que ficou.
      expect(tab.resumeId, 'sess-1');
    });

    test('um plugin acorda pelo session.wake, com o tabId e a permissão', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      store.hibernate(tab);
      final api = PluginApi(store);
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1', permissions: {PluginPermission.sessionsCreate}),
      );
      final nope = MxPlugin(dir: '/q', manifest: const PluginManifest(id: 'q', name: 'Q', version: '1'));
      expect(() => api.handle(nope, 'session.wake', {'tabId': tab.id}), throwsA(isA<PluginRpcError>()));
      expect(() => api.handle(plugin, 'session.wake', {}), throwsA(isA<PluginRpcError>()));
      expect(tab.hibernated, isTrue);

      expect(await api.handle(plugin, 'session.wake', {'tabId': tab.id}), {'woke': true});
      expect(tab.hibernated, isFalse);
      expect(tab.hooks.status, ClaudeStatus.starting);
      expect(await api.handle(plugin, 'session.wake', {'tabId': tab.id}), {'woke': false});
    });

    test('um plugin hiberna pelo session.hibernate: parada, com o tabId e a permissão', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      final api = PluginApi(store);
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1', permissions: {PluginPermission.sessionsClose}),
      );
      final create = MxPlugin(
        dir: '/q',
        manifest: const PluginManifest(id: 'q', name: 'Q', version: '1', permissions: {PluginPermission.sessionsCreate}),
      );
      expect(() => api.handle(create, 'session.hibernate', {'tabId': tab.id}), throwsA(isA<PluginRpcError>()));
      expect(() => api.handle(plugin, 'session.hibernate', {}), throwsA(isA<PluginRpcError>()));

      // No meio de um turno, não.
      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
      expect(() => api.handle(plugin, 'session.hibernate', {'tabId': tab.id}), throwsA(isA<PluginRpcError>()));
      expect(tab.hibernated, isFalse);

      store.applyHook(HookEvent(tab.id, 'Stop', {}));
      expect(await api.handle(plugin, 'session.hibernate', {'tabId': tab.id}), {'hibernated': true});
      expect(tab.hibernated, isTrue);
      expect(await api.handle(plugin, 'session.hibernate', {'tabId': tab.id}), {'hibernated': false});
    });

    test('com o "confia nesta pasta?" na tela, o plugin não escreve no terminal', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      final api = PluginApi(store);
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1', permissions: {PluginPermission.terminalWrite}),
      );
      tab.term.terminal.write(
        'Accessing workspace:\r\n\r\nQuick safety check: Is this a project you created or one you trust?\r\n'
        '❯ No, exit\r\n  Yes, I trust this folder\r\n',
      );
      expect(tab.term.asksTrust, isTrue);
      for (final method in ['terminal.sendText', 'terminal.sendKeys']) {
        await expectLater(
          api.handle(plugin, method, {
            'tabId': tab.id,
            'text': 'oi',
            'submit': true,
            'keys': ['enter'],
          }),
          throwsA(isA<PluginRpcError>().having((e) => e.message, 'message', contains('confia na pasta'))),
        );
      }
      // Respondida, a tela limpa e o prompt volta: aí pode.
      tab.term.terminal.write('\x1b[2J\x1b[H> ');
      expect(tab.term.asksTrust, isFalse);
    });

    test('o retrato de uma sessão: só um png da pasta do plugin', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      final dir = Directory.systemTemp.createTempSync('retrato');
      addTearDown(() => dir.deleteSync(recursive: true));
      final png = File('${dir.path}/rosto.png')..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
      final fora = Directory.systemTemp.createTempSync('fora');
      addTearDown(() => fora.deleteSync(recursive: true));
      final alheio = File('${fora.path}/outro.png')..writeAsBytesSync([0x89]);
      final api = PluginApi(store);
      final plugin = MxPlugin(dir: dir.path, manifest: const PluginManifest(id: 'p', name: 'P', version: '1'));

      await api.handle(plugin, 'session.portrait', {'tabId': tab.id, 'image': png.path});
      expect(tab.portrait, png.resolveSymbolicLinksSync());
      expect(
        () => api.handle(plugin, 'session.portrait', {'tabId': tab.id, 'image': alheio.path}),
        throwsA(isA<PluginRpcError>()),
        reason: 'fora da pasta do plugin, não',
      );
      expect(
        () => api.handle(plugin, 'session.portrait', {'tabId': tab.id, 'image': '${dir.path}/nada.png'}),
        throwsA(isA<PluginRpcError>()),
      );
      await api.handle(plugin, 'session.portrait', {'tabId': tab.id, 'image': null});
      expect(tab.portrait, isNull);
    });

    test('um plugin renomeia a sessão; vazio volta pro nome de sempre', () async {
      final (store, tab) = storeWithSession();
      addTearDown(store.dispose);
      final api = PluginApi(store);
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1', permissions: {PluginPermission.sessionsCreate}),
      );
      final nope = MxPlugin(dir: '/q', manifest: const PluginManifest(id: 'q', name: 'Q', version: '1'));
      expect(() => api.handle(nope, 'session.rename', {'tabId': tab.id, 'title': 'x'}), throwsA(isA<PluginRpcError>()));
      expect(() => api.handle(plugin, 'session.rename', {'title': 'x'}), throwsA(isA<PluginRpcError>()));

      expect(await api.handle(plugin, 'session.rename', {'tabId': tab.id, 'title': '  login do google  '}), {'title': 'login do google'});
      expect(tab.title, 'login do google');
      final back = await api.handle(plugin, 'session.rename', {'tabId': tab.id, 'title': ''}) as Map;
      expect(back['title'], isNot('login do google'), reason: 'vazio volta pro nome de sempre');
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
      expect(find.textContaining('Hibernada'), findsOneWidget);
      // A gravação do config é debounced; deixa ela sair antes de desmontar.
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
