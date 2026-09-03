/// O link que está debaixo do cursor num texto que não sabe que tem um.
///
/// O leitor de markdown ganha os links de graça: o parser diz onde cada um
/// começa e acaba, e clicar num deles é um `onTapLink`. O terminal não ganha
/// nada — a saída do Claude chega como uma parede de caracteres, e o
/// `https://…` ou o `lib/services/store.dart:42` no meio dela é texto igual ao
/// resto. Quem decide que ali tem link é isto, pela forma do que foi clicado.
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
