import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/history.dart';
import 'package:maestria/services/report.dart';
import 'package:maestria/services/shell.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/dialogs.dart';
import 'package:maestria/ui/sidebar.dart';

/// Uma quarta-feira às 18h40, que é a hora em que o relatório de hoje é lido.
final agora = DateTime(2025, 9, 3, 18, 40);

/// A terça anterior: o dia que se fala na daily da manhã seguinte.
final ontem = DateTime(2025, 9, 2);

/// O exemplo do usuário -- uma segunda-feira de duas semanas antes.
final vinteCinco = DateTime(2025, 8, 25);

/// Um store que não escreve relatório nenhum.
///
/// O de verdade levanta o material com `git log` e chama o `claude -p`; o que
/// está em teste aqui é o *pedido* -- de que dia --, não a volta ao CLI.
class NoReport extends AppStore {
  DateTime? asked;

  @override
  Future<void> openDailyReport({DateTime? day}) async => asked = day;
}

/// Um store no meio de um relatório: é o estado que o botão da lateral mostra
/// como espera, e o único em que o clique não pergunta dia nenhum.
class Escrevendo extends NoReport {
  @override
  bool get writingReport => true;
}

/// O calendário, aberto pelo caminho que o botão da lateral usa.
Future<void> pumpPicker(WidgetTester tester, NoReport store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDailyReport(ctx, store, today: agora),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

Future<String> materialOf({
  required DateTime day,
  List<SessionNote> sessions = const [],
  List<ArchivedChat> chats = const [],
}) => DailyReport.material(
  folders: const [],
  worktrees: const {},
  projects: const [],
  sessions: sessions,
  chats: chats,
  day: day,
  now: agora,
);

void main() {
  group('como um dia se chama', () {
    test('hoje é "do dia", que é como o relatório sempre se chamou', () {
      expect(DailyReport.label(agora, now: agora), 'do dia');
      expect(DailyReport.label(DateTime(2025, 9, 3, 2, 15), now: agora), 'do dia');
    });

    test('ontem tem nome, e não data: é o dia da daily', () {
      expect(DailyReport.label(ontem, now: agora), 'de ontem');
    });

    test('os outros vêm pela data, com o ano só quando não é este', () {
      expect(DailyReport.label(vinteCinco, now: agora), 'de 25/08');
      expect(DailyReport.label(DateTime(2024, 12, 7), now: agora), 'de 07/12/2024');
    });
  });

  group('o material de um dia', () {
    test('o de hoje é o de sempre: o dia, a hora, e as sessões desta janela', () async {
      final text = await materialOf(day: agora);
      expect(text, contains('# material do dia — quarta-feira, 3 de setembro de 2025, 18:40'));
      expect(text, contains('nenhuma sessão aberta hoje.'));
      // A ressalva do dia que passou não tem o que fazer num relatório de hoje.
      expect(text, isNot(contains('levantado em')));
    });

    test('o de um dia que passou diz de que dia é, e quando foi levantado', () async {
      final text = await materialOf(day: vinteCinco);
      expect(text, contains('# material de segunda-feira, 25 de agosto de 2025'));
      expect(text, contains('levantado em quarta-feira, 3 de setembro de 2025, às 18:40'));
      // O que o relatório não pode afirmar sobre aquele dia, dito de frente:
      // uma seção ausente seria lida como bancada limpa.
      expect(text, contains('O que estava sem commitar naquele dia não se sabe mais.'));
    });

    test('sem painel daquele dia, o material manda ler as conversas', () async {
      final text = await materialOf(day: vinteCinco);
      expect(text, contains('nenhum painel desta janela é daquele dia'));
    });

    test('as conversas arquivadas entram como linha, com pasta e hora', () async {
      final text = await materialOf(
        day: vinteCinco,
        chats: [
          ArchivedChat(
            title: 'o leitor de markdown',
            folder: 'maestria_v2',
            at: DateTime(2025, 8, 25, 16, 12),
            size: '312 kB',
          ),
        ],
      );
      expect(text, contains('## conversas daquele dia'));
      expect(
        text,
        contains('- o leitor de markdown · pasta maestria_v2 · último movimento 16:12 · 312 kB'),
      );
    });

    test('num relatório de hoje não há seção de conversas', () async {
      expect(await materialOf(day: agora), isNot(contains('## conversas')));
    });
  });

  group('o pedido ao claude', () {
    test('o de hoje é lido no fim do expediente', () {
      final prompt = DailyReport.promptFor('...', day: agora, now: agora);
      expect(prompt, contains('material bruto de hoje'));
      expect(prompt, contains('trabalho não commitado e as sessões que rodaram'));
      expect(prompt, contains('Ele lê isso no fim do expediente'));
      expect(prompt, contains('o que ficou sem commit'));
    });

    test('o de ontem é falado na daily de agora, e diz que dia da semana foi', () {
      final prompt = DailyReport.promptFor('...', day: ontem, now: agora);
      expect(prompt, contains('material bruto de terça-feira, 2 de setembro de 2025'));
      expect(prompt, contains('na daily de hoje, em minutos'));
    });

    test('o de um dia antigo é uma olhada pra trás, sem bancada pra citar', () {
      final prompt = DailyReport.promptFor('...', day: vinteCinco, now: agora);
      expect(prompt, contains('material bruto de segunda-feira, 25 de agosto de 2025'));
      expect(prompt, contains('Ele está olhando pra trás'));
      expect(prompt, contains('Nada de trabalho não commitado'));
      expect(prompt, isNot(contains('o que ficou sem commit')));
    });
  });

  group('as conversas de um dia', () {
    /// Duas conversas na mesma pasta, mexidas em dias diferentes. O mtime é o
    /// critério -- ver [ChatHistory.read] --, então é ele que o teste arma.
    Future<Directory> archive() async {
      final root = await Directory.systemTemp.createTemp('maestria-conversas');
      final dir = Directory('${root.path}/${ChatHistory.dirFor('/repo')}')
        ..createSync(recursive: true);
      for (final one in [
        (id: 'aaaa1111-1111-4111-8111-000000000001', said: 'a janela do relatório', at: vinteCinco),
        (id: 'bbbb2222-2222-4222-8222-000000000002', said: 'a porta do hook', at: agora),
      ]) {
        File('${dir.path}/${one.id}.jsonl')
          ..writeAsStringSync(
            '{"type":"user","cwd":"/repo","message":{"content":"${one.said}"}}\n',
          )
          ..setLastModifiedSync(one.at);
      }
      return root;
    }

    test('sem dia pedido, são todas', () async {
      final root = await archive();
      addTearDown(() => root.delete(recursive: true));
      final chats = await ChatHistory.read(root: root.path);
      expect(chats.map((c) => c.title), ['a porta do hook', 'a janela do relatório']);
    });

    test('com um dia, só as mexidas naquele dia', () async {
      final root = await archive();
      addTearDown(() => root.delete(recursive: true));
      final chats = await ChatHistory.read(root: root.path, on: vinteCinco);
      expect(chats.map((c) => c.title), ['a janela do relatório']);
    });

    test('um dia em que ninguém falou nada volta vazio', () async {
      final root = await archive();
      addTearDown(() => root.delete(recursive: true));
      expect(await ChatHistory.read(root: root.path, on: DateTime(2025, 7, 4)), isEmpty);
    });

    // O corte por dia vem antes do limite, e não depois: com o limite primeiro,
    // um dia de agosto só apareceria se as quarenta conversas mais recentes
    // chegassem até lá -- e um relatório de agosto voltaria sem sessão nenhuma
    // justamente em quem usa o app todo dia.
    test('o dia pedido não disputa o limite com as conversas de hoje', () async {
      final root = await archive();
      addTearDown(() => root.delete(recursive: true));
      final chats = await ChatHistory.read(root: root.path, on: vinteCinco, limit: 1);
      expect(chats.map((c) => c.title), ['a janela do relatório']);
    });
  });

  group('os commits de um dia', () {
    /// Um repo de verdade, com um commit no dia 25 de agosto, outro hoje, e um
    /// arquivo sem commitar na bancada.
    ///
    /// De verdade porque o que está em teste é a janela que o `git log` recebe
    /// -- ver `_commitsOn` --, e uma janela errada é justamente o que um git de
    /// mentira não teria como mostrar. As duas datas vão nas duas variáveis: o
    /// `--since`/`--until` filtra pela data do *commit*, não pela do autor.
    Future<Folder> repo() async {
      final dir = await Directory.systemTemp.createTemp('maestria-repo');
      addTearDown(() => dir.delete(recursive: true));
      await Sh.run(
        'git init -q . && git config user.email dev@teste && '
        'git config user.name dev && git config commit.gpgsign false',
        cwd: dir.path,
      );
      for (final one in [
        (file: 'leitor.md', said: 'o leitor de markdown', at: '2025-08-25 14:30:00'),
        (file: 'hook.md', said: 'a porta do hook', at: '2025-09-03 09:10:00'),
      ]) {
        await Sh.run(
          'echo x > ${one.file} && git add ${one.file} && '
          'GIT_AUTHOR_DATE=${Sh.q(one.at)} GIT_COMMITTER_DATE=${Sh.q(one.at)} '
          'git commit -qm ${Sh.q(one.said)}',
          cwd: dir.path,
        );
      }
      await Sh.run('echo x > pendente.md', cwd: dir.path);
      return Folder(root: dir.path, name: 'meu-repo')..isRepo = true;
    }

    Future<String> materialFor(Folder folder, DateTime day) => DailyReport.material(
      folders: [folder],
      worktrees: {
        folder.root: [WorktreeInfo(path: folder.root, branch: 'master', isMain: true)],
      },
      projects: const [],
      sessions: const [],
      day: day,
      now: agora,
    );

    // A janela é fechada nos dois lados. Com o `--since=midnight` de antes, um
    // relatório de 25 de agosto pedido em setembro trazia os dez dias que
    // vieram depois -- e o dia relatado ficava sendo o mês inteiro.
    test('são os daquele dia, e nada do que veio depois', () async {
      final text = await materialFor(await repo(), vinteCinco);

      expect(text, contains('commits de 25/08, de dev@teste:'));
      expect(text, contains('14:30'));
      expect(text, contains('o leitor de markdown'));
      expect(text, isNot(contains('a porta do hook')));
    });

    test('de hoje, são os de hoje — e a bancada vem junto', () async {
      final text = await materialFor(await repo(), agora);

      expect(text, contains('commits de hoje, de dev@teste:'));
      expect(text, contains('a porta do hook'));
      expect(text, isNot(contains('o leitor de markdown')));
      // A bancada é a metade honesta de um dia: quatro commits e nove
      // arquivos sujos é um dia diferente de quatro commits e a árvore limpa.
      expect(text, contains('trabalho ainda não commitado:'));
      expect(text, contains('pendente.md'));
    });

    // `git status` diz como a checkout *está*, não como ela estava em agosto:
    // uma seção ausente seria lida como bancada limpa naquela noite.
    test('de um dia que passou, a bancada não é coletada — e o material diz', () async {
      final text = await materialFor(await repo(), vinteCinco);

      expect(text, contains('trabalho não commitado: não dá pra saber'));
      expect(text, isNot(contains('pendente.md')));
    });

    test('um dia sem commit nenhum diz que não teve', () async {
      final text = await materialFor(await repo(), DateTime(2025, 7, 4));
      expect(text, contains('commits de 04/07, de dev@teste:\n- nenhum.'));
    });
  });

  group('o botão do relatório', () {
    /// A lateral inteira, larga o bastante pro rodapé caber — ver worktrees_test.
    Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 660, height: 700, child: Sidebar(store: store)),
        ),
      ),
    );

    testWidgets('enquanto um relatório sai, o glifo é uma espera', (tester) async {
      final store = Escrevendo();
      store.folders.add(Folder(root: '/repo', name: 'meu-repo'));
      await pumpSidebar(tester, store);

      // Uma volta ao `claude -p` leva dezenas de segundos: um botão que não
      // diz isso é um botão que parece não ter funcionado, e que se clica de
      // novo. Nunca pumpAndSettle -- a espera gira pra sempre.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_outlined), findsNothing);
      store.dispose();
    });

    testWidgets('clicado durante um, diz que já está escrevendo e não abre o mês', (
      tester,
    ) async {
      final store = Escrevendo();
      await pumpPicker(tester, store);

      expect(find.text('relatório de que dia?'), findsNothing);
      expect(store.banner, contains('já estou escrevendo'));
      expect(store.asked, isNull);
      store.dispose();
    });
  });

  group('o calendário que pergunta o dia', () {
    testWidgets('abre no mês de hoje, com os dois dias que respondem quase sempre', (
      tester,
    ) async {
      await pumpPicker(tester, NoReport());
      expect(find.text('relatório de que dia?'), findsOne);
      expect(find.text('setembro de 2025'), findsOne);
      expect(find.text('hoje'), findsOne);
      expect(find.text('ontem'), findsOne);
    });

    testWidgets('"ontem" pede o dia da daily sem ninguém achar dia no calendário', (tester) async {
      final store = NoReport();
      await pumpPicker(tester, store);
      await tester.tap(find.text('ontem'));
      await tester.pumpAndSettle();
      expect(store.asked, ontem);
    });

    testWidgets('"hoje" pede hoje, que é o que o botão sempre fez', (tester) async {
      final store = NoReport();
      await pumpPicker(tester, store);
      await tester.tap(find.text('hoje'));
      await tester.pumpAndSettle();
      expect(DailyReport.sameDay(store.asked!, agora), isTrue);
    });

    testWidgets('andando um mês pra trás dá no 25 de agosto', (tester) async {
      final store = NoReport();
      await pumpPicker(tester, store);
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      expect(find.text('agosto de 2025'), findsOne);
      await tester.tap(find.text('25'));
      await tester.pumpAndSettle();
      expect(store.asked, vinteCinco);
    });

    testWidgets('o dia que ainda não chegou está escrito e não clica', (tester) async {
      final store = NoReport();
      await pumpPicker(tester, store);
      // 4 de setembro, o dia seguinte ao de hoje no teste.
      expect(find.text('4'), findsOne);
      await tester.tap(find.text('4'));
      await tester.pumpAndSettle();
      expect(store.asked, isNull);
      expect(find.text('relatório de que dia?'), findsOne);
    });

    testWidgets('não há mês pra frente: a seta de avançar está desligada', (tester) async {
      await pumpPicker(tester, NoReport());
      final forward = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_right_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(forward.onPressed, isNull);
      // E ela liga de novo assim que o mês na tela é um mês passado.
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      final back = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_right_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(back.onPressed, isNotNull);
    });
  });
}
