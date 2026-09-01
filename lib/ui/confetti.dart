import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Confete, pros dois momentos do app que merecem um.
///
/// Fica de fora do estado da aplicação de propósito: nada aqui é salvo, nada
/// pode ser desfeito, e nada sobrevive aos poucos segundos que dura. É uma
/// folha por cima da janela — [IgnorePointer], então clicar durante a festa
/// acerta o que estava embaixo — que se remove sozinha quando acaba.
///
/// Dois tamanhos, porque as duas conclusões não são do mesmo tamanho: um
/// projeto inteiro ganha a janela toda, uma sessão ganha um punhado no lugar
/// onde você clicou. Se a sessão ganhasse a mesma festa do projeto, nenhuma
/// das duas significaria nada.
class Confetti {
  /// Dois canhões, um em cada canto de baixo, mirados pra dentro.
  ///
  /// O canto é escolha e não preguiça: um estouro no meio da tela tampa
  /// justamente o painel que o projeto acabou de deixar, e as duas diagonais
  /// subindo dizem "acabou" de longe, sem esconder nada do que ficou.
  static void fire(BuildContext context) =>
      _open(context, (done) => _Burst.cannons(onDone: done));

  /// Um punhado saindo de [at] (posição global, tipicamente o botão que foi
  /// clicado): a versão de bolso, pra uma sessão marcada como concluída.
  static void puff(BuildContext context, {required Offset at}) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final box = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || box.size.isEmpty) return;
    // Guardado em fração da folha, como todo o resto: o tamanho da janela só
    // se conhece na hora de pintar.
    final local = box.globalToLocal(at);
    final origin = Offset(local.dx / box.size.width, local.dy / box.size.height);
    _open(context, (done) => _Burst.puff(at: origin, onDone: done));
  }

  static void _open(BuildContext context, _Burst Function(VoidCallback) build) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    var gone = false;
    entry = OverlayEntry(
      builder: (_) => build(() {
        // O ticker e um `dispose` da janela podem chegar aqui os dois.
        if (gone) return;
        gone = true;
        entry.remove();
      }),
    );
    overlay.insert(entry);
  }
}

/// Um papelzinho: de onde saiu, pra onde foi, e como ele gira no caminho.
///
/// Guardado em fração da tela, não em pixels, porque o tamanho da janela só
/// se conhece na hora de pintar — e redimensionar no meio do estouro não pode
/// mandar o confete pra fora do mundo.
class _Bit {
  /// Um papel de canhão: sai do canto de baixo, pra dentro e pra cima.
  _Bit.cannon(Random r, {required bool fromLeft})
    : origin = fromLeft ? const Offset(0, 1) : const Offset(1, 1),
      // Entre 35° e 80° acima da horizontal, apontando pro meio da janela.
      angle = fromLeft ? _lerp(r, 0.19, 0.44) * pi : pi - _lerp(r, 0.19, 0.44) * pi,
      speed = _lerp(r, 2.1, 3.1),
      spin = _lerp(r, -9, 9),
      flutter = _lerp(r, 5, 11),
      phase = r.nextDouble() * pi * 2,
      width = _lerp(r, 5, 9),
      height = _lerp(r, 3, 12),
      hue = r.nextInt(7),
      // Um atraso curtinho espalha o estouro em vez de cuspir 55 papéis no
      // mesmo frame, que lê como um bloco só.
      delay = _lerp(r, 0, 0.16);

  /// Um papel de punhado: sai de um ponto pra todo lado, mais devagar e
  /// menor — e sem atraso, porque um punhado é um estouro só.
  ///
  /// Redondo e não em leque pra cima: o botão que pede um punhado fica no
  /// topo de um painel, e um leque ali joga metade do confete fora da janela
  /// antes de qualquer um ver. Redondo, a gravidade cuida do resto.
  _Bit.puff(Random r, {required this.origin})
    : angle = r.nextDouble() * 2 * pi,
      speed = _lerp(r, 0.6, 1.5),
      spin = _lerp(r, -11, 11),
      flutter = _lerp(r, 6, 13),
      phase = r.nextDouble() * pi * 2,
      width = _lerp(r, 4, 7),
      height = _lerp(r, 3, 8),
      hue = r.nextInt(7),
      delay = 0;

  /// Onde ele nasce, em fração da folha.
  final Offset origin;

  /// Radianos, medidos da horizontal pra cima. Velocidade em alturas de tela
  /// por segundo.
  final double angle;
  final double speed;

