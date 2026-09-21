import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/vt.dart';
import 'package:xterm/xterm.dart';

/// Os atributos da primeira linha do buffer, célula por célula.
String attrs(Terminal t) {
  final line = t.buffer.lines[0];
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final code = line.getCodePoint(i);
    if (code == 0) break;
    final flags = line.getAttributes(i);
    final marks = [
      if (flags & CellFlags.bold != 0) 'b',
      if (flags & CellFlags.faint != 0) 'f',
      if (flags & CellFlags.underline != 0) 'u',
    ];
    out.write('${String.fromCharCode(code)}${marks.join()} ');
  }
  return out.toString().trimRight();
}

void main() {
  group('VtTerminal', () {
    test('ESC[22m fecha o negrito que o ESC[1m abriu', () {
      final t = VtTerminal(maxLines: 100);
      t.write('\x1b[1mA\x1b[22mB');
      expect(attrs(t), 'Ab B');
    });

    test('e continua fechando o faint, que é a outra metade do 22', () {
      final t = VtTerminal(maxLines: 100);
      t.write('\x1b[2mA\x1b[22mB');
      expect(attrs(t), 'Af B');
    });

    test('o xterm de fábrica é o que erra -- a régua deste teste', () {
      final t = Terminal(maxLines: 100);
      t.write('\x1b[1mA\x1b[22mB');
      expect(attrs(t), 'Ab Bb');
    });

    // A TUI do Claude Code roda na tela alternativa e sai dela sem resetar
    // nada: quem devolve os atributos é o próprio `ESC[?1049l`. Sem isso, o
    // sublinhado que ela deixou aberto vale pro que o painel escrever depois
    // -- o prompt do shell de volta, e daí em diante tudo.
    test('sair da tela alternativa devolve o atributo que a TUI abriu', () {
      final t = VtTerminal(maxLines: 100);
      t.write('\x1b[?1049h\x1b[4mTUI\x1b[?1049lA');
      expect(attrs(t), 'A');
    });

    test('e o xterm de fábrica leva o sublinhado pra fora -- a régua', () {
      final t = Terminal(maxLines: 100);
      t.write('\x1b[?1049h\x1b[4mTUI\x1b[?1049lA');
      expect(attrs(t), 'Au');
    });
  });

  group('VtScrubber', () {
    test('o XTMODKEYS do Claude Code não vira sublinhado', () {
      final scrub = VtScrubber();
      final t = VtTerminal(maxLines: 100);
      t.write(scrub('\x1b[>4;2mABC'));
      expect(attrs(t), 'A B C');
    });

    test('nem na forma sem parâmetro, que é a do reset', () {
      final scrub = VtScrubber();
      expect(scrub('\x1b[>4mABC'), 'ABC');
    });

    test('texto e SGR de verdade passam intactos', () {
      final scrub = VtScrubber();
      const line = 'a \x1b[1mb\x1b[22m \x1b[38;5;208mc\x1b[39m\r\n';
      expect(scrub(line), line);
    });

    test('CSI privado que não é `m` passa -- ESC[>c espera resposta', () {
      final scrub = VtScrubber();
      expect(scrub('\x1b[>c\x1b[<u\x1b[?25lA'), '\x1b[>c\x1b[<u\x1b[?25lA');
    });

    test('sequência partida entre dois chunks do pty ainda é vista', () {
      final scrub = VtScrubber();
      expect(scrub('A\x1b[>4'), 'A');
      expect(scrub(';2mB'), 'B');
    });

    test('e o ESC solto no fim de um chunk espera o resto', () {
      final scrub = VtScrubber();
      expect(scrub('A\x1b'), 'A');
      expect(scrub('[>4mB'), 'B');
    });

    test('o que ficou pendurado demais é texto, e sai', () {
      final scrub = VtScrubber();
      final long = '\x1b[>${'9' * 40}';
      expect(scrub(long), long);
    });
  });

  // A âncora é o que sabe em que linha uma seleção começou e em que célula um
  // `OSC 8` foi pendurado. Ela conta a fila pela linha, a linha conta pela
  // lista -- e a lista, depois de aparar o scrollback, passa a contar errado.
  // É esse número que põe a seleção trinta linhas abaixo do mouse.
  group('a âncora depois de apagar o scrollback', () {
    /// Um terminal de 10 linhas de janela com 30 escritas, que é uma janela e
    /// vinte e uma de scrollback.
    T cheio<T extends Terminal>(T t) {
      t.resize(80, 10);
      for (var i = 0; i < 30; i++) {
        t.write('linha $i\r\n');
      }
      return t;
    }

    test('a âncora nova diz a linha em que foi feita', () {
      final t = cheio(VtTerminal(maxLines: 8000));
      t.write('\x1b[3J');

      expect(t.buffer.createAnchor(0, 2).y, 2);
      expect(t.buffer.createAnchor(0, 9).y, 9);
    });

    test('o xterm de fábrica é o que erra -- a régua deste teste', () {
      final t = cheio(Terminal(maxLines: 8000));
      t.write('\x1b[3J');

      // 21 linhas caíram, e a lista não tomou conhecimento.
      expect(t.buffer.createAnchor(0, 2).y, 23);
    });

    test('e a âncora feita antes do corte acompanha a linha dela', () {
      final t = cheio(VtTerminal(maxLines: 8000));
      // A última linha escrita está no fim do buffer; depois do corte ela é a
      // penúltima da janela, e a âncora tem que dizer isso.
      final anchor = t.buffer.createAnchor(0, t.buffer.lines.length - 2);
      t.write('\x1b[3J');

      expect(anchor.y, t.buffer.lines.length - 2);
    });

    test('e o corte que vem do resize da tela alternativa também', () {
      final t = VtTerminal(maxLines: 8000);
      t.resize(80, 10);
      t.write('\x1b[?1049h');
      for (var i = 0; i < 20; i++) {
        t.write('tui $i\r\n');
      }
      t.resize(80, 6);

      expect(t.buffer.createAnchor(0, 1).y, 1);
    });
  });
}
