import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/docs.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/doc_pane.dart';
import 'package:maestria/ui/result_strip.dart';
import 'package:maestria/ui/terminal_pane.dart';

Map<String, dynamic> ev(String name, [Map<String, dynamic> extra = const {}]) => {
  'hook_event_name': name,
  'session_id': 'sess-1',
  'cwd': '/repo',
  ...extra,
};

/// Uma sessão do claude ocupando o único painel da tela.
MxTab session(AppStore store, {String title = 'TASK#47730'}) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: title,
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

/// Um painel de leitura montado à mão.
///
/// Direto e não por [AppStore.showDoc] de propósito: pôr algo na tela agenda a
/// escrita do config, e um timer de 400ms pendente reprova um teste de widget
/// antes de o `tearDown` chegar a existir. Onde o leitor *aparece* é assunto
/// dos testes de store aqui em cima; este é o desenho dele.
MxTab reader(MxDoc doc) => MxTab(
  id: 'doc1',
  folder: Folder(root: '/repo', name: 'meu-repo'),
  kind: TabKind.reader,
  cwd: '/repo',
  branch: '',
  doc: doc,
);

Future<void> pumpReader(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 720, height: 420, child: DocPane(store: store, tab: tab)),
    ),
  ),
);

void main() {
  group('o plano, pego do hook', () {
    test('o ExitPlanMode guarda o markdown que a sessão apresentou', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'PreToolUse',
        ev('PreToolUse', {
          'tool_name': 'ExitPlanMode',
          'tool_input': {'plan': '## Trocar o middleware\n\n- [ ] jwt.dart\n- [ ] os call sites'},
        }),
      );
      expect(s.plans, hasLength(1));
      expect(s.plan!.headline, 'Trocar o middleware');
    });

    test('reapresentar o mesmo plano não é um plano novo', () {
      final s = HookState();
      for (var i = 0; i < 3; i++) {
        HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'ExitPlanMode',
            'tool_input': {'plan': '# igual'},
          }),
        );
      }
      expect(s.plans, hasLength(1));
    });

    test('replanejar guarda os dois, e o da vez é o último', () {
      final s = HookState();
      for (final text in ['# primeiro', '# segundo']) {
        HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'ExitPlanMode',
            'tool_input': {'plan': text},
          }),
        );
      }
      expect(s.plans, hasLength(2));
      expect(s.plan!.headline, 'segundo');
    });
  });

  group('o painel de leitura', () {
    test('o plano abre ao lado da sessão, não em cima dela', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));

      final reader = store.showPlan(tab)!;
      expect(reader.isReader, isTrue);
      // Os dois painéis na tela, o da sessão primeiro.
      expect(Panes.order(store.panes), [tab.id, reader.id]);
      expect(store.focusedPaneId, reader.id);
    });

    test('o segundo documento troca o que está no leitor em vez de abrir outro', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));
      tab.hooks.lastMessageFull = 'terminei os **sete** call sites';

      final first = store.showPlan(tab)!;
      final second = store.showMessage(tab)!;
      expect(identical(first, second), isTrue);
      expect(store.paneCount, 2);
      expect(second.doc!.source, DocSource.message);
      expect(second.title, 'recado de TASK#47730');
    });

    test('um leitor que saiu do painel é reaproveitado, não duplicado', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));

      final leitor = store.showPlan(tab)!;
      // Alguém pôs a sessão de volta naquele painel: o leitor continua na
      // lateral, fora da tela.
      store.dropTab(tab, target: leitor, side: DropSide.center);
      expect(store.isOpen(leitor), isFalse);

      final again = store.showPlan(tab)!;
      expect(identical(again, leitor), isTrue);
      expect(store.tabs.where((t) => t.isReader), hasLength(1));
      expect(store.isOpen(leitor), isTrue);
    });

    test('sem plano nenhum, nada abre e a janela diz por quê', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      expect(store.showPlan(tab), isNull);
      expect(store.paneCount, 1);
      expect(store.banner, contains('não apresentou nenhum plano'));
    });

    test('um leitor não é uma sessão: não tem estado nem pede nada de você', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));
      final reader = store.showPlan(tab)!;
      expect(reader.status, ClaudeStatus.unknown);
      expect(reader.status.needsHuman, isFalse);
    });

    test('só markdown vale um leitor; o resto continua sendo do Quick Look', () {
      expect(AppStore.readable('/repo/PLANO.md'), isTrue);
      expect(AppStore.readable('/repo/notas.markdown'), isTrue);
      expect(AppStore.readable('/repo/lib/main.dart'), isFalse);
      expect(AppStore.readable('/repo/dados.csv'), isFalse);
    });
  });

  group('o markdown, desenhado', () {
    testWidgets('títulos, listas e crases saem como texto, não como marcação', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = reader(
        MxDoc(
          source: DocSource.plan,
          title: 'plano de TASK#47730',
          text: '# Trocar o middleware\n\nMexe em `jwt.dart`.\n\n- primeiro\n- segundo',
        ),
      );

      await pumpReader(tester, store, tab);
      expect(find.text('Trocar o middleware', findRichText: true), findsOneWidget);
      // A crase virou fonte mono no meio do parágrafo, então o que se acha é o
      // parágrafo inteiro sem as crases.
      expect(find.textContaining('jwt.dart', findRichText: true), findsOneWidget);
      expect(find.textContaining('`jwt.dart`', findRichText: true), findsNothing);
      // A cerquilha e o traço ficaram na marcação, que é o ponto do leitor.
      expect(find.textContaining('# Trocar', findRichText: true), findsNothing);
      expect(find.textContaining('- primeiro', findRichText: true), findsNothing);
    });

    testWidgets('um arquivo que sumiu diz isso em vez de abrir em branco', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = reader(MxDoc.file('/nao/existe/PLANO.md'));

      await pumpReader(tester, store, tab);
      expect(find.text('esse arquivo não está mais lá'), findsOneWidget);
      // O painel continua olhando o disco: um arquivo que a sessão reescrever
      // volta sozinho. Cancelado aqui porque o teste acaba antes dele.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('a fita de documentos do painel', () {
    /// O painel dentro de um [AnimatedBuilder], como em `main.dart`: é o que
    /// faz a janela repintar quando o store avisa, e sem isso um teste de
    /// "muda o estado e a fita acompanha" estaria testando o próprio andaime.
    Future<void> pumpPane(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 420,
            child: AnimatedBuilder(
              animation: store,
              builder: (context, _) => TerminalPane(store: store, tab: tab),
            ),
          ),
        ),
      ),
    );

    testWidgets('não existe num painel que não escreveu documento nenhum', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.touched.add('/repo/lib/main.dart');

      await pumpPane(tester, store, tab);
      expect(find.byType(DocBar), findsNothing);
    });

    testWidgets('mostra o plano e os .md, e ignora o resto', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));
      tab.hooks.touched.addAll(['/repo/lib/main.dart', '/repo/PLANO.md', '/repo/dados.csv']);

      await pumpPane(tester, store, tab);
      expect(find.byType(DocBar), findsOneWidget);
      // Uma só: a ficha "plano" mora aqui e não no cabeçalho -- duas fichas
      // com a mesma palavra e a mesma ação a 40px uma da outra eram uma a mais.
      expect(find.text('plano'), findsOneWidget);
      expect(find.text('PLANO.md'), findsOneWidget);
      // A fita responde "o que dá pra ler", não "o que a sessão mexeu" -- essa
      // pergunta continua sendo da tira de arquivos alterados.
      expect(find.text('main.dart'), findsNothing);
      expect(find.text('dados.csv'), findsNothing);
    });

    testWidgets('a ficha do documento aberto no leitor fica acesa', (tester) async {
      final store = AppStore();
      final tab = session(store);
      tab.hooks.plans.add(PlanNote(text: '# o plano'));
      // O leitor na tela, mostrando justamente esse plano.
      store.showPlan(tab);

      await pumpPane(tester, store, tab);
      final lit = find.descendant(
        of: find.byType(DocBar),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == Mx.accent.withValues(alpha: 0.12),
        ),
      );
      expect(lit, findsOneWidget);
      // E apaga quando o leitor passa a mostrar outra coisa.
      tab.hooks.lastMessageFull = 'terminei';
      store.showMessage(tab);
      await tester.pump();
      expect(lit, findsNothing);
      // Encerrado aqui dentro, e não no `tearDown`: pôr um documento na tela
      // agenda a escrita do config, e o teste de widget cobra os timers
      // pendentes antes de o `tearDown` acontecer.
      store.dispose();
    });

    testWidgets('o mais novo vem primeiro', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store);
      tab.hooks.touched.addAll(['/repo/PRIMEIRO.md', '/repo/SEGUNDO.md']);

      await pumpPane(tester, store, tab);
      final novo = tester.getTopLeft(find.text('SEGUNDO.md'));
      final velho = tester.getTopLeft(find.text('PRIMEIRO.md'));
      expect(novo.dx, lessThan(velho.dx));
    });
  });

  /// O arquivo é testado sem widget de propósito: o relógio de um teste de
  /// widget é falso e o disco é real, então uma releitura pedida de dentro da
  /// árvore nunca voltaria — o que se garante aqui é o contrato que o painel
  /// consome, que é "releu, e me diz se mudou".
  group('um documento de disco', () {
    test('é lido, e a releitura só avisa quando o conteúdo mudou', () async {
      final dir = await Directory.systemTemp.createTemp('maestria-leitor');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/PLANO.md')..writeAsStringSync('# antes');

      final doc = MxDoc.file(file.path);
      expect(doc.text, isEmpty);
      expect(await doc.reload(), isTrue);
      expect(doc.text, '# antes');

      // Sem mudança no disco não há repintura: é isto que deixa o painel poder
      // reler de segundo em segundo sem tirar de lugar quem está lendo.
      expect(await doc.reload(), isFalse);

      file.writeAsStringSync('# depois');
      expect(await doc.reload(), isTrue);
      expect(doc.text, '# depois');
    });

    test('um caminho que não existe não é lido nem apaga o que estava na tela', () async {
      final doc = MxDoc.file('/nao/existe/PLANO.md');
      doc.text = '# o que já estava aberto';
      expect(await doc.reload(), isFalse);
      expect(doc.missing, isTrue);
      expect(doc.text, '# o que já estava aberto');
    });

    test('um plano atravessa o config; um arquivo atravessa como caminho', () {
      final plan = MxDoc(source: DocSource.plan, title: 'plano', text: '# o plano');
      expect(MxDoc.fromJson(plan.toJson())!.text, '# o plano');

      final file = MxDoc.file('/repo/PLANO.md');
      expect(file.toJson().containsKey('text'), isFalse);
      expect(MxDoc.fromJson(file.toJson())!.path, '/repo/PLANO.md');
    });
  });
}
