import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// Um achado da busca no painel: da célula [from] até antes de [to].
///
/// O fim é exclusivo porque é assim que o xterm pinta um trecho -- ver
/// `BufferRangeLine` --, e um achado que vira duas linhas (a resposta do Claude
/// quebrada pela largura do painel) é um trecho só, não dois.
@immutable
class TermHit {
  const TermHit(this.from, this.to);

  final CellOffset from;
  final CellOffset to;

  @override
  bool operator ==(Object other) => other is TermHit && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'TermHit($from, $to)';
}

/// Onde [query] aparece no que o painel tem escrito, de cima pra baixo.
///
/// A conta é por linha *lógica*: as linhas que o terminal quebrou por falta de
/// largura (`isWrapped`) são juntadas antes de procurar, senão uma palavra
/// cortada no fim da linha nunca seria achada -- e é justo nos painéis
/// estreitos da grade que isso mais acontece.
///
/// Maiúscula só conta se a busca tiver uma: `erro` acha `Erro` e `ERRO`, e
/// `Erro` acha só ele. É o "smart case" do vim e do ripgrep, e poupa um botão.
///
/// [limit] porque cada achado vira um destaque que o xterm pinta a cada
/// quadro; mil já é mais do que alguém vai percorrer com o Enter.
List<TermHit> findInTerminal(Terminal terminal, String query, {int limit = 1000}) {
  if (query.isEmpty) return const [];
  final pattern = RegExp(RegExp.escape(query), caseSensitive: query != query.toLowerCase());
  final lines = terminal.buffer.lines;
  final width = terminal.viewWidth;
  final hits = <TermHit>[];

  var first = 0;
  while (first < lines.length && hits.length < limit) {
    var last = first;
    while (last + 1 < lines.length && lines[last + 1].isWrapped) {
      last++;
    }

    // Célula por célula, e não `getText()`, pelo mesmo motivo de
    // `linkAtCell`: aquele pula as células vazias, e aí a posição no texto
    // não diz mais em que coluna o achado está. [cells] é essa ponte, uma
    // entrada por unidade da string: `y << 16 | x`.
    final text = StringBuffer();
    final cells = <int>[];
    for (var y = first; y <= last; y++) {
      final line = lines[y];
      final end = min(width, line.length);
      for (var x = 0; x < end; x++) {
        final code = line.getCodePoint(x);
        // A metade de trás de um caractere largo (CJK, emoji) é uma célula
        // vazia de largura zero; como espaço, `你好` viraria `你 好`.
        if (code == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
        final char = code == 0 ? 0x20 : code;
        text.writeCharCode(char);
        cells.add(y << 16 | x);
        // Fora do plano básico são duas unidades na string pra uma célula.
        if (char > 0xFFFF) cells.add(y << 16 | x);
      }
    }

    for (final m in pattern.allMatches(text.toString())) {
      final start = cells[m.start];
      final end = cells[m.end - 1];
      final endY = end >> 16;
      final endX = end & 0xFFFF;
      // Termina depois da última célula, que num caractere largo são duas.
      final span = lines[endY].getWidth(endX) == 2 ? 2 : 1;
      hits.add(TermHit(CellOffset(start & 0xFFFF, start >> 16), CellOffset(endX + span, endY)));
      if (hits.length >= limit) break;
    }
    first = last + 1;
  }
  return hits;
}
