import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/links.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/terminal_pane.dart';
import 'package:xterm/xterm.dart';

/// Uma pasta de mentira com um `.md` dentro, que é o link que interessa: o
/// detector só chama caminho de link quando o arquivo existe mesmo.
Directory withPlan() {
  final dir = Directory.systemTemp.createTempSync('maestria-links');
  File('${dir.path}/PLANO.md').writeAsStringSync('# o plano');
  Directory('${dir.path}/lib').createSync();
  File('${dir.path}/lib/store.dart').writeAsStringSync('void main() {}');
  return dir;
}

/// Uma sessão do claude ocupando o único painel da tela, rodando em [cwd].
MxTab session(AppStore store, String cwd) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: cwd, name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: cwd,
    branch: '',
    customLabel: 'TASK#48757',
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

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

/// Um clique no meio da célula (col, row) do terminal que está na tela.
///
/// A posição vem do próprio render e não de uma conta com o corpo da fonte: a
/// fonte de um teste de widget não é a do app, e o que se quer garantir é o
/// clique em cima de uma célula, não a métrica dela.
Future<void> tapCell(WidgetTester tester, {required int col, required int row}) async {
  final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
  final cell = render.getOffset(CellOffset(col, row));
  final middle = cell + Offset(render.cellSize.width / 2, render.cellSize.height / 2);
  await tester.tapAt(render.localToGlobal(middle));
  // O xterm arma um relógio de duplo clique a cada toque, e um teste de widget
  // cobra os relógios pendentes.
  await tester.pump(kDoubleTapTimeout);
}

