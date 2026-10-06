/// A seleção que fica no texto quando o programa rola a tela por conta própria.
///
/// O relato: "seleciono um texto e scrollo, e a seleção não fica naquele
/// texto, ela acompanha a tela". Isso é a tela alternativa, que é onde o
/// `claude` vive: ali não há scrollback, e rolar é o programa redesenhar as
/// mesmas fileiras com outro texto (ver `TermSession.wheel`). A seleção do
/// xterm é presa a objetos de linha (`CellAnchor`), não ao que está escrito
/// neles — a linha continua no lugar, o texto dela muda, e o realce fica
/// parado na tela enquanto o texto passa por baixo.
///
/// Quando o programa rola com sequências de scroll de verdade (`CSI S`, uma
/// região com `DECSTBM`), as linhas andam e as âncoras vão junto — desde que
/// o `VtTerminal` as recoloque na lista, que o xterm 4.0.0 as desanexa no
/// caminho (ver o sétimo item de `vt.dart`). Isso aqui é pro outro jeito de
/// rolar, que é o que o claude usa.
///
/// O que se faz aqui é o que o xterm não tem como fazer: lembrar o que estava
/// escrito nas fileiras selecionadas e, depois que a tela muda, procurar pra
/// onde esse texto foi. Achou: a seleção vai junto. Não achou — o texto rolou
/// pra fora da tela, ou foi apagado —: a seleção some, porque não há mais o
/// que ela selecionava.
///
/// Só na tela alternativa. Na principal o scrollback é do xterm, as linhas
/// andam de verdade quando a saída empurra a tela, e a âncora já vai junto.
library;

import 'dart:async';
import 'dart:io';

import 'package:xterm/xterm.dart';

// DEBUG temporário -- remover.
void _log(String msg) {
  try {
    File('/private/tmp/claude-501/-Volumes-Dev-Mac-repos-Pessoal-maestria-v2/496a86f6-3762-4829-9abc-be86eae0b0ed/scratchpad/sticky.log').writeAsStringSync('${DateTime.now().toIso8601String()} $msg\n', mode: FileMode.append);
  } catch (_) {}
}

class StickySelection {
  StickySelection(this.terminal, this.controller) {
    controller.addListener(_selected);
    terminal.addListener(_written);
  }

  final Terminal terminal;
  final TerminalController controller;

  /// Onde a seleção estava da última vez que ela estava certa, nas duas pontas
  /// que o xterm lhe deu — `begin` é onde o arrasto começou, que pode estar
  /// depois de `end`.
  CellOffset? _begin;
  CellOffset? _end;

  /// O texto de cada fileira que a seleção toca, de cima pra baixo, no momento
  /// em que [_begin] e [_end] foram anotados. A fileira inteira, e não só o
  /// trecho selecionado: uma palavra solta aparece em muitos lugares da tela,
  /// a linha em volta dela quase nunca.
  List<String>? _rows;

  /// A próxima conferência, já marcada.
  Timer? _check;

  /// Se a última conferência não achou o texto.
  ///
  /// Uma vez não basta pra desistir: o pty entrega um quadro do programa em
  /// quantos pedaços a leitura quiser, e uma conferência que cai entre dois
  /// deles vê a tela pela metade.
  bool _missed = false;

  /// Quem está mexendo na seleção somos nós, e não quem arrastou o mouse.
  bool _moving = false;

  /// O intervalo entre uma escrita e a conferência que ela pede.
  ///
  /// Um limite, não uma espera: enquanto o programa escreve sem parar — o
  /// claude respondendo —, conferir só depois do silêncio deixaria a seleção
  /// no lugar errado a resposta inteira.
  static const _settle = Duration(milliseconds: 30);

  /// O que a tela pela metade ganha pra terminar de chegar. Ver [_missed].
  static const _grace = Duration(milliseconds: 120);

  void _selected() {
    if (_moving) return;
    final range = controller.selection;
    _log('selected alt=${terminal.isUsingAltBuffer} range=${range?.begin}..${range?.end} '
        'mouse=${terminal.mouseMode} lines=${terminal.buffer.lines.length} view=${terminal.viewHeight}');
    if (range == null || !terminal.isUsingAltBuffer) return _forget();
    // O controller avisa de outras coisas também. Uma seleção que não mudou
    // de lugar não é motivo pra reler a tela — que pode estar justamente no
    // meio de um quadro, com a seleção ainda por corrigir.
    if (range.begin == _begin && range.end == _end) return;
    _begin = range.begin;
    _end = range.end;
    _rows = _read(_top(range.begin, range.end), _bottom(range.begin, range.end));
    _missed = false;
    _log('  rows=${_rows!.map((r) => '«${r.trimRight()}»').join(' | ')}');
  }

