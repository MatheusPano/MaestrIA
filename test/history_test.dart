import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/history.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/dialogs.dart';
import 'package:maestria/ui/sidebar.dart';

/// As conversas de mentira: `test/fixtures/history` tem a mesma forma que
/// `~/.claude/projects` -- uma pasta por caminho escapado, um `.jsonl` por
/// conversa. Ver [ChatHistory.dirFor].
const fixtures = 'test/fixtures/history';

/// A conversa completa da fixture: o `--name` que o cockpit passou, o título
/// que o próprio CLI deu a ela, e a primeira fala.
const titled = 'aaaa1111-1111-4111-8111-000000000001';

/// A que não tem `ai-title`: o nome dela tem que sair da fala do usuário.
const spoke = 'bbbb2222-2222-4222-8222-000000000002';

/// A que não tem título nem fala nenhuma dentro do pedaço lido.
const mute = 'cccc3333-3333-4333-8333-000000000003';

/// A de um repo que não está mais no disco.
const orphan = 'dddd4444-4444-4444-8444-000000000004';

/// Como a fixture [titled] se chama na tela.
const chamada = 'Cabeçalho da lateral com a busca';

ChatEntry byId(List<ChatEntry> chats, String id) =>
    chats.firstWhere((c) => c.sessionId == id);

/// Um store que não sobe processo.
///
/// [AppStore.openClaude] de verdade roda o `claude` da máquina num pty, e o
/// que está em teste aqui é o *pedido* -- qual conversa, em que pasta, com que
/// id --, não o terminal que atenderia a ele.
class NoPty extends AppStore {
  final List<Map<String, String?>> asked = [];

  @override
  MxTab openClaude(
    Folder f, {
    required String cwd,
    String? label,
    String? resumeId,
    Project? project,
    String? prompt,
  }) {
    asked.add({'folder': f.root, 'cwd': cwd, 'label': label, 'resumeId': resumeId});
    final tab = MxTab(
      id: 'tab${asked.length}',
      folder: f,
      kind: TabKind.claude,
      cwd: cwd,
      branch: '',
      customLabel: label,
    );
    tab.sessionId = resumeId;
    tabs.add(tab);
    select(tab);
    return tab;
  }
}

/// Bate frames até [finder] achar alguém.
///
/// Nunca pumpAndSettle: a marca do claude, que abre cada linha do histórico,
/// pulsa pra sempre. E nunca só `pump`: a lista vem de uma leitura de disco de
/// verdade, e o relógio de um teste de widget é de mentira -- sem o `runAsync`
/// o `Future` do disco não volta nunca.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// O diálogo, aberto pelo botão -- que é o que o `+` da lateral faz. Espera
/// por [until], que é a primeira linha a aparecer: o diálogo é montado no
/// clique, mas as conversas só chegam quando a leitura do disco volta.
///
/// Sem [folder] é o histórico inteiro, que é o que o rodapé da lateral pede.
Future<void> openHistory(
  WidgetTester tester,
  AppStore store, {
  Folder? folder,
  required Finder until,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showChatHistory(context, store, folder: folder),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await pumpUntil(tester, until);
}

/// A lateral inteira, que é onde o botão do histórico mora de verdade.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 700, child: Sidebar(store: store)),
    ),
  ),
);

