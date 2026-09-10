import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'icons.dart';

/// Anthropic's burst, drawn instead of typed.
///
/// The sidebar used to render the character `✳`, and macOS resolves that to
/// Apple Color Emoji: a green tile, whatever colour we asked for. A drawing
/// has no such opinion — and it is the mark people already read as "claude".
///
/// O desenho é a marca de verdade, vinda de `assets/icons/claude.svg`, e não
/// mais dez lâminas aproximadas na mão: as proporções são as dela, e não as
/// que couberam num [CustomPainter]. Ver [MxIcon].
class ClaudeMark extends StatelessWidget {
  const ClaudeMark({super.key, this.size = 14, this.color = Mx.claude});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => MxIcon(MxIcons.claude, size: size, color: color);
}

/// The mark with a small state badge notched into its corner, the way Warp
/// stamps a tick on an agent that has finished.
///
/// The badge is the honest part: the mark says *whose* session this is, the
/// badge says whether it is still going. A spinner only while it actually
/// works, a caret while it waits at its prompt, a tick when it finishes a
/// turn, the alert colour when it wants you -- and, when it wants you, which
/// kind of wanting: a lock for something to authorise, a question mark for
/// something to answer.
class ClaudeAvatar extends StatelessWidget {
  const ClaudeAvatar({super.key, required this.status, this.size = 20, this.dim = false});

  final ClaudeStatus status;
  final double size;

  /// A session that is no longer the point: muted, but still on screen.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final badge = (size * 0.56).clamp(9.0, 14.0);
    return Opacity(
      opacity: dim ? 0.72 : 1,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ClaudeMark(size: size)),
            Positioned(
              right: -badge * 0.18,
              bottom: -badge * 0.18,
              child: _StatusBadge(status: status, size: badge),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.size});
  final ClaudeStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case ClaudeStatus.working:
      case ClaudeStatus.tool:
        return _Spinner(size: size, color: status.color);
      case ClaudeStatus.starting:
        return _Pulse(size: size, color: status.color);
      // A caret, because that is what the session is showing you: its prompt.
      // It has run nothing, so a tick would be claiming work that never
      // happened, and the spinner it used to get was claiming work in flight.
      case ClaudeStatus.ready:
        return _Glyph(
          icon: Icons.chevron_right_rounded,
          color: Mx.green,
          size: size,
          scale: 0.94,
        );
      case ClaudeStatus.idle:
        return _Glyph(icon: Icons.check_rounded, color: Mx.green, size: size);
      case ClaudeStatus.waitingInput:
        return _Glyph(icon: Icons.priority_high_rounded, color: Mx.yellow, size: size);
      // A question mark, and never the lock: a lock says something wants to
      // be let through, and nothing is being let through here -- the session
      // wrote you a question and is holding the turn for the answer.
      case ClaudeStatus.waitingAnswer:
        return _Glyph(
          icon: Icons.question_mark_rounded,
          color: Mx.yellow,
          size: size,
          scale: 0.62,
        );
      case ClaudeStatus.waitingPermission:
        return _Glyph(icon: Icons.lock_rounded, color: Mx.red, size: size);
      case ClaudeStatus.ended:
        return _Glyph(icon: Icons.close_rounded, color: Mx.fgFaint, size: size);
      case ClaudeStatus.unknown:
        return const SizedBox.shrink();
    }
  }
}

/// A dark disc so the glyph is legible over the orange, ringed in the state's
/// colour so the state is readable before the glyph even resolves.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.icon,
    required this.color,
    required this.size,
    this.scale = 0.72,
  });
  final IconData icon;
  final Color color;
  final double size;

  /// How much of the disc the glyph fills. A tick reads at 0.72; a caret is
  /// mostly whitespace inside its own box, and needs the room; a question
  /// mark is the opposite -- tall and inked to its own edges, so it has to be
  /// held back or it touches the ring.
  final double scale;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Mx.canvas,
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1.1),
    ),
    child: Center(
      child: Icon(icon, size: size * scale, color: color),
    ),
  );
}

/// The badge while the session is coming up: the ring, and a core that
/// breathes inside it.
///
/// Deliberately not the spinner. A turning arc is a claim that something is
/// being done, and a session two seconds into its launch is not doing
/// anything for you -- it is opening. Same ring as [_Spinner] so the two read
/// as one family, and it lasts about as long as the launch does.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        painter: _PulsePainter(Curves.easeInOut.transform(_c.value), widget.color),
      ),
    ),
  );
}

class _PulsePainter extends CustomPainter {
  const _PulsePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2);
    canvas
      ..drawCircle(c, r, Paint()..color = Mx.canvas)
      ..drawCircle(
        c,
        r - 0.7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = color.withValues(alpha: 0.20 + 0.30 * t),
      )
      ..drawCircle(
        c,
        r * (0.26 + 0.16 * t),
        Paint()..color = color.withValues(alpha: 0.55 + 0.45 * t),
      );
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t || old.color != color;
}

/// The badge while it is still going: the ring, minus a gap, turning.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(painter: _SpinnerPainter(_c.value, widget.color)),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c, r, Paint()..color = Mx.canvas);
    final rect = Rect.fromCircle(center: c, radius: r - 0.7);
    canvas
      ..drawArc(
        rect,
        0,
        math.pi * 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = color.withValues(alpha: 0.22),
      )
      ..drawArc(
        rect,
        t * math.pi * 2,
        math.pi * 1.05,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.t != t || old.color != color;
}