  void _written() {
    if (_rows == null) return;
    _check ??= Timer(_settle, _follow);
  }

  void _follow() {
    _check = null;
    final rows = _rows;
    if (_begin == null || _end == null || rows == null) return;
    if (!terminal.isUsingAltBuffer) return _forget();

    // Um scroll de verdade leva as âncoras junto com as linhas (ver o sétimo
    // item de `vt.dart`): a seleção já está onde o texto foi, e é dali que se
    // confere.
    final current = controller.selection;
    final begin = current?.begin ?? _begin!;
    final end = current?.end ?? _end!;

    final shift = _find(rows, _top(begin, end));
    _log('follow alt=${terminal.isUsingAltBuffer} current=${current?.begin}..${current?.end} '
        'saved=$_begin..$_end shift=$shift missed=$_missed');
    if (shift == null || shift != 0) {
      final lines = terminal.buffer.lines;
      for (var y = 0; y < lines.length; y++) {
        _log('  $y «${lines[y].getText().trimRight()}»');
      }
    }
    if (shift == null) {
      if (!_missed) {
        _missed = true;
        _check = Timer(_grace, _follow);
        return;
      }
      _set(controller.clearSelection);
      return _forget();
    }
    _missed = false;

    // No lugar e com as âncoras vivas: nada mudou debaixo da seleção.
    if (shift == 0 && current != null) {
      _begin = begin;
      _end = end;
      return;
    }
    final buffer = terminal.buffer;
    final from = CellOffset(begin.x, begin.y + shift);
    final to = CellOffset(end.x, end.y + shift);
    _set(
      () => controller.setSelection(
        buffer.createAnchorFromOffset(from),
        buffer.createAnchorFromOffset(to),
      ),
    );
    _begin = from;
    _end = to;
  }

  /// Quantas fileiras o texto de [rows] andou desde [top], ou null se ele não
  /// está mais na tela.
  ///
  /// O deslocamento menor primeiro: um quadro anda pouco de cada vez, e uma
  /// fileira que se repete mais longe — uma linha em branco, um separador —
  /// não deve roubar a seleção da que só desceu uma casa.
  int? _find(List<String> rows, int top) {
    final height = terminal.buffer.lines.length;
    for (var distance = 0; distance < height; distance++) {
      for (final shift in distance == 0 ? const [0] : [distance, -distance]) {
        final at = top + shift;
        if (at < 0 || at + rows.length > height) continue;
        if (_matches(rows, at)) return shift;
      }
    }
    return null;
  }

  bool _matches(List<String> rows, int at) {
    final lines = terminal.buffer.lines;
    for (var i = 0; i < rows.length; i++) {
      if (_text(lines[at + i]) != rows[i]) return false;
    }
    return true;
  }

  List<String> _read(int top, int bottom) {
    final lines = terminal.buffer.lines;
    return [
      for (var y = top; y <= bottom; y++)
        if (y >= 0 && y < lines.length) _text(lines[y]),
    ];
  }

  /// A fileira como ela aparece, e não como o xterm a conta.
  ///
  /// O claude desenha um espaço pulando o cursor por cima dele, e ao repintar
  /// a mesma frase às vezes o escreve de verdade: a célula que era zero vira
  /// um `0x20`. Na tela as duas são o mesmo branco; pro `getText` uma é nada
  /// e a outra é espaço (ver o quinto item de `vt.dart`), e a frase que só
  /// desceu duas fileiras parecia ter sumido. Aqui as duas são espaço, e o
  /// branco do fim da fileira, que ninguém desenhou, não conta.
  static String _text(BufferLine line) {
    final out = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final codePoint = line.getCodePoint(i);
      out.writeCharCode(codePoint == 0 ? 0x20 : codePoint);
    }
    return out.toString().trimRight();
  }

  void _set(void Function() change) {
    _moving = true;
    try {
      change();
    } finally {
      _moving = false;
    }
  }

  void _forget() {
    _check?.cancel();
    _check = null;
    _begin = null;
    _end = null;
    _rows = null;
    _missed = false;
  }

  static int _top(CellOffset a, CellOffset b) => a.y < b.y ? a.y : b.y;
  static int _bottom(CellOffset a, CellOffset b) => a.y > b.y ? a.y : b.y;
}