void main() {
  group('o link debaixo do clique', () {
    test('a URL no meio da frase é achada por qualquer letra dela', () {
      const line = 'veja https://docs.anthropic.com/claude-code depois';
      for (final column in [5, 20, 42]) {
        expect(linkAt(line, column), 'https://docs.anthropic.com/claude-code');
      }
    });

    test('o ponto que acaba a frase não faz parte do endereço', () {
      expect(linkAt('abre https://x.dev/a.', 10), 'https://x.dev/a');
    });

    test('a moldura da TUI colada na URL também não', () {
      // O Claude desenha caixas, e o traço não é separador de palavra nenhum.
      expect(linkAt('│ https://x.dev/a', 12), 'https://x.dev/a');
      expect(linkAt('(veja https://x.dev/a)', 10), 'https://x.dev/a');
    });

    test('um mailto é link; um ftp:// não, porque o app não sabe abrir', () {
      expect(linkAt('escreva pra mailto:eu@marrow.com.br', 20), 'mailto:eu@marrow.com.br');
      expect(linkAt('pegue em ftp://x.dev/a', 15), isNull);
    });

    test('texto que não é link nenhum não vira link', () {
      // Um clique no meio do terminal é também como se dá o teclado ao painel:
      // o que não é link tem que não fazer nada.
      expect(linkAt('escrevi o middleware e/ou o resto', 22), isNull);
      expect(linkAt('nada aqui', 3), isNull);
      expect(linkAt('', 0), isNull);
      expect(linkAt('abc', 9), isNull);
    });

    test('um caminho da sessão é link; o mesmo caminho sem arquivo não é', () {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(linkAt('escrevi lib/store.dart agora', 12, base: dir.path), 'lib/store.dart');
      expect(linkAt('escrevi lib/sumiu.dart agora', 12, base: dir.path), isNull);
      // Sem base, um caminho relativo não tem contra o que ser resolvido.
      expect(linkAt('escrevi lib/store.dart agora', 12), isNull);
    });

    test('o :42 é endereço pro editor, não parte do nome do arquivo', () {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(linkAt('veja lib/store.dart:42:9', 10, base: dir.path), 'lib/store.dart');
      expect(linkAt('veja ${dir.path}/PLANO.md:3', 10, base: dir.path), '${dir.path}/PLANO.md');
    });

    test('um .md citado sem barra nenhuma é link; a palavra ao lado não', () {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(linkAt('atualizei o PLANO.md', 14, base: dir.path), 'PLANO.md');
      expect(linkAt('atualizei o PLANO.md', 3, base: dir.path), isNull);
    });
  });

  group('o link no buffer do terminal', () {
    test('o clique acha a URL na linha em que ela foi escrita', () {
      final t = Terminal(maxLines: 100);
      t.write('rode isto:\r\nabra https://x.dev/auth em outra aba\r\n');
      expect(linkAtCell(t, const CellOffset(10, 1)), 'https://x.dev/auth');
      // A linha de cima não tem link, e o clique nela não inventa um.
      expect(linkAtCell(t, const CellOffset(3, 0)), isNull);
    });

    test('uma URL quebrada pelo terminal continua sendo uma URL só', () {
      final t = Terminal(maxLines: 100);
      t.resize(40, 10);
      const url = 'https://x.dev/muito/comprida/pra/caber/numa/linha/so?token=abc';
      t.write('abra $url agora');
      // A metade de baixo, clicada: sem juntar a linha lógica ela seria um
      // pedaço de endereço que não abre nada.
      expect(linkAtCell(t, const CellOffset(5, 1)), url);
      expect(linkAtCell(t, const CellOffset(10, 0)), url);
    });

    test('fora do buffer não tem link', () {
      final t = Terminal(maxLines: 100);
      t.write('https://x.dev/a');
      expect(linkAtCell(t, const CellOffset(0, -1)), isNull);
      expect(linkAtCell(t, CellOffset(0, t.buffer.lines.length + 5)), isNull);
    });
  });

  group('seguir o link', () {
    test('um .md abre no leitor, que é o "por dentro" que o app tem', () async {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store, dir.path);

      await store.followLink('PLANO.md', from: tab);
      final reader = store.tabs.firstWhere((t) => t.isReader);
      expect(reader.doc!.path, '${dir.path}/PLANO.md');
      // Ao lado da sessão, não em cima dela.
      expect(store.paneCount, 2);
    });

    test('um link pra arquivo que não existe diz isso em vez de não fazer nada', () async {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store, dir.path);

      await store.followLink('SUMIU.md', from: tab);
      expect(store.tabs.any((t) => t.isReader), isFalse);
      expect(store.banner, contains('não existe'));
    });
  });

  group('o link que o programa marcou (OSC 8)', () {
    /// `ESC]8;;<url>BEL<rótulo>ESC]8;;BEL` — o link como o claude escreve um.
    String marked(String url, String label) => '\x1b]8;;$url\x07$label\x1b]8;;\x07';

    test('a URL está no rótulo, e o rótulo não a tem escrita', () {
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      t.write('abra ${marked('https://x.dev/auth', 'aqui')} agora');

      // "abra " são as colunas 0..4; "aqui", 5..8.
      expect(links.at(const CellOffset(5, 0)), 'https://x.dev/auth');
      expect(links.at(const CellOffset(8, 0)), 'https://x.dev/auth');
      // O espaço antes e o texto depois não são o link.
      expect(links.at(const CellOffset(4, 0)), isNull);
      expect(links.at(const CellOffset(9, 0)), isNull);
      // E a URL não passou pela tela: é isso que o palpite pela forma não
      // tinha como achar.
      expect(t.buffer.getText(), isNot(contains('x.dev')));
      expect(t.buffer.getText(), contains('abra aqui agora'));
    });

    test('um rótulo que o terminal quebrou em duas linhas é um link só', () {
      final t = Terminal(maxLines: 100);
      t.resize(20, 6);
      final links = TermLinks(t);
      t.write('leia ${marked('https://x.dev/a', 'um rótulo bem comprido')}!');

      expect(links.at(const CellOffset(6, 0)), 'https://x.dev/a');
      expect(links.at(const CellOffset(3, 1)), 'https://x.dev/a');
      // O `!` depois do fecha já não é dele.
      expect(links.at(const CellOffset(7, 1)), isNull);
    });

    test('um file:// vira o caminho, que é o que o app sabe abrir por dentro', () {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      t.write(marked('file://${dir.path}/PLANO.md', 'PLANO.md'));

      expect(links.at(const CellOffset(2, 0)), '${dir.path}/PLANO.md');
    });

    test('um link de outra máquina fica sendo URL', () {
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      t.write(marked('file://outra-maquina/etc/hosts', 'hosts'));

      expect(links.at(const CellOffset(2, 0)), 'file://outra-maquina/etc/hosts');
    });

    test('a TUI redesenhou por cima: a célula não é mais do link', () {
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      t.write(marked('https://x.dev/a', 'aqui'));
      expect(links.at(const CellOffset(1, 0)), 'https://x.dev/a');

      // Mesma linha, outro texto -- o que uma TUI faz a cada quadro.
      t.write('\r\x1b[2Koutra coisa');
      expect(links.at(const CellOffset(1, 0)), isNull);
    });

    test('a linha que caiu do scrollback levou o link com ela', () {
      final t = Terminal(maxLines: 30);
      t.resize(20, 4);
      final links = TermLinks(t);
      t.write('${marked('https://x.dev/a', 'aqui')}\r\n');
      expect(links.at(const CellOffset(1, 0)), 'https://x.dev/a');

      for (var i = 0; i < 40; i++) {
        t.write('linha $i\r\n');
      }
      for (var y = 0; y < t.buffer.lines.length; y++) {
        expect(links.at(CellOffset(1, y)), isNull, reason: 'linha $y');
      }
    });

    test('abrir sem fechar, e fechar sem nada dentro, não inventam link', () {
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      // Um abre novo fecha o de antes, como num terminal de verdade.
      t.write('\x1b]8;;https://x.dev/a\x07um\x1b]8;;https://x.dev/b\x07dois\x1b]8;;\x07');
      expect(links.at(const CellOffset(0, 0)), 'https://x.dev/a');
      expect(links.at(const CellOffset(3, 0)), 'https://x.dev/b');

      // Abriu e fechou sem escrever nada: não há célula pra clicar.
      t.write('\r\n${'\x1b]8;;https://x.dev/c\x07'}\x1b]8;;\x07texto');
      expect(links.at(const CellOffset(0, 1)), isNull);
    });

    test('a URI com ; dentro chega inteira', () {
      final t = Terminal(maxLines: 100);
      final links = TermLinks(t);
      t.write(marked('https://x.dev/a?b=1;c=2', 'aqui'));

      expect(links.at(const CellOffset(1, 0)), 'https://x.dev/a?b=1;c=2');
    });
  });

  group('o clique no terminal', () {
    testWidgets('num .md do scrollback, abre o leitor', (tester) async {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppStore();
      final tab = session(store, dir.path);
      tab.term.terminal.write('escrevi PLANO.md agora\r\n');

      await pumpPane(tester, store, tab);
      // A oitava coluna é o P de PLANO.md.
      await tapCell(tester, col: 8, row: 0);

      final reader = store.tabs.firstWhereOrNull((t) => t.isReader);
      expect(reader, isNotNull, reason: 'o clique no link não abriu nada');
      expect(reader!.doc!.path, '${dir.path}/PLANO.md');
      // Encerrado aqui dentro: pôr um documento na tela agenda a escrita do
      // config, e o teste de widget cobra os timers pendentes antes de o
      // `tearDown` acontecer.
      store.dispose();
    });

    testWidgets('num rótulo de OSC 8, segue a URL que estava escondida nele', (tester) async {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppStore();
      final tab = session(store, dir.path);
      tab.term.terminal.write(
        'veja \x1b]8;;file://${dir.path}/PLANO.md\x07o plano\x1b]8;;\x07 agora\r\n',
      );

      await pumpPane(tester, store, tab);
      // A sexta coluna é o "o" de "o plano" -- na tela não há URL nenhuma.
      await tapCell(tester, col: 5, row: 0);

      final reader = store.tabs.firstWhereOrNull((t) => t.isReader);
      expect(reader, isNotNull, reason: 'o clique no rótulo do link não abriu nada');
      expect(reader!.doc!.path, '${dir.path}/PLANO.md');
      store.dispose();
    });

    testWidgets('em cima de texto comum, não abre nada', (tester) async {
      final dir = withPlan();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = session(store, dir.path);
      tab.term.terminal.write('escrevi PLANO.md agora\r\n');

      await pumpPane(tester, store, tab);
      await tapCell(tester, col: 2, row: 0);

      expect(store.tabs.any((t) => t.isReader), isFalse);
      expect(store.banner, isNull);
    });
  });
}