  /// Voltas por segundo, e o bater de papel — a largura oscila em [flutter]
  /// hertz, que é o que faz um retângulo parecer uma folha virando.
  final double spin;
  final double flutter;
  final double phase;

  final double width;
  final double height;

  /// Índice na paleta em vigor: a festa é da cor do tema, não de uma cor
  /// nossa que brigaria com metade dos treze.
  final int hue;
  final double delay;

  static double _lerp(Random r, double a, double b) => a + r.nextDouble() * (b - a);
}

class _Burst extends StatefulWidget {
  const _Burst.cannons({required this.onDone})
    : at = null,
      count = 55,
      life = const Duration(milliseconds: 2600),
      fadeFrom = 0.72;

  /// [at] nunca é nulo aqui — o campo é que precisa ser, pros canhões.
  const _Burst.puff({required this.at, required this.onDone})
    : count = 40,
      life = const Duration(milliseconds: 1400),
      // Vida curta pede sumiço mais cedo: o punhado passa parte do tempo
      // dele indo embora, o que é o que faz não virar um segundo evento.
      fadeFrom = 0.62;

  /// Origem fixa, em fração da folha. Nulo são os dois cantos de baixo.
  final Offset? at;

  /// Papéis por canhão, ou o punhado inteiro.
  final int count;

  final Duration life;
  final double fadeFrom;
  final VoidCallback onDone;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<_Bit> _bits;

  @override
  void initState() {
    super.initState();
    final r = Random();
    final at = widget.at;
    _bits = at == null
        ? [
            for (var i = 0; i < widget.count; i++) _Bit.cannon(r, fromLeft: true),
            for (var i = 0; i < widget.count; i++) _Bit.cannon(r, fromLeft: false),
          ]
        : [for (var i = 0; i < widget.count; i++) _Bit.puff(r, origin: at)];
    _c = AnimationController(vsync: this, duration: widget.life)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          painter: _ConfettiPainter(
            bits: _bits,
            seconds: _c.value * widget.life.inMilliseconds / 1000,
            progress: _c.value,
            fadeFrom: widget.fadeFrom,
            palette: Mx.palette,
          ),
          size: Size.infinite,
        ),
      ),
    ),
  );
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({
    required this.bits,
    required this.seconds,
    required this.progress,
    required this.fadeFrom,
    required this.palette,
  });

  final List<_Bit> bits;
  final double seconds;
  final double progress;

  /// A última fatia do tempo é só o sumiço. Confete que desaparece de uma vez
  /// no meio da tela lê como bug; sumindo aos poucos, lê como acabou.
  final double fadeFrom;

  final MxPalette palette;

  /// Gravidade e arrasto, em alturas de tela. O arrasto é o que dá velocidade
  /// terminal ao papel: sem ele o confete cai como pedra, que é exatamente o
  /// que confete não faz.
  static const _g = 1.5;
  static const _drag = 1.15;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.height;
    final colors = [
      palette.accent,
      palette.green,
      palette.yellow,
      palette.purple,
      palette.red,
      palette.ansi.cyan,
      palette.ansi.blue,
    ];
    final fade = progress <= fadeFrom ? 1.0 : 1 - (progress - fadeFrom) / (1 - fadeFrom);

    final paint = Paint()..style = PaintingStyle.fill;
    for (final b in bits) {
      final t = seconds - b.delay;
      if (t <= 0) continue;

      // Solução fechada do movimento com arrasto linear, para não carregar
      // estado de simulação entre frames: um `t` qualquer dá a mesma posição,
      // e um frame perdido não desalinha nada.
      // v(t) = vt + (v0 - vt)e^-kt, integrado: o termo linear é a queda em
      // velocidade terminal, e a exponencial é o empurrão do canhão gastando.
      final decay = (1 - exp(-_drag * t)) / _drag;
      final terminal = _g * unit / _drag;
      final vx = cos(b.angle) * b.speed * unit;
      final vy = -sin(b.angle) * b.speed * unit;
      final x = b.origin.dx * size.width + vx * decay;
      final y = b.origin.dy * size.height + (vy - terminal) * decay + terminal * t;
      if (y > size.height + 40) continue;

      paint.color = colors[b.hue % colors.length].withValues(alpha: fade);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(b.spin * t);
      // O papel visto de lado: a largura passa por zero e volta.
      canvas.scale(cos(b.phase + b.flutter * t), 1);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: b.width, height: b.height),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.seconds != seconds;
}
