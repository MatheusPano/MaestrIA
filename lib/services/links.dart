/// O link que está debaixo do cursor num texto que não sabe que tem um.
///
/// O leitor de markdown ganha os links de graça: o parser diz onde cada um
/// começa e acaba, e clicar num deles é um `onTapLink`. O terminal não ganha
/// nada — a saída do Claude chega como uma parede de caracteres, e o
/// `https://…` ou o `lib/services/store.dart:42` no meio dela é texto igual ao
/// resto. Quem decide que ali tem link é isto, pela forma do que foi clicado.
///
/// Um programa pode dizer onde tem link em vez de deixar adivinhar — é o que
/// `OSC 8` é, e é o que [TermLinks] guarda. Quando ele diz, é ele quem manda:
/// o palpite pela forma é para o texto de quem não disse nada.
///
/// Conservador de propósito: um clique no terminal que não caia em cima de um
/// link tem que não fazer nada, porque clicar no meio do terminal é também
/// como se dá o teclado ao painel. Por isso um caminho só é link se o arquivo
/// existir mesmo — senão qualquer palavra com uma barra no meio ("e/ou")
/// viraria um aviso de arquivo não encontrado.
library;

import 'dart:io';

import 'package:xterm/xterm.dart';

import 'docs.dart';
import 'paths.dart';

/// Os caracteres que não podem estar *dentro* de um link.
///
/// Aspas, parênteses e crase entram aqui porque é assim que a saída do Claude
/// embrulha um caminho — `(veja lib/a.dart)` tem que dar `lib/a.dart` e não o
/// parêntese junto.
const _breaks = ' \t\u00a0"\'`<>|()[]{},;*';

/// O que sobra colado no fim de um link quando ele acaba uma frase.
const _tail = '.,;:!?\'"';

/// Os dois esquemas que o app sabe seguir. Ver [AppStore.followLink]: um
/// `ftp://` detectado aqui só chegaria lá pra virar "esse arquivo não existe".
final _url = RegExp(r'(?:https?://|mailto:)\S');

/// `lib/a.dart:42` — o número da linha é endereço pro editor, não parte do
/// nome do arquivo, e é assim que o Claude cita um trecho.
final _atLine = RegExp(r'^(.+?):\d+(?::\d+)?$');

/// Onde [path] fica de verdade: o que veio do link é relativo à pasta de onde
/// o link veio, que é o que o autor dele quis dizer.
String resolveLinkPath(String path, {String? base}) {
  final expanded = expandHome(path);
  if (expanded.startsWith('/')) return expanded;
  return base == null || base.isEmpty ? expanded : '$base/$expanded';
}

/// O link debaixo da coluna [column] de [line], ou null se ali não tem link.
///
/// [base] é a pasta contra a qual um caminho relativo é resolvido — sem ela,
/// só caminho absoluto conta como link.
String? linkAt(String line, int column, {String? base}) {
  if (column < 0 || column >= line.length) return null;
  if (_breaks.contains(line[column])) return null;

  var from = column;
  var to = column;
  while (from > 0 && !_breaks.contains(line[from - 1])) {
    from--;
  }
  while (to + 1 < line.length && !_breaks.contains(line[to + 1])) {
    to++;
  }
  final token = line.substring(from, to + 1);

  // A URL pode vir colada num traço da moldura da TUI (`│https://…`), então o
  // que vale é de onde o esquema começa — não o começo da palavra.
  if (_url.firstMatch(token) case final url?) {
    // Refeito sobre o que sobrou: um `https://` que perdeu o resto pro corte
    // do fim da frase não é endereço de nada.
    final trimmed = _trimTail(token.substring(url.start));
    return _url.hasMatch(trimmed) ? trimmed : null;
  }

  final path = _trimTail(_atLine.firstMatch(token)?.group(1) ?? token);
  // Sem barra, só markdown: um `PLANO.md` citado numa frase é um link, e a
  // palavra "relatório" ao lado dele não é.
  if (!path.contains('/') && !isMarkdownPath(path)) return null;
  // A âncora não é arquivo; quem existe no disco é o que vem antes dela.
  if (!File(resolveLinkPath(path.split('#').first, base: base)).existsSync()) return null;
  return path;
}

