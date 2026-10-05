import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
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
  final text = tester.widget<Text>(find.textContaining('Nenhuma pasta ainda'));
  return text.style!.color!;
}

/// A distância entre duas cores como o olho a mede (CIELAB, ΔE76). Lado a lado,
/// abaixo de uns 10 duas bolinhas de menu já se confundem.
double _deltaE(Color a, Color b) {
  List<double> lab(Color c) {
    double lin(double v) => v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = lin(c.r), g = lin(c.g), b = lin(c.b);
    final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    double f(double t) => t > 0.008856 ? pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
  }

  final p = lab(a), q = lab(b);
  return sqrt(pow(p[0] - q[0], 2) + pow(p[1] - q[1], 2) + pow(p[2] - q[2], 2));
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

    test('an id from a retired theme lands on its nearest look-alike', () {
      // A config file from before the cut should come up in the window it
      // had, not in the default — Tokyo Night was the default's twin and the
      // renamed grey is itself.
      expect(MxThemes.byId('tokyo-night'), MxThemes.maestria);
      expect(MxThemes.byId('chatgpt-dark'), MxThemes.graphite);
    });

    test('catppuccin comes from its plugin, retired aliases included', () {
      // Without the plugin, Mocha is an id nobody knows — and so is Frappé,
      // which points at it.
      expect(MxThemes.byId('catppuccin-mocha'), MxThemes.maestria);
      expect(MxThemes.byId('catppuccin-frappe'), MxThemes.maestria);
      expect(MxThemes.isBuiltIn('catppuccin-mocha'), isFalse);

      final mocha = MxPalette.fromJson({
        ...jsonDecode(File('examples/plugins/tema-e-atalhos/themes/aurora.json').readAsStringSync())
            as Map<String, dynamic>,
        'id': 'catppuccin-mocha',
      });
      MxThemes.extra.add(mocha);
      addTearDown(MxThemes.extra.clear);
      expect(MxThemes.byId('catppuccin-mocha'), mocha);
      expect(MxThemes.byId('catppuccin-frappe'), mocha);
      expect(MxThemes.byId('rose-pine'), mocha);
    });

    test('no theme uses the same colour for a search hit and the current one', () {
      // The pty paints every hit in `yellow` and the current one in `accent`;
      // a palette whose accent is its yellow would make them one colour.
      for (final p in MxThemes.all) {
        expect(p.accent, isNot(p.yellow), reason: p.id);
        expect(p.accent, isNot(p.purple), reason: p.id);
      }
    });

    test('the pty inherits the pane it sits in', () {
      expect(MxThemes.nord.terminal.background, MxThemes.nord.bg);
      expect(MxThemes.githubLight.terminal.foreground, MxThemes.githubLight.fg);
    });
  });

  // A cor que alguém escolhe pra um painel, uma pasta ou um projeto. Ver [MxTint].
  group('as cores de etiqueta', () {
    test('são treze, na ordem do círculo de cores, com o cinza por último', () {
      expect(MxTint.values.map((t) => t.label), [
        'Vermelho',
        'Laranja',
        'Amarelo',
        'Lima',
        'Verde',
        'Verde-água',
        'Ciano',
        'Azul-petróleo',
        'Violeta',
        'Magenta',
        'Rosa',
        'Marrom',
        'Cinza',
      ]);
    });

    test('nenhuma se confunde com outra, em nenhum tema', () {
      for (final palette in MxThemes.all) {
        Mx.apply(palette);
        for (final a in MxTint.values) {
          for (final b in MxTint.values.where((b) => b.index > a.index)) {
            expect(
              _deltaE(a.color, b.color),
              greaterThanOrEqualTo(10),
              reason: '${a.label} e ${b.label} no ${palette.id}',
            );
          }
        }
      }
    });

    test('nenhuma some no fundo do painel, em nenhum tema', () {
      for (final palette in MxThemes.all) {
        Mx.apply(palette);
        for (final tint in MxTint.values) {
          expect(
            _deltaE(tint.color, palette.bg),
            greaterThanOrEqualTo(15),
            reason: '${tint.label} no ${palette.id}',
          );
        }
      }
    });

    test('seguem o tema: o mesmo nome dá outra cor em outra paleta', () {
      Mx.apply(MxThemes.nord);
      final nord = MxTint.cyan.color;
      Mx.apply(MxThemes.githubLight);
      expect(MxTint.cyan.color, isNot(nord));
      Mx.apply(MxThemes.nord);
      expect(MxTint.cyan.color, nord);
    });

    test('a escolhida volta do config com o mesmo nome', () {
      for (final tint in MxTint.values) {
        final folder = Folder(root: '/repo', name: 'repo')..tint = tint;
        expect(Folder.fromJson(folder.toJson()).tint, tint);
      }
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
      Mx.apply(MxThemes.githubLight);
      // MaterialApp cross-fades its ThemeData, so the new brightness is only
      // in place once that animation is done.
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, MxThemes.githubLight.canvas);
    });
  });
}
