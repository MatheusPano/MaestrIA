import 'package:flutter/material.dart';

import '../theme.dart';

/// A floating panel: the one shape every region of the window is made of.
///
/// The window paints [Mx.canvas] and each region — sidebar, terminal, status
/// bar — sits on it as its own card with a gutter around it, the way VS Code
/// detaches its panels. The seam between two regions is a gap, so nothing
/// needs a 1px divider to be told apart.
class MxPanel extends StatelessWidget {
  const MxPanel({
    super.key,
    required this.child,
    this.color,
    this.focused = false,
    this.showFocus = false,
    this.radius = Mx.radius,
  });

  final Widget child;

  /// Defaults to [Mx.bg] — resolved in [build], not in the constructor, so the
  /// panel follows a theme change like everything else.
  final Color? color;

  /// The accent outline, for telling two open panes apart. Only drawn when
  /// [showFocus] asks for it, so a lone pane is not permanently ringed.
  final bool focused;
  final bool showFocus;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    final ring = showFocus && focused;
    return Container(
      // The child fills the card — a header strip has to stop at the corner.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? Mx.bg,
        borderRadius: shape,
        boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 12, offset: const Offset(0, 3))],
      ),
      // In front of the child, not behind it: an opaque header would otherwise
      // paint over the inner half of a background border.
      foregroundDecoration: BoxDecoration(
        borderRadius: shape,
        border: Border.all(
          color: ring ? Mx.accent.withValues(alpha: 0.65) : Mx.border,
          width: ring ? 1.4 : 1,
        ),
      ),
      child: child,
    );
  }
}