/// O link debaixo da célula [cell] do buffer de [terminal].
///
/// A linha lida é a lógica e não a da tela: o terminal quebra uma URL longa no
/// meio, e a metade em que se clicou, sozinha, não é link nenhum.
String? linkAtCell(Terminal terminal, CellOffset cell, {String? base}) {
  final lines = terminal.buffer.lines;
  if (cell.y < 0 || cell.y >= lines.length) return null;
  final width = terminal.viewWidth;

  var first = cell.y;
  while (first > 0 && lines[first].isWrapped) {
    first--;
  }
  var last = cell.y;
  while (last + 1 < lines.length && lines[last + 1].isWrapped) {
    last++;
  }

  final text = StringBuffer();
  for (var y = first; y <= last; y++) {
    // Célula por célula, e não `getText()`: aquele pula as células vazias, e
    // aí a coluna do clique não bate mais com a posição no texto.
    final line = lines[y];
    for (var x = 0; x < width; x++) {
      final code = line.getCodePoint(x);
      text.writeCharCode(code == 0 ? 0x20 : code);
    }
  }
  return linkAt(text.toString(), (cell.y - first) * width + cell.x, base: base);
}

String _trimTail(String value) {
  var end = value.length;
  while (end > 0 && _tail.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}

/// Os links que o programa **marcou**, em vez dos que a gente adivinha.
///
/// `OSC 8` é como um programa diz "estas células são um link": ele escreve
/// `ESC]8;;https://x.dev BEL`, escreve o rótulo, e fecha com `ESC]8;; BEL`. A
/// URL viaja fora do texto — na tela só fica a palavra. É o que o `claude`
/// escreve quando acha que o terminal entende (`supports-hyperlinks`: um
/// `TERM_PROGRAM` conhecido, um `VTE_VERSION >= 0.50`, um `FORCE_HYPERLINK` no
/// ambiente), e é o que o `ls --hyperlink`, o `gh` e o `cargo` escrevem também.
///
/// O xterm 4.0.0 não guarda nada disso: o parser trata `OSC 8` como sequência
/// privada e larga em `onPrivateOSC` (`escape/parser.dart`, `unknownOSC`), sem
/// pendurar a URL em célula nenhuma. Sem isto aqui, uma palavra que o claude
/// pintou de azul chega ao painel como texto comum, e o clique nela — que só
/// sabe procurar `https://` no meio do texto, ver [linkAt] — não acha link
/// nenhum e não faz nada. Era isso o "no terminal normal abre, no maestria
/// não".
///
/// O que fica guardado são as duas pontas do rótulo, como [CellAnchor]: um
/// âncora acompanha a linha dela pelo scrollback e pela redobra do resize, e
/// se solta quando a linha cai fora — que é justo quando o link deixa de
/// existir. O rótulo também fica, em texto: uma TUI redesenha a tela por cima
/// de si mesma, e uma célula que agora tem outra palavra não é mais a palavra
/// que era o link.
class TermLinks {
  TermLinks(this._terminal) {
    _terminal.onPrivateOSC = read;
  }

  final Terminal _terminal;

  /// Os trechos já fechados, do mais antigo pro mais novo.
  final _spans = <_LinkSpan>[];

  /// Quantos trechos ficam guardados. Uma sessão longa marca link a rodo, e
  /// os antigos já saíram do scrollback muito antes disto encher.
  static const _maxSpans = 512;

  String? _url;
  CellAnchor? _from;
  bool _alt = false;

  /// Um `OSC` privado, que é onde o xterm larga o `OSC 8`.
  ///
  /// Chamado de dentro do `write`, e é isso que faz a conta fechar: quando o
  /// abre chega, o cursor está na célula em que o rótulo vai começar; quando o
  /// fecha chega, ele está uma célula depois do fim dele.
  void read(String code, List<String> args) {
    if (code != '8') return;
    // `OSC 8 ; params ; URI`: o primeiro campo são os parâmetros (`id=x`), e a
    // URI é todo o resto — um `;` dentro dela não a divide em duas.
    final url = args.length < 2 ? '' : args.sublist(1).join(';');
    // Um abre sem fecha antes dele fecha o de antes: é o que um terminal faz,
    // e é o que um programa que se enrola escreve.
    _close();
    if (url.isEmpty) return;
    _url = url;
    _alt = _terminal.buffer.isAltBuffer;
    _from = _terminal.buffer.createAnchorFromCursor();
  }

  /// A URL que o programa pendurou na célula [cell], ou null se ali não tem.
  String? at(CellOffset cell) {
    final alt = _terminal.buffer.isAltBuffer;
    for (var i = _spans.length - 1; i >= 0; i--) {
      final span = _spans[i];
      // A linha do link saiu do scrollback: o link foi com ela.
      if (!span.attached) {
        _spans.removeAt(i).dispose();
        continue;
      }
      if (span.alt != alt || !span.holds(cell)) continue;
      // A TUI redesenhou por cima: essas células têm outra coisa escrita
      // agora, e o link não é mais delas.
      if (_labelBetween(span.from.offset, span.to.offset) != span.label) {
        _spans.removeAt(i).dispose();
        continue;
      }
      return _localPath(span.url);
    }
    return null;
  }

  /// Fecha o trecho aberto, se o que ele pegou for rótulo de verdade.
  void _close() {
    final url = _url;
    final from = _from;
    _url = null;
    _from = null;
    if (url == null || from == null) return;
    // Um link aberto na tela alternativa e fechado fora dela não tem trecho:
    // as duas pontas estão em buffers diferentes.
    if (!from.attached || _terminal.buffer.isAltBuffer != _alt) {
      from.dispose();
      return;
    }
    final to = _terminal.buffer.createAnchorFromCursor();
    final label = _labelBetween(from.offset, to.offset);
    // Abriu e fechou sem escrever nada: não há o que clicar.
    if (label.isEmpty) {
      from.dispose();
      to.dispose();
      return;
    }
    _spans.add(_LinkSpan(url: url, from: from, to: to, label: label, alt: _alt));
    while (_spans.length > _maxSpans) {
      _spans.removeAt(0).dispose();
    }
  }

  /// O que está escrito de [from] até [to], sem o [to] — o rótulo do link.
  ///
  /// Célula por célula pelo mesmo motivo de [linkAtCell]: uma célula que a TUI
  /// nunca escreveu é o espaço que ela parece, e não um nada que encurta o
  /// texto e desalinha a comparação.
  String _labelBetween(CellOffset from, CellOffset to) {
    if (to.y < from.y || (to.y == from.y && to.x <= from.x)) return '';
    final lines = _terminal.buffer.lines;
    final width = _terminal.viewWidth;
    final out = StringBuffer();
    for (var y = from.y; y <= to.y && y < lines.length; y++) {
      final line = lines[y];
      final start = y == from.y ? from.x : 0;
      final end = y == to.y ? to.x : width;
      for (var x = start; x < end && x < line.length; x++) {
        final code = line.getCodePoint(x);
        out.writeCharCode(code == 0 ? 0x20 : code);
      }
    }
    return out.toString();
  }
}

/// Um `OSC 8` que abriu e fechou.
class _LinkSpan {
  _LinkSpan({
    required this.url,
    required this.from,
    required this.to,
    required this.label,
    required this.alt,
  });

  final String url;
  final CellAnchor from;
  final CellAnchor to;

  /// O que estava escrito no trecho quando ele fechou. Ver [TermLinks].
  final String label;

  /// Se o trecho é da tela alternativa. A âncora conta a linha dela dentro do
  /// buffer em que está, e as duas telas contam do zero cada uma.
  final bool alt;

  bool get attached => from.attached && to.attached;

  /// Se [cell] cai no rótulo: de [from] até [to], sem o [to].
  bool holds(CellOffset cell) {
    final start = from.offset;
    final end = to.offset;
    if (cell.y < start.y || cell.y > end.y) return false;
    if (cell.y == start.y && cell.x < start.x) return false;
    if (cell.y == end.y && cell.x >= end.x) return false;
    return true;
  }

  void dispose() {
    from.dispose();
    to.dispose();
  }
}

/// O caminho de um `file://`, que é como quem lista arquivos marca um link.
///
/// Vale a troca porque o app abre caminho melhor do que abre URL: um `.md`
/// assim cai no leitor em vez de sair pro navegador (ver [AppStore.followLink]).
String _localPath(String url) {
  if (!url.startsWith('file://')) return url;
  final uri = Uri.tryParse(url);
  // `file://outra-maquina/x` não é arquivo que esta máquina tenha.
  if (uri == null || (uri.host.isNotEmpty && uri.host != 'localhost')) return url;
  if (uri.path.isEmpty) return url;
  try {
    return uri.toFilePath();
  } on UnsupportedError {
    return url;
  }
}