void main() {
  group('o histórico', () {
    test('lista as conversas de uma pasta, e não as dos subagentes dela', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp']);

      expect(chats.map((c) => c.sessionId).toSet(), {titled, spoke, mute});
      // O transcript de um subagente mora em `<id>/subagents/`, e não é uma
      // conversa que se retoma.
      expect(chats.any((c) => c.sessionId.startsWith('agent-')), isFalse);
      // A conversa de outra pasta não entra: o histórico pedido foi o de /tmp.
      expect(chats.any((c) => c.sessionId == orphan), isFalse);
    });

    test('chama a conversa pelo título que o próprio claude deu a ela', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp']);
      expect(byId(chats, titled).title, 'Cabeçalho da lateral com a busca');
    });

    // O `custom-title` é o `--name` com que a sessão subiu, e o cockpit passa
    // o nome da pasta em todas que abre: por ele, vinte conversas deste repo
    // se chamariam "maestria_v2". A fala do usuário vem antes.
    test('sem título do claude, chama pela primeira coisa que o usuário disse', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp']);

      expect(byId(chats, spoke).title, 'Tarefa o + da bandeja de grupos ficou torto');
    });

    test('sem título e sem fala, sobra o nome com que a sessão subiu', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp']);
      expect(byId(chats, mute).title, 'maestria_v2');
    });

    test('cada linha sabe o id, a pasta, o tamanho e quando foi', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp']);
      final one = byId(chats, titled);
      final file = File('$fixtures/-tmp/$titled.jsonl');

      // O id é o nome do arquivo: está ali antes de qualquer leitura.
      expect(one.sessionId, titled);
      // A pasta é a que foi perguntada, e não uma reconstruída do nome da
      // pasta escapada -- de lá não há volta. Ver [ChatHistory.dirFor].
      expect(one.cwd, '/tmp');
      expect(one.where, 'tmp');
      expect(one.bytes, file.lengthSync());
      expect(one.at, file.statSync().modified);
      expect(one.missing, isFalse);
    });

    test('o histórico inteiro acha a conversa de uma pasta que não existe mais', () async {
      final chats = await ChatHistory.read(root: fixtures);

      expect(chats.map((c) => c.sessionId).toSet(), {titled, spoke, mute, orphan});
      final gone = byId(chats, orphan);
      // Sem pasta perguntada, o cwd é o que o transcript diz.
      expect(gone.cwd, '/repo/sumiu');
      expect(gone.title, 'Migrar o schema do relatório');
      expect(gone.missing, isTrue);
    });

    // O histórico da janela é o que a lateral não sabe: o `~/.claude/projects`
    // tem uma pasta por caminho em que o claude rodou, e a maior parte deles
    // nunca foi adicionada aqui.
    test('o da janela traz conversa de pasta que não está na lateral', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);

      final all = await store.allChats();
      final only = await store.chatsIn(folder);

      expect(all.map((c) => c.sessionId).toSet(), {titled, spoke, mute, orphan});
      // Enquanto o da pasta continua sendo só o dela.
      expect(only.map((c) => c.sessionId).toSet(), {titled, spoke, mute});
    });

    test('a mais recente vem primeiro', () async {
      final home = Directory.systemTemp.createTempSync('maestria-history');
      addTearDown(() => home.deleteSync(recursive: true));
      final dir = Directory('${home.path}/${ChatHistory.dirFor('/tmp')}')..createSync();
      File('${dir.path}/velha.jsonl').writeAsStringSync('{"type":"ai-title","aiTitle":"velha"}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File('${dir.path}/nova.jsonl').writeAsStringSync('{"type":"ai-title","aiTitle":"nova"}');

      final chats = await ChatHistory.read(root: home.path, cwds: ['/tmp']);
      expect(chats.map((c) => c.title), ['nova', 'velha']);
      // E o limite corta pela ponta de cima, que é a que interessa.
      final one = await ChatHistory.read(root: home.path, cwds: ['/tmp'], limit: 1);
      expect(one.map((c) => c.title), ['nova']);
    });

    test('pasta sem conversa nenhuma não é erro', () async {
      expect(await ChatHistory.read(root: fixtures, cwds: ['/nao/existe']), isEmpty);
      expect(await ChatHistory.read(root: '$fixtures/nao-existe'), isEmpty);
    });

    // Duas pastas diferentes podem escapar pro mesmo nome, e a conversa não
    // pode aparecer duas vezes por causa disso.
    test('a mesma pasta pedida duas vezes não duplica a conversa', () async {
      final chats = await ChatHistory.read(root: fixtures, cwds: ['/tmp', '/tmp', '/-tmp']);
      expect(chats, hasLength(3));
    });
  });

  group('retomar uma conversa', () {
    test('abre um painel na pasta dela, com o --resume daquele id', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);
      final chats = await store.chatsIn(folder);
      final chat = byId(chats, titled);

      expect(store.standingOf(chat), ChatStanding.fresh);
      final tab = store.resumeChat(chat, folder: folder)!;

      expect(store.asked, [
        {
          'folder': '/tmp',
          'cwd': '/tmp',
          'label': 'Cabeçalho da lateral com a busca',
          'resumeId': titled,
        },
      ]);
      // E o painel volta apontando pra conversa: é o `resumeId` dele que o
      // layout salvo leva pra retomá-la de novo amanhã.
      expect(tab.resumeId, titled);
      expect(tab.title, 'Cabeçalho da lateral com a busca');
    });

    // No histórico da janela ninguém diz de que pasta a conversa é: cada linha
    // é de um lugar diferente, e quem sabe qual é o caminho dela.
    test('sem pasta dita, acha a da lateral pelo caminho da conversa', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      store.folders.add(Folder(root: '/tmp', name: 'tmp'));
      final chat = byId(await store.allChats(), titled);

      store.resumeChat(chat);

      expect(store.asked.single['folder'], '/tmp');
      expect(store.asked.single['resumeId'], titled);
    });

    test('a de um repo que não está na lateral cai nos avulsos', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final chat = byId(await store.allChats(), titled);

      store.resumeChat(chat);

      // A pasta é a bandeja, mas o painel sobe onde a conversa rodou: retomar
      // noutro lugar é retomar uma conversa que fala de arquivos que não estão
      // lá.
      expect(store.asked.single['folder'], store.loose.root);
      expect(store.asked.single['cwd'], '/tmp');
    });

    test('a que já está num painel vai pra tela em vez de abrir a segunda', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);
      final chat = byId(await store.chatsIn(folder), titled);
      final already = store.resumeChat(chat, folder: folder)!;
      store.panes = null;

      expect(store.standingOf(chat), ChatStanding.onScreen);
      expect(store.resumeChat(chat, folder: folder), same(already));
      // Um painel, não dois: o segundo seria o CLI recusando o `--resume` de
      // uma sessão viva -- a que o próprio cockpit acabou de subir.
      expect(store.asked, hasLength(1));
      expect(store.panes, isNotNull);
    });

    // O CLI recusa o `--resume` de uma sessão que ainda está rodando, e manda
    // um `claude attach <jobId>` que o cockpit não tem como formar.
    test('a que está viva fora do maestria avisa em vez de abrir', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);
      final chat = byId(await store.chatsIn(folder), titled);
      store.agents.latest = [
        AgentInfo(pid: 4242, cwd: '/tmp', kind: 'interactive', sessionId: titled),
      ];

      expect(store.standingOf(chat), ChatStanding.live);
      expect(store.resumeChat(chat, folder: folder), isNull);
      expect(store.asked, isEmpty);
      expect(store.banner, contains('ainda está rodando fora do maestria'));
    });

    test('a de uma pasta que sumiu avisa em vez de abrir', () async {
      final store = NoPty();
      addTearDown(store.dispose);
      final chat = byId(await store.chatsIn(store.loose), orphan);

      expect(store.standingOf(chat), ChatStanding.gone);
      expect(store.resumeChat(chat), isNull);
      expect(store.asked, isEmpty);
      expect(store.banner, contains('/repo/sumiu'));
    });
  });

  group('o diálogo do histórico', () {
    testWidgets('mostra as conversas e diz o que cada uma tem de errado', (tester) async {
      final store = NoPty();
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);
      // A bandeja dos avulsos pede o histórico inteiro, que é onde a conversa
      // do repo que sumiu aparece.
      await openHistory(tester, store, folder: store.loose, until: find.text(chamada));

      expect(find.text('conversas de antes'), findsOneWidget);
      expect(find.text(chamada), findsOneWidget);
      expect(find.text('Tarefa o + da bandeja de grupos ficou torto'), findsOneWidget);
      expect(find.text('Migrar o schema do relatório'), findsOneWidget);
      // A linha diz por que a conversa não abre, antes do clique -- e diz
      // qual dos dois motivos é: a pasta que sumiu, ou o transcript que nunca
      // disse em que pasta ela rodou.
      expect(find.text('a pasta não existe mais'), findsOneWidget);
      expect(find.text('não sei onde ela rodou'), findsOneWidget);
      // A pasta aparece pelo nome curto, que é como a lateral chama um repo.
      expect(find.textContaining('· sumiu ·'), findsOneWidget);
      expect(find.textContaining('/repo/sumiu'), findsNothing);
      store.dispose();
    });

    testWidgets('sem pasta, mostra as de todas elas de uma vez', (tester) async {
      final store = NoPty();
      store.folders.add(Folder(root: '/tmp', name: 'tmp'));
      await openHistory(tester, store, until: find.text(chamada));

      expect(find.text('todas as conversas'), findsOneWidget);
      // A de /tmp e a do repo que sumiu, na mesma lista.
      expect(find.text(chamada), findsOneWidget);
      expect(find.text('Migrar o schema do relatório'), findsOneWidget);
      store.dispose();
    });

    testWidgets('o rodapé da lateral é por onde se chega nele', (tester) async {
      final store = NoPty();
      store.folders.add(Folder(root: '/tmp', name: 'tmp'));
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('retomar uma conversa'));
      await pumpUntil(tester, find.text(chamada));

      expect(find.text('todas as conversas'), findsOneWidget);
      store.dispose();
    });

    testWidgets('um clique numa linha retoma aquela conversa', (tester) async {
      final store = NoPty();
      final folder = Folder(root: '/tmp', name: 'tmp');
      store.folders.add(folder);
      await openHistory(tester, store, folder: folder, until: find.text(chamada));

      await tester.tap(find.text(chamada));
      await tester.pump();

      expect(store.asked.single['resumeId'], titled);
      expect(store.asked.single['cwd'], '/tmp');
      // O diálogo sai de cena: o painel que ele abriu é o que se olha agora.
      expect(find.text('fechar'), findsNothing);
      store.dispose();
    });
  });
}
