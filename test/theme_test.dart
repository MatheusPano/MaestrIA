import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/sidebar.dart';

/// The sidebar with nothing in it — its empty state is the one piece of the UI
/// that used to be a `const` widget, which is exactly what a theme change has
/// to be able to reach.
Future<void> pumpSidebar(WidgetTester tester) {
  final store = AppStore();
  // The same wiring main.dart uses: the palette listened to above the
  // MaterialApp, since it feeds `theme:` as well as the panels.
  return tester.pumpWidget(
    ValueListenableBuilder<MxPalette>(
      valueListenable: Mx.current,
      builder: (context, _, _) => MaterialApp(
        theme: Mx.theme(),
        // Wider than the real sidebar for the same reason the worktree tests
        // are: one square em per character in the test font makes the tray's
        // button row much wider than it ever is on screen.
        home: Scaffold(
          body: SizedBox(width: 700, height: 700, child: Sidebar(store: store)),
        ),
      ),
    ),
  );
}

Color _emptyStateColor(WidgetTester tester) {
  final text = tester.widget<Text>(find.textContaining('nenhuma pasta ainda'));
  return text.style!.color!;
}

void main() {
  tearDown(() => Mx.apply(MxThemes.maestria));

  group('palettes', () {
    test('every theme has its own id, and the picker order holds them all', () {
      final ids = MxThemes.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(MxThemes.all.where((p) => !p.dark).length, greaterThan(0), reason: 'há tema claro');
    });

    test('no two palettes are the same window', () {
      // The set exists to offer a choice, so two themes that differ only by a
      // few points of lightness are one theme wearing two names. Backgrounds
      // being distinct is the cheap half of that; the accents being distinct
      // is what stops the picker from reading as one palette eleven times.
      final windows = MxThemes.all.map((p) => (p.canvas, p.bg, p.bgSidebar)).toList();
      expect(windows.toSet().length, windows.length);

      // Enough light themes to be a choice of its own, not a token one.
      expect(MxThemes.all.where((p) => !p.dark).length, greaterThanOrEqualTo(3));
    });

    test('the darks are not all one window at thirteen brightnesses', () {
      // Hue spread is the cheaper half of the job: the background is most of
      // what you see, so a set whose darks all sit within a few points of each
      // other is one dark theme wearing a dozen accents. Zenburn is the top of
      // that climb and Ayu is the floor, and the gap between them is the point.
      final darks = MxThemes.all.where((p) => p.dark).map((p) => p.bg.computeLuminance());
      expect(darks.reduce(max) / darks.reduce(min), greaterThan(5));
    });

    test('at least one dark window is a grey and not a very dark blue', () {
      // Every tinted grey reads as blue once a true one is next to it, which
      // is exactly what the set was missing: thirteen darks, all of them lit.
      final neutral = MxThemes.all.where((p) => p.dark && p.bg.r == p.bg.g && p.bg.g == p.bg.b);
      expect(neutral, isNotEmpty);
    });

    test('an id nobody knows falls back instead of failing to start', () {
      expect(MxThemes.byId('nord').id, 'nord');
      expect(MxThemes.byId('theme-from-the-future').id, MxThemes.maestria.id);
      expect(MxThemes.byId(null).id, MxThemes.maestria.id);
    });

    test('the pty inherits the pane it sits in', () {
      expect(MxThemes.nord.terminal.background, MxThemes.nord.bg);
      expect(MxThemes.catppuccinLatte.terminal.foreground, MxThemes.catppuccinLatte.fg);
    });
  });

  group('switching', () {
    testWidgets('repaints widgets that were const before', (tester) async {
      await pumpSidebar(tester);
      expect(_emptyStateColor(tester), MxThemes.maestria.fgFaint);

      Mx.apply(MxThemes.nord);
      await tester.pump();

      expect(_emptyStateColor(tester), MxThemes.nord.fgFaint);
    });

    testWidgets('a light theme takes the Material base with it', (tester) async {
      await pumpSidebar(tester);
      Mx.apply(MxThemes.catppuccinLatte);
      // MaterialApp cross-fades its ThemeData, so the new brightness is only
      // in place once that animation is done.
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, MxThemes.catppuccinLatte.canvas);
    });
  });
}
