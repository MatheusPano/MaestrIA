import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// The sixteen colours a pty speaks in.
///
/// The bright half is optional: several palettes (the Catppuccin family, most
/// notably) publish one set and let bright fall back onto it, and spelling
/// sixteen literals out to say eight of them twice helps nobody.
/// `#RRGGBB` ou `#AARRGGBB`, como um arquivo de tema escreve uma cor. Null no
/// que não for isso -- quem chama é quem sabe dizer de qual campo se tratava.
Color? parseHexColor(String raw) {
  final hex = raw.trim().replaceFirst('#', '');
  if (hex.length != 6 && hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(hex.length == 6 ? 0xFF000000 | value : value);
}

@immutable
class MxAnsi {
  const MxAnsi({
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    Color? brightBlack,
    Color? brightRed,
    Color? brightGreen,
    Color? brightYellow,
    Color? brightBlue,
    Color? brightMagenta,
    Color? brightCyan,
    Color? brightWhite,
  }) : _brightBlack = brightBlack,
       _brightRed = brightRed,
       _brightGreen = brightGreen,
       _brightYellow = brightYellow,
       _brightBlue = brightBlue,
       _brightMagenta = brightMagenta,
       _brightCyan = brightCyan,
       _brightWhite = brightWhite;

  final Color black, red, green, yellow, blue, magenta, cyan, white;
  final Color? _brightBlack,
      _brightRed,
      _brightGreen,
      _brightYellow,
      _brightBlue,
      _brightMagenta,
      _brightCyan,
      _brightWhite;

  Color get brightBlack => _brightBlack ?? black;
  Color get brightRed => _brightRed ?? red;
  Color get brightGreen => _brightGreen ?? green;
  Color get brightYellow => _brightYellow ?? yellow;
  Color get brightBlue => _brightBlue ?? blue;
  Color get brightMagenta => _brightMagenta ?? magenta;
  Color get brightCyan => _brightCyan ?? cyan;
  Color get brightWhite => _brightWhite ?? white;
}

/// One theme: every colour the app draws with, named by the role it plays
/// rather than by what it looks like, so a palette can be swapped underneath
/// the whole UI without a single widget knowing.
@immutable
class MxPalette {
  const MxPalette({
    required this.id,
    required this.label,
    required this.dark,
    required this.canvas,
    required this.bg,
    required this.bgSidebar,
    required this.bgHover,
    required this.bgActive,
    required this.border,
    required this.fg,
    required this.fgDim,
    required this.fgFaint,
    required this.accent,
    required this.green,
    required this.yellow,
    required this.red,
    required this.purple,
    required this.ansi,
  });

  /// Stable across renames — this is what lands in the config file.
  final String id;

  /// What the picker calls it.
  final String label;

  /// Which Material base to build on, and how heavy the panel shadow gets.
  final bool dark;

  /// The window itself, behind everything. Every panel floats on top of it, so
  /// it is a step away from any surface — that step is what makes the gutters
  /// read as gaps instead of lines. Darker on a dark theme, greyer on a light
  /// one; either way, the cards have to lift off it.
  final Color canvas;
  final Color bg;
  final Color bgSidebar;
  final Color bgHover;
  final Color bgActive;
  final Color border;
  final Color fg;
  final Color fgDim;
  final Color fgFaint;
  final Color accent;
  final Color green;
  final Color yellow;
  final Color red;
  final Color purple;

  final MxAnsi ansi;

  /// Uma paleta escrita em json — é como um plugin entrega um tema.
  ///
  /// As cores vão como `#RRGGBB` ou `#AARRGGBB`. Nenhuma é opcional fora dos
  /// oito `bright*` do `ansi`, que caem na cor normal como nas embutidas: um
  /// tema pela metade pintaria metade da janela com a paleta anterior. O que
  /// faltar ou não for cor vira um [FormatException] que diz qual campo foi,
  /// porque quem lê o erro é quem escreveu o arquivo.
  factory MxPalette.fromJson(Map<String, dynamic> j) {
    Color color(Map<String, dynamic> from, String key, {String prefix = ''}) {
      final raw = from[key];
      final parsed = raw is String ? parseHexColor(raw) : null;
      if (parsed == null) throw FormatException('"$prefix$key" precisa ser uma cor #RRGGBB');
      return parsed;
    }

    Color? maybe(Map<String, dynamic> from, String key) =>
        from[key] is String ? parseHexColor(from[key] as String) : null;

    final id = j['id'];
    final label = j['label'];
    if (id is! String || id.isEmpty) throw const FormatException('"id" é obrigatório');
    if (label is! String || label.isEmpty) throw const FormatException('"label" é obrigatório');
    final ansi = j['ansi'];
    if (ansi is! Map<String, dynamic>) throw const FormatException('"ansi" é obrigatório');
    const a = 'ansi.';
    return MxPalette(
      id: id,
      label: label,
      dark: j['dark'] != false,
      canvas: color(j, 'canvas'),
      bg: color(j, 'bg'),
      bgSidebar: color(j, 'bgSidebar'),
      bgHover: color(j, 'bgHover'),
      bgActive: color(j, 'bgActive'),
      border: color(j, 'border'),
      fg: color(j, 'fg'),
      fgDim: color(j, 'fgDim'),
      fgFaint: color(j, 'fgFaint'),
      accent: color(j, 'accent'),
      green: color(j, 'green'),
      yellow: color(j, 'yellow'),
      red: color(j, 'red'),
      purple: color(j, 'purple'),
      ansi: MxAnsi(
        black: color(ansi, 'black', prefix: a),
        red: color(ansi, 'red', prefix: a),
        green: color(ansi, 'green', prefix: a),
        yellow: color(ansi, 'yellow', prefix: a),
        blue: color(ansi, 'blue', prefix: a),
        magenta: color(ansi, 'magenta', prefix: a),
        cyan: color(ansi, 'cyan', prefix: a),
        white: color(ansi, 'white', prefix: a),
        brightBlack: maybe(ansi, 'brightBlack'),
        brightRed: maybe(ansi, 'brightRed'),
        brightGreen: maybe(ansi, 'brightGreen'),
        brightYellow: maybe(ansi, 'brightYellow'),
        brightBlue: maybe(ansi, 'brightBlue'),
        brightMagenta: maybe(ansi, 'brightMagenta'),
        brightCyan: maybe(ansi, 'brightCyan'),
        brightWhite: maybe(ansi, 'brightWhite'),
      ),
    );
  }

  /// A light theme lit from the same angle would look bruised: the drop shadow
  /// under a panel has to be a hint there, not the slab that works on black.
  Color get shadow => dark ? const Color(0x59000000) : const Color(0x14101828);

  /// The pty's own colours. Its background is the pane it sits in, so the
  /// terminal reads as the panel rather than as a rectangle dropped into one.
  TerminalTheme get terminal => TerminalTheme(
    cursor: accent,
    selection: accent.withValues(alpha: 0.3),
    foreground: fg,
    background: bg,
    black: ansi.black,
    red: ansi.red,
    green: ansi.green,
    yellow: ansi.yellow,
    blue: ansi.blue,
    magenta: ansi.magenta,
    cyan: ansi.cyan,
    white: ansi.white,
    brightBlack: ansi.brightBlack,
    brightRed: ansi.brightRed,
    brightGreen: ansi.brightGreen,
    brightYellow: ansi.brightYellow,
    brightBlue: ansi.brightBlue,
    brightMagenta: ansi.brightMagenta,
    brightCyan: ansi.brightCyan,
    brightWhite: ansi.brightWhite,
    searchHitBackground: yellow,
    searchHitBackgroundCurrent: accent,
    searchHitForeground: canvas,
  );
}

/// The built-in themes.
///
/// Each one is the published palette of its source, mapped onto the roles
/// above — not re-tuned by eye. Nord is Nord; the reason to pick it is that it
/// looks like Nord everywhere else you use it.
///
/// What the set is chosen for is spread. A picker of eleven near-blacks all lit
/// blue offers eleven ways to look the same, so each theme here holds a corner
/// nothing else does: ink, sand-on-ink, greige, forest, brown, teal,
/// warm neon, steel, neon purple, hot pink, cobalt, navy, black — then three lights
/// that are as far apart, paper white through cream. Two palettes that differ
/// only in how far up the greyscale they sit are one palette; the second one
/// goes. That is why Tokyo Night is not here (it is [maestria] under another
/// name), and why Rosé Pine's dark half gave way to [dracula].
///
/// Catppuccin is not here either, though for another reason: it moved out to
/// the `maestria.catppuccin` plugin (in `maestria-plugins`), under the same
/// ids it had here, so a config file that picked it opens in it again as soon
/// as the plugin is installed.
///
/// Hue is only half of that spread, though, and the cheaper half. A dozen
/// darks whose windows all sat between L\* 4 and L\* 22 read as one dark theme
/// wearing a dozen accents, because the background is most of what you see.
/// So the set also climbs: [highContrast] is the floor at true black,
/// [claudeDark], [slate] and [graphite] sit on the mid grey desktop apps use
/// (warm, cool and neutral, in that order), and
/// [zenburn] goes further up than anything else here. [graphite] holds the
/// other gap those found — it is the only window with no hue in it at all.
class MxThemes {
  static const maestria = MxPalette(
    id: 'maestria',
    label: 'Dark',
    dark: true,
    canvas: Color(0xFF0D0F13),
    bg: Color(0xFF16181D),
    bgSidebar: Color(0xFF1B1E24),
    bgHover: Color(0xFF23272F),
    bgActive: Color(0xFF2C313A),
    border: Color(0xFF2A2F38),
    fg: Color(0xFFE6E8EB),
    fgDim: Color(0xFF8B929E),
    fgFaint: Color(0xFF5C636F),
    accent: Color(0xFF7AA2F7),
    green: Color(0xFF6ECF8F),
    yellow: Color(0xFFE0AF68),
    red: Color(0xFFF07178),
    purple: Color(0xFFBB9AF7),
    ansi: MxAnsi(
      black: Color(0xFF16181D),
      red: Color(0xFFF07178),
      green: Color(0xFF6ECF8F),
      yellow: Color(0xFFE0AF68),
      blue: Color(0xFF7AA2F7),
      magenta: Color(0xFFBB9AF7),
      cyan: Color(0xFF7DCFFF),
      white: Color(0xFFE6E8EB),
      brightBlack: Color(0xFF5C636F),
      brightRed: Color(0xFFFF8B92),
      brightGreen: Color(0xFF86E0A4),
      brightYellow: Color(0xFFF0C589),
      brightBlue: Color(0xFF94B4FF),
      brightMagenta: Color(0xFFCDB2FF),
      brightCyan: Color(0xFF96DBFF),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  static const nord = MxPalette(
    id: 'nord',
    label: 'Nord',
    dark: true,
    canvas: Color(0xFF242933),
    bg: Color(0xFF2E3440),
    bgSidebar: Color(0xFF2B303B),
    bgHover: Color(0xFF3B4252),
    bgActive: Color(0xFF434C5E),
    border: Color(0xFF3B4252),
    fg: Color(0xFFECEFF4),
    fgDim: Color(0xFFB7C0CE),
    fgFaint: Color(0xFF7B8797),
    accent: Color(0xFF88C0D0),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    red: Color(0xFFBF616A),
    purple: Color(0xFFB48EAD),
    ansi: MxAnsi(
      black: Color(0xFF3B4252),
      red: Color(0xFFBF616A),
      green: Color(0xFFA3BE8C),
      yellow: Color(0xFFEBCB8B),
      blue: Color(0xFF81A1C1),
      magenta: Color(0xFFB48EAD),
      cyan: Color(0xFF88C0D0),
      white: Color(0xFFE5E9F0),
      brightBlack: Color(0xFF4C566A),
      brightCyan: Color(0xFF8FBCBB),
      brightWhite: Color(0xFFECEFF4),
    ),
  );

  static const gruvbox = MxPalette(
    id: 'gruvbox-dark',
    label: 'Gruvbox Dark',
    dark: true,
    canvas: Color(0xFF1D2021),
    bg: Color(0xFF282828),
    bgSidebar: Color(0xFF32302F),
    bgHover: Color(0xFF3C3836),
    bgActive: Color(0xFF504945),
    border: Color(0xFF3C3836),
    fg: Color(0xFFEBDBB2),
    fgDim: Color(0xFFBDAE93),
    fgFaint: Color(0xFF928374),
    accent: Color(0xFF83A598),
    green: Color(0xFFB8BB26),
    yellow: Color(0xFFFABD2F),
    red: Color(0xFFFB4934),
    purple: Color(0xFFD3869B),
    ansi: MxAnsi(
      black: Color(0xFF282828),
      red: Color(0xFFCC241D),
      green: Color(0xFF98971A),
      yellow: Color(0xFFD79921),
      blue: Color(0xFF458588),
      magenta: Color(0xFFB16286),
      cyan: Color(0xFF689D6A),
      white: Color(0xFFA89984),
      brightBlack: Color(0xFF928374),
      brightRed: Color(0xFFFB4934),
      brightGreen: Color(0xFFB8BB26),
      brightYellow: Color(0xFFFABD2F),
      brightBlue: Color(0xFF83A598),
      brightMagenta: Color(0xFFD3869B),
      brightCyan: Color(0xFF8EC07C),
      brightWhite: Color(0xFFEBDBB2),
    ),
  );

  static const dracula = MxPalette(
    id: 'dracula',
    label: 'Dracula',
    dark: true,
    canvas: Color(0xFF1B1C24),
    bg: Color(0xFF282A36),
    bgSidebar: Color(0xFF21222C),
    bgHover: Color(0xFF343746),
    bgActive: Color(0xFF44475A),
    border: Color(0xFF343746),
    fg: Color(0xFFF8F8F2),
    fgDim: Color(0xFFBFC7D5),
    fgFaint: Color(0xFF6272A4),
    accent: Color(0xFFBD93F9),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    red: Color(0xFFFF5555),
    purple: Color(0xFFFF79C6),
    ansi: MxAnsi(
      black: Color(0xFF21222C),
      red: Color(0xFFFF5555),
      green: Color(0xFF50FA7B),
      yellow: Color(0xFFF1FA8C),
      blue: Color(0xFFBD93F9),
      magenta: Color(0xFFFF79C6),
      cyan: Color(0xFF8BE9FD),
      white: Color(0xFFF8F8F2),
      brightBlack: Color(0xFF6272A4),
      brightRed: Color(0xFFFF6E6E),
      brightGreen: Color(0xFF69FF94),
      brightYellow: Color(0xFFFFFFA5),
      brightBlue: Color(0xFFD6ACFF),
      brightMagenta: Color(0xFFFF92DF),
      brightCyan: Color(0xFFA4FFFF),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  static const rosePineDawn = MxPalette(
    id: 'rose-pine-dawn',
    label: 'Rosé Pine Dawn',
    dark: false,
    canvas: Color(0xFFEBE3DB),
    bg: Color(0xFFFFFAF3),
    bgSidebar: Color(0xFFFAF4ED),
    bgHover: Color(0xFFF2E9E1),
    bgActive: Color(0xFFDFDAD9),
    border: Color(0xFFE5DED6),
    fg: Color(0xFF575279),
    fgDim: Color(0xFF797593),
    fgFaint: Color(0xFF9893A5),
    accent: Color(0xFF286983),
    green: Color(0xFF56949F),
    yellow: Color(0xFFEA9D34),
    red: Color(0xFFB4637A),
    purple: Color(0xFF907AA9),
    ansi: MxAnsi(
      black: Color(0xFFF2E9E1),
      red: Color(0xFFB4637A),
      green: Color(0xFF286983),
      yellow: Color(0xFFEA9D34),
      blue: Color(0xFF56949F),
      magenta: Color(0xFF907AA9),
      cyan: Color(0xFFD7827E),
      white: Color(0xFF575279),
      brightBlack: Color(0xFF9893A5),
      brightWhite: Color(0xFF575279),
    ),
  );

  /// Ayu Dark. The one near-black in the set that is lit warm: a sand
  /// foreground and an amber accent over ink, where every other dark theme
  /// here goes blue. Its own terminal mapping sends `blue` to a real blue,
  /// so directories stay readable.
  static const ayuDark = MxPalette(
    id: 'ayu-dark',
    label: 'Ayu Dark',
    dark: true,
    canvas: Color(0xFF07090F),
    bg: Color(0xFF0D1017),
    bgSidebar: Color(0xFF0B0E14),
    bgHover: Color(0xFF191E29),
    bgActive: Color(0xFF242A36),
    border: Color(0xFF1C222C),
    fg: Color(0xFFBFBDB6),
    fgDim: Color(0xFF8A8986),
    fgFaint: Color(0xFF565B66),
    accent: Color(0xFFE6B450),
    green: Color(0xFFAAD94C),
    yellow: Color(0xFFFFB454),
    red: Color(0xFFD95757),
    purple: Color(0xFFD2A6FF),
    ansi: MxAnsi(
      black: Color(0xFF191E29),
      red: Color(0xFFEA6C73),
      green: Color(0xFF91B362),
      yellow: Color(0xFFF9AF4F),
      blue: Color(0xFF53BDFA),
      magenta: Color(0xFFD2A6FF),
      cyan: Color(0xFF90E1C6),
      white: Color(0xFFC7C7C7),
      brightBlack: Color(0xFF686868),
      brightRed: Color(0xFFF07178),
      brightGreen: Color(0xFFC2D94C),
      brightYellow: Color(0xFFFFB454),
      brightBlue: Color(0xFF59C2FF),
      brightMagenta: Color(0xFFFFEE99),
      brightCyan: Color(0xFF95E6CB),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// Solarized Dark — the deep teal end of the set, and the only theme whose
  /// background is a colour rather than a grey.
  ///
  /// The bright half is the patched mapping every terminal ships, not
  /// Solarized's own: the original spends six of its bright slots on greys,
  /// which reads as a broken palette in a pane running a CLI that colours its
  /// output.
  static const solarizedDark = MxPalette(
    id: 'solarized-dark',
    label: 'Solarized Dark',
    dark: true,
    canvas: Color(0xFF00212B),
    bg: Color(0xFF002B36),
    bgSidebar: Color(0xFF00252F),
    bgHover: Color(0xFF073642),
    bgActive: Color(0xFF0E4B5A),
    border: Color(0xFF0A3A47),
    fg: Color(0xFF93A1A1),
    fgDim: Color(0xFF839496),
    fgFaint: Color(0xFF586E75),
    accent: Color(0xFF268BD2),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    red: Color(0xFFDC322F),
    purple: Color(0xFF6C71C4),
    ansi: MxAnsi(
      black: Color(0xFF073642),
      red: Color(0xFFDC322F),
      green: Color(0xFF859900),
      yellow: Color(0xFFB58900),
      blue: Color(0xFF268BD2),
      magenta: Color(0xFFD33682),
      cyan: Color(0xFF2AA198),
      white: Color(0xFFEEE8D5),
      brightBlack: Color(0xFF586E75),
      brightRed: Color(0xFFCB4B16),
      brightGreen: Color(0xFF9FBF00),
      brightYellow: Color(0xFFD5A200),
      brightBlue: Color(0xFF4FA8E0),
      brightMagenta: Color(0xFF8085D6),
      brightCyan: Color(0xFF35BFB4),
      brightWhite: Color(0xFFFDF6E3),
    ),
  );

  /// Everforest Dark, medium. Green where the rest of the set is blue, and
  /// low-saturation throughout — the quiet one.
  static const everforest = MxPalette(
    id: 'everforest-dark',
    label: 'Everforest Dark',
    dark: true,
    canvas: Color(0xFF232A2E),
    bg: Color(0xFF2D353B),
    bgSidebar: Color(0xFF272E33),
    bgHover: Color(0xFF3D484D),
    bgActive: Color(0xFF475258),
    border: Color(0xFF3D484D),
    fg: Color(0xFFD3C6AA),
    fgDim: Color(0xFF9DA9A0),
    fgFaint: Color(0xFF7A8478),
    accent: Color(0xFF83C092),
    green: Color(0xFFA7C080),
    yellow: Color(0xFFDBBC7F),
    red: Color(0xFFE67E80),
    purple: Color(0xFFD699B6),
    ansi: MxAnsi(
      black: Color(0xFF343F44),
      red: Color(0xFFE67E80),
      green: Color(0xFFA7C080),
      yellow: Color(0xFFDBBC7F),
      blue: Color(0xFF7FBBB3),
      magenta: Color(0xFFD699B6),
      cyan: Color(0xFF83C092),
      white: Color(0xFFD3C6AA),
      brightBlack: Color(0xFF859289),
      brightWhite: Color(0xFFF2EFDF),
    ),
  );

  /// Monokai Pro. A warm charcoal window under neon — the loudest palette
  /// here, and the counterweight to Everforest.
  ///
  /// Monokai's terminal mapping sends `blue` to its orange, which is why a
  /// listing comes out warm; that is the theme, not a slip. The accent is the
  /// cyan rather than the signature pink, so that an error still reads as an
  /// error and not as the cursor.
  static const monokaiPro = MxPalette(
    id: 'monokai-pro',
    label: 'Monokai Pro',
    dark: true,
    canvas: Color(0xFF221F22),
    bg: Color(0xFF2D2A2E),
    bgSidebar: Color(0xFF262327),
    bgHover: Color(0xFF3A373B),
    bgActive: Color(0xFF4A474B),
    border: Color(0xFF403E41),
    fg: Color(0xFFFCFCFA),
    fgDim: Color(0xFFC1C0C0),
    fgFaint: Color(0xFF939293),
    accent: Color(0xFF78DCE8),
    green: Color(0xFFA9DC76),
    yellow: Color(0xFFFFD866),
    red: Color(0xFFFF6188),
    purple: Color(0xFFAB9DF2),
    ansi: MxAnsi(
      black: Color(0xFF403E41),
      red: Color(0xFFFF6188),
      green: Color(0xFFA9DC76),
      yellow: Color(0xFFFFD866),
      blue: Color(0xFFFC9867),
      magenta: Color(0xFFAB9DF2),
      cyan: Color(0xFF78DCE8),
      white: Color(0xFFFCFCFA),
      brightBlack: Color(0xFF727072),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// GitHub Light. The bright one: panels at pure white, on a canvas grey
  /// enough to keep the gutters visible. The other two light themes are both
  /// tinted — lavender and rose — and neither of them is this.
  static const githubLight = MxPalette(
    id: 'github-light',
    label: 'GitHub Light',
    dark: false,
    canvas: Color(0xFFEAEEF2),
    bg: Color(0xFFFFFFFF),
    bgSidebar: Color(0xFFF6F8FA),
    bgHover: Color(0xFFEFF2F5),
    bgActive: Color(0xFFDDE3E9),
    border: Color(0xFFD8DEE4),
    fg: Color(0xFF1F2328),
    fgDim: Color(0xFF656D76),
    fgFaint: Color(0xFF8C959F),
    accent: Color(0xFF0969DA),
    green: Color(0xFF1A7F37),
    yellow: Color(0xFF9A6700),
    red: Color(0xFFCF222E),
    purple: Color(0xFF8250DF),
    ansi: MxAnsi(
      black: Color(0xFF24292F),
      red: Color(0xFFCF222E),
      green: Color(0xFF116329),
      yellow: Color(0xFF7D4E00),
      blue: Color(0xFF0969DA),
      magenta: Color(0xFF8250DF),
      cyan: Color(0xFF1B7C83),
      white: Color(0xFF6E7781),
      brightBlack: Color(0xFF57606A),
      brightRed: Color(0xFFA40E26),
      brightGreen: Color(0xFF1A7F37),
      brightYellow: Color(0xFF9A6700),
      brightBlue: Color(0xFF218BFF),
      brightMagenta: Color(0xFFA475F9),
      brightCyan: Color(0xFF3192AA),
      brightWhite: Color(0xFF8C959F),
    ),
  );

  /// Gruvbox Light. Paper: a cream window and the dark half of Gruvbox's own
  /// colours, which are saturated enough to hold on it.
  ///
  /// Gruvbox's published light mapping swaps `black` and `white` so that ansi
  /// black paints the background — the same trade [solarizedDark] refuses, and
  /// refused here too: black stays a dark, as it does in Catppuccin Latte.
  static const gruvboxLight = MxPalette(
    id: 'gruvbox-light',
    label: 'Gruvbox Light',
    dark: false,
    canvas: Color(0xFFEBDBB2),
    bg: Color(0xFFFBF1C7),
    bgSidebar: Color(0xFFF2E5BC),
    bgHover: Color(0xFFEBDBB2),
    bgActive: Color(0xFFD5C4A1),
    border: Color(0xFFE1D2A9),
    fg: Color(0xFF3C3836),
    fgDim: Color(0xFF665C54),
    fgFaint: Color(0xFF928374),
    accent: Color(0xFF076678),
    green: Color(0xFF79740E),
    yellow: Color(0xFFB57614),
    red: Color(0xFF9D0006),
    purple: Color(0xFF8F3F71),
    ansi: MxAnsi(
      black: Color(0xFF665C54),
      red: Color(0xFF9D0006),
      green: Color(0xFF79740E),
      yellow: Color(0xFFB57614),
      blue: Color(0xFF076678),
      magenta: Color(0xFF8F3F71),
      cyan: Color(0xFF427B58),
      white: Color(0xFF7C6F64),
      brightBlack: Color(0xFF928374),
      brightRed: Color(0xFFCC241D),
      brightGreen: Color(0xFF98971A),
      brightYellow: Color(0xFFD79921),
      brightBlue: Color(0xFF458588),
      brightMagenta: Color(0xFFB16286),
      brightCyan: Color(0xFF689D6A),
      brightWhite: Color(0xFFA89984),
    ),
  );

  /// Claude. A warm greige window with a cream foreground — the app's own
  /// surfaces, not a terminal palette, since Anthropic never published one:
  /// canvas is the page, [bg] the composer card, and the ansi half is derived
  /// to sit on greige (low saturation, warm-leaning) rather than borrowed.
  ///
  /// The accent is the deeper terracotta the app puts on its buttons, one step
  /// off [Mx.claude] — close enough to read as the same family, far enough
  /// that the mark still reads as the mark and not as one more accented
  /// control. `red` is pushed to a true crimson for the same reason: an error
  /// here has to be distinguishable from a cursor.
  static const claudeDark = MxPalette(
    id: 'claude-dark',
    label: 'Claude Dark',
    dark: true,
    canvas: Color(0xFF262624),
    bg: Color(0xFF30302E),
    bgSidebar: Color(0xFF2B2A28),
    bgHover: Color(0xFF3D3C38),
    bgActive: Color(0xFF4C4A45),
    border: Color(0xFF3B3A35),
    fg: Color(0xFFF5F4EF),
    fgDim: Color(0xFFC2BFB5),
    fgFaint: Color(0xFF918D83),
    accent: Color(0xFFC96442),
    green: Color(0xFF7FA968),
    yellow: Color(0xFFD9A441),
    red: Color(0xFFE0575B),
    purple: Color(0xFFC08BB9),
    ansi: MxAnsi(
      black: Color(0xFF3D3C38),
      red: Color(0xFFE0575B),
      green: Color(0xFF7FA968),
      yellow: Color(0xFFD9A441),
      blue: Color(0xFF6F9BC4),
      magenta: Color(0xFFC08BB9),
      cyan: Color(0xFF6FA8A0),
      white: Color(0xFFE8E5DC),
      brightBlack: Color(0xFF6E6A61),
      brightRed: Color(0xFFEC7A72),
      brightGreen: Color(0xFF9CC183),
      brightYellow: Color(0xFFEBC168),
      brightBlue: Color(0xFF8FB5D9),
      brightMagenta: Color(0xFFD3A5DA),
      brightCyan: Color(0xFF8CC2B9),
      brightWhite: Color(0xFFF5F4EF),
    ),
  );

  /// Night Owl. A deep, saturated navy — darker than [cobalt] and bluer than
  /// anything near-black here — under the palette's soft blue, mint and
  /// lavender. Published palette throughout; `green` is the theme's own
  /// lime-leaning green rather than the neon it puts in the terminal, so the
  /// status glyphs stay in the family.
  static const nightOwl = MxPalette(
    id: 'night-owl',
    label: 'Night Owl',
    dark: true,
    canvas: Color(0xFF010E1A),
    bg: Color(0xFF011627),
    bgSidebar: Color(0xFF011221),
    bgHover: Color(0xFF0B2942),
    bgActive: Color(0xFF1D3B53),
    border: Color(0xFF122D42),
    fg: Color(0xFFD6DEEB),
    fgDim: Color(0xFF8FA4BE),
    fgFaint: Color(0xFF5F7E97),
    accent: Color(0xFF82AAFF),
    green: Color(0xFFADDB67),
    yellow: Color(0xFFECC48D),
    red: Color(0xFFEF5350),
    purple: Color(0xFFC792EA),
    ansi: MxAnsi(
      black: Color(0xFF1D3B53),
      red: Color(0xFFEF5350),
      green: Color(0xFF22DA6E),
      yellow: Color(0xFFADDB67),
      blue: Color(0xFF82AAFF),
      magenta: Color(0xFFC792EA),
      cyan: Color(0xFF21C7A8),
      white: Color(0xFFD6DEEB),
      brightBlack: Color(0xFF5F7E97),
      brightYellow: Color(0xFFFFEB95),
      brightCyan: Color(0xFF7FDBCA),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// Slate. The cool grey: a mid-grey window like [graphite]'s, but tinted
  /// blue throughout rather than neutral — every grey here has more blue than
  /// red in it, and nothing in the accents is warm except the yellow, which is
  /// kept dusty for the same reason. It is the counterweight to [claudeDark],
  /// which is the same lightness leaning the other way. Not a published
  /// palette; drawn as a ramp around the greys the way the default is.
  static const slate = MxPalette(
    id: 'slate',
    label: 'Slate',
    dark: true,
    canvas: Color(0xFF1E2126),
    bg: Color(0xFF2A2E35),
    bgSidebar: Color(0xFF24282E),
    bgHover: Color(0xFF353A43),
    bgActive: Color(0xFF414751),
    border: Color(0xFF3A404A),
    fg: Color(0xFFE2E7EE),
    fgDim: Color(0xFFA0AAB8),
    fgFaint: Color(0xFF6B7584),
    accent: Color(0xFF7FB2E5),
    green: Color(0xFF7DC9A5),
    yellow: Color(0xFFD4BC7A),
    red: Color(0xFFE27A88),
    purple: Color(0xFFA6A0E0),
    ansi: MxAnsi(
      black: Color(0xFF353A43),
      red: Color(0xFFE27A88),
      green: Color(0xFF7DC9A5),
      yellow: Color(0xFFD4BC7A),
      blue: Color(0xFF7FB2E5),
      magenta: Color(0xFFA6A0E0),
      cyan: Color(0xFF7CC7D6),
      white: Color(0xFFCBD2DC),
      brightBlack: Color(0xFF6B7584),
      brightRed: Color(0xFFF0929E),
      brightGreen: Color(0xFF97DDBA),
      brightYellow: Color(0xFFE6D094),
      brightBlue: Color(0xFF9CC6F0),
      brightMagenta: Color(0xFFBDB7EE),
      brightCyan: Color(0xFF98DAE7),
      brightWhite: Color(0xFFE2E7EE),
    ),
  );

  /// Graphite. The one window here with no hue in it at all: every grey is
  /// r == g == b, which is what makes it read as grey rather than as a very
  /// dark blue — the trap most other dark themes in this set fall into.
  ///
  /// Same caveat as [claudeDark]: the greys are a desktop app's, the ansi half
  /// is derived. It is deliberately the flat, saturated set a modern web app
  /// would use, because a muted one disappears against a neutral background.
  static const graphite = MxPalette(
    id: 'graphite',
    label: 'Graphite',
    dark: true,
    canvas: Color(0xFF212121),
    bg: Color(0xFF303030),
    bgSidebar: Color(0xFF272727),
    bgHover: Color(0xFF3F3F3F),
    bgActive: Color(0xFF515151),
    border: Color(0xFF3D3D3D),
    fg: Color(0xFFECECEC),
    fgDim: Color(0xFFB4B4B4),
    fgFaint: Color(0xFF8F8F8F),
    accent: Color(0xFF19C37D),
    green: Color(0xFF10A37F),
    yellow: Color(0xFFE5A33A),
    red: Color(0xFFE5484D),
    purple: Color(0xFFB87BF0),
    ansi: MxAnsi(
      black: Color(0xFF3D3D3D),
      red: Color(0xFFE5484D),
      green: Color(0xFF10A37F),
      yellow: Color(0xFFE5A33A),
      blue: Color(0xFF4E9BF5),
      magenta: Color(0xFFB87BF0),
      cyan: Color(0xFF2DBFB1),
      white: Color(0xFFD9D9D9),
      brightBlack: Color(0xFF6E6E6E),
      brightRed: Color(0xFFFF6B6E),
      brightGreen: Color(0xFF19C37D),
      brightYellow: Color(0xFFF5C15A),
      brightBlue: Color(0xFF74B3FF),
      brightMagenta: Color(0xFFCE9AFF),
      brightCyan: Color(0xFF55D8CB),
      brightWhite: Color(0xFFECECEC),
    ),
  );

  /// SynthWave '84. Pink on deep purple — the one dark window here that is
  /// violet rather than blue-black or grey, and the only pink accent in the
  /// set. Published palette for the surfaces and the accents; the theme has no
  /// blue of its own, so ansi `blue` is a periwinkle chosen to keep a listing
  /// readable while staying in the family.
  static const synthwave = MxPalette(
    id: 'synthwave-84',
    label: "SynthWave '84",
    dark: true,
    canvas: Color(0xFF1A1727),
    bg: Color(0xFF262335),
    bgSidebar: Color(0xFF241B2F),
    bgHover: Color(0xFF34294F),
    bgActive: Color(0xFF463465),
    border: Color(0xFF34294F),
    fg: Color(0xFFF0EFF1),
    fgDim: Color(0xFFAFA9D3),
    fgFaint: Color(0xFF848BBD),
    accent: Color(0xFFFF7EDB),
    green: Color(0xFF72F1B8),
    yellow: Color(0xFFFEDE5D),
    red: Color(0xFFFE4450),
    purple: Color(0xFFB893CE),
    ansi: MxAnsi(
      black: Color(0xFF34294F),
      red: Color(0xFFFE4450),
      green: Color(0xFF72F1B8),
      yellow: Color(0xFFFEDE5D),
      blue: Color(0xFF8C8CFF),
      magenta: Color(0xFFFF7EDB),
      cyan: Color(0xFF36F9F6),
      white: Color(0xFFF0EFF1),
      brightBlack: Color(0xFF848BBD),
      brightRed: Color(0xFFF97E72),
      brightYellow: Color(0xFFF3E70F),
      brightBlue: Color(0xFFA6A6FF),
      brightCyan: Color(0xFF03EDF9),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// Cobalt. A real blue window, not a navy one — the only theme in the set
  /// whose background is a colour you would name — with the yellow that is
  /// its signature as the accent. `yellow` therefore takes the palette's
  /// orange, so a search hit and the current hit stay two colours.
  static const cobalt = MxPalette(
    id: 'cobalt',
    label: 'Cobalt',
    dark: true,
    canvas: Color(0xFF122738),
    bg: Color(0xFF193549),
    bgSidebar: Color(0xFF15232D),
    bgHover: Color(0xFF1F4662),
    bgActive: Color(0xFF245A7E),
    border: Color(0xFF234E6D),
    fg: Color(0xFFFFFFFF),
    fgDim: Color(0xFF9FB8CF),
    fgFaint: Color(0xFF5B87AD),
    accent: Color(0xFFFFC600),
    green: Color(0xFF3AD900),
    yellow: Color(0xFFFF9D00),
    red: Color(0xFFFF628C),
    purple: Color(0xFFFB94FF),
    ansi: MxAnsi(
      black: Color(0xFF1F4662),
      red: Color(0xFFFF628C),
      green: Color(0xFF3AD900),
      yellow: Color(0xFFFFC600),
      blue: Color(0xFF0088FF),
      magenta: Color(0xFFFB94FF),
      cyan: Color(0xFF80FCFF),
      white: Color(0xFFE0E8F0),
      brightBlack: Color(0xFF5B87AD),
      brightRed: Color(0xFFFF2C6D),
      brightGreen: Color(0xFFA5FF90),
      brightYellow: Color(0xFFFFE50A),
      brightBlue: Color(0xFF55AAFF),
      brightCyan: Color(0xFF9EFFFF),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// High Contrast. True black, true white, and colours saturated enough to
  /// clear WCAG AAA on both — the Modus Vivendi set, which was built for
  /// exactly that. Nothing else here is black: [ayuDark] is the closest and
  /// still a step off it. The panels lift off the canvas by a few points so
  /// the gutters survive, and the border is the one deliberately loud grey.
  static const highContrast = MxPalette(
    id: 'high-contrast',
    label: 'High Contrast',
    dark: true,
    canvas: Color(0xFF000000),
    bg: Color(0xFF0F0F0F),
    bgSidebar: Color(0xFF080808),
    bgHover: Color(0xFF1E1E1E),
    bgActive: Color(0xFF2E2E2E),
    border: Color(0xFF4A4A4A),
    fg: Color(0xFFFFFFFF),
    fgDim: Color(0xFFC6C6C6),
    fgFaint: Color(0xFF8A8A8A),
    accent: Color(0xFF2FAFFF),
    green: Color(0xFF44BC44),
    yellow: Color(0xFFD0BC00),
    red: Color(0xFFFF5F59),
    purple: Color(0xFFB6A0FF),
    ansi: MxAnsi(
      black: Color(0xFF595959),
      red: Color(0xFFFF5F59),
      green: Color(0xFF44BC44),
      yellow: Color(0xFFD0BC00),
      blue: Color(0xFF2FAFFF),
      magenta: Color(0xFFFF66FF),
      cyan: Color(0xFF00D3D0),
      white: Color(0xFFE0E0E0),
      brightBlack: Color(0xFF8A8A8A),
      brightRed: Color(0xFFFF8F88),
      brightGreen: Color(0xFF70D73F),
      brightYellow: Color(0xFFFEC43F),
      brightBlue: Color(0xFF79A8FF),
      brightMagenta: Color(0xFFF78FE7),
      brightCyan: Color(0xFF6AE4B9),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// Zenburn. The lightest window in the set by a clear margin — an olive-grey
  /// panel where most others are near-black ones — and the only theme here
  /// that is low-contrast on purpose: its foreground is a soft bone, not white,
  /// and its red is dusty enough to point at an error without shouting.
  ///
  /// Published palette, ansi included; the greys are its own `bg`, `bg-1` and
  /// `bg+1` rather than a ramp invented around them.
  static const zenburn = MxPalette(
    id: 'zenburn',
    label: 'Zenburn',
    dark: true,
    canvas: Color(0xFF2F2F2F),
    bg: Color(0xFF3F3F3F),
    bgSidebar: Color(0xFF383838),
    bgHover: Color(0xFF4F4F4F),
    bgActive: Color(0xFF5F5F5F),
    border: Color(0xFF4A4A4A),
    fg: Color(0xFFDCDCCC),
    fgDim: Color(0xFFB8B8A6),
    fgFaint: Color(0xFF909082),
    accent: Color(0xFF8CD0D3),
    green: Color(0xFF60B48A),
    yellow: Color(0xFFF0DFAF),
    red: Color(0xFFCC9393),
    purple: Color(0xFFDC8CC3),
    ansi: MxAnsi(
      black: Color(0xFF4D4D4D),
      red: Color(0xFF705050),
      green: Color(0xFF60B48A),
      yellow: Color(0xFFDFAF8F),
      blue: Color(0xFF506070),
      magenta: Color(0xFFDC8CC3),
      cyan: Color(0xFF8CD0D3),
      white: Color(0xFFDCDCCC),
      brightBlack: Color(0xFF709080),
      brightRed: Color(0xFFDCA3A3),
      brightGreen: Color(0xFFC3BF9F),
      brightYellow: Color(0xFFF0DFAF),
      brightBlue: Color(0xFF94BFF3),
      brightMagenta: Color(0xFFEC93D3),
      brightCyan: Color(0xFF93E0E3),
      brightWhite: Color(0xFFFFFFFF),
    ),
  );

  /// Picker order: hues interleaved rather than grouped by family, so that
  /// neighbours contrast and the grid reads as a range at a glance — the light
  /// greys are spread through the darks for the same reason, not parked
  /// together at the end. Darks first, lights last.
  static const List<MxPalette> all = [
    maestria,
    ayuDark,
    claudeDark,
    cobalt,
    everforest,
    highContrast,
    nightOwl,
    gruvbox,
    solarizedDark,
    graphite,
    synthwave,
    slate,
    monokaiPro,
    nord,
    dracula,
    zenburn,
    githubLight,
    rosePineDawn,
    gruvboxLight,
  ];

  /// Ids that earlier builds wrote and this one no longer ships, each sent to
  /// the id of the theme it most looked like — so a config file from before
  /// the cut comes up in the same window it had, not in the default.
  ///
  /// Ids, not palettes: Frappé and Rosé Pine went to Mocha, and Mocha is now a
  /// plugin's theme. Without the plugin they land on the default like any
  /// other id nobody knows.
  static const Map<String, String> _retired = {
    'tokyo-night': 'maestria',
    'catppuccin-frappe': 'catppuccin-mocha',
    'rose-pine': 'catppuccin-mocha',
    'chatgpt-dark': 'graphite',
  };

  /// Os temas que vieram de plugins. Ver `services/plugins.dart`.
  ///
  /// Fora de [all] de propósito: [all] é o conjunto curado, com as regras de
  /// espaçamento que o comentário da classe descreve, e um tema de plugin não
  /// passou por nenhuma delas. A galeria os desenha depois, num bloco próprio.
  /// Quem mexe nesta lista é só o [Plugins], que a remonta inteira a cada
  /// carga -- ligar, desligar ou remover um plugin tira os temas dele daqui.
  static final List<MxPalette> extra = [];

  /// An id from a config file written by a newer build — or by a hand — is not
  /// a reason to fail to start: fall back to the default.
  static MxPalette byId(String? id) => _find(id) ?? _find(_retired[id]) ?? maestria;

  static MxPalette? _find(String? id) =>
      all.where((p) => p.id == id).firstOrNull ?? extra.where((p) => p.id == id).firstOrNull;

  /// Se [id] já é de um tema embutido — ou de um que foi aposentado e ainda
  /// responde por ele. Um plugin não pode tomar esse nome: o config de quem
  /// escolheu o embutido passaria a abrir no tema do plugin.
  static bool isBuiltIn(String id) => all.any((p) => p.id == id) || _retired.containsKey(id);
}

/// Uma face monoespaçada que a tela de configurações oferece.
///
/// [bundled] é a única que não precisa existir na máquina pra aparecer na
/// lista: ela vem dentro do app (ver `pubspec.yaml`). O resto é do sistema, e
/// "está instalada?" não é uma pergunta que o Flutter responda — ver
/// [MxFaces.resolves].
@immutable
class MxFace {
  const MxFace(this.family, {this.note, this.bundled = false});

  final String family;

  /// O que a face é, pra quem não a reconhece pelo nome.
  final String? note;

  final bool bundled;
}

/// As monoespaçadas oferecidas, e a descoberta de quais delas existem aqui.
class MxFaces {
  const MxFaces._();

  static const hack = MxFace('Hack', note: 'vem no app', bundled: true);

  /// A lista, na ordem em que a tela a mostra.
  ///
  /// Sem ramo por plataforma de propósito: Menlo não existe no Linux e a
  /// DejaVu não existe no mac, e é [resolves] que descobre isso — pela mesma
  /// medida com que descobre a JetBrains Mono de quem foi instalá-la.
  /// Longa de propósito: como só as que existem são desenhadas, um nome a mais
  /// na lista é uma chance a mais de a tela oferecer justamente a fonte que a
  /// pessoa já usa no terminal dela — e custa duas medidas, uma vez.
  ///
  /// As Nerd Font vêm primeiro pela razão de sempre: o que roda nestes painéis
  /// é uma TUI, e o prompt de quem instalou uma delas desenha glifos que só
  /// ela tem.
  static const all = <MxFace>[
    hack,
    MxFace('Hack Nerd Font', note: 'com os glifos do prompt'),
    MxFace('JetBrainsMono Nerd Font'),
    MxFace('FiraCode Nerd Font'),
    MxFace('MesloLGS NF'),
    MxFace('SF Mono', note: 'a do Terminal.app'),
    MxFace('Menlo', note: 'a do macOS'),
    MxFace('Monaco'),
    MxFace('JetBrains Mono'),
    MxFace('Fira Code'),
    MxFace('IBM Plex Mono'),
    MxFace('Source Code Pro'),
    MxFace('Roboto Mono'),
    MxFace('Inconsolata'),
    MxFace('Cascadia Code'),
    MxFace('Cascadia Mono'),
    MxFace('Iosevka'),
    MxFace('Berkeley Mono'),
    MxFace('Geist Mono'),
    MxFace('Commit Mono'),
    MxFace('Maple Mono'),
    MxFace('Monaspace Neon'),
    MxFace('Victor Mono'),
    MxFace('Anonymous Pro'),
    MxFace('DejaVu Sans Mono'),
    MxFace('Liberation Mono'),
    MxFace('Noto Sans Mono'),
    MxFace('Ubuntu Mono'),
    MxFace('Andale Mono'),
    MxFace('PT Mono'),
    MxFace('Courier New'),
  ];

  /// As que esta máquina tem — a lista que a tela desenha.
  static List<MxFace> get installed => all.where(available).toList();

  static bool available(MxFace face) => face.bundled || resolves(face.family);

  /// A face chamada [family], ou a padrão quando esse nome não existe aqui.
  ///
  /// É o que faz um config trazido de outra máquina — ou de uma fonte
  /// desinstalada desde a última vez — abrir na Hack, em vez de abrir na
  /// proporcional do sistema, que é onde o motor cai calado.
  static MxFace byFamily(String? family) =>
      all.firstWhereOrNull((f) => f.family == family && available(f)) ?? hack;

  static final Map<String, bool> _resolved = {};

  /// Se [family] existe nesta máquina.
  ///
  /// Não há API pra listar as fontes instaladas, então a pergunta é feita do
  /// único jeito que sobra: medindo. Uma família que o motor não resolve cai
  /// na fonte padrão da plataforma, que é proporcional — de modo que `iiii` e
  /// `MMMM` saírem com a mesma largura é a prova de que ela resolveu.
  ///
  /// Uma face que vem no app não passa por aqui: o asset pode ainda não estar
  /// carregado na primeira medida, e a resposta seria um "não" falso.
  static bool resolves(String family) => _resolved.putIfAbsent(family, () {
    double advance(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: 40, fontFamily: family)),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final narrow = advance('iiiiiiii');
    return narrow > 0 && (narrow - advance('MMMMMMMM')).abs() < 0.5;
  });
}

/// A tipografia do pty: a face, o corpo e a entrelinha.
///
/// Três constantes, até virarem escolha. Moram juntas porque é junto que elas
/// se decidem — uma face mais estreita pede um corpo maior, um corpo maior
/// pede menos entrelinha — e porque é junto que elas vão pro config.
@immutable
class MxType {
  const MxType._(this.mono, this.size, this.line);

  /// Normaliza na entrada, e não no uso: um corpo de 400 ou uma face que
  /// ninguém tem chegam de um config editado à mão, e o lugar de descobrir
  /// isso é aqui, uma vez — não em cada frame do pty.
  factory MxType({String? mono, double? size, double? line}) => MxType._(
    MxFaces.byFamily(mono ?? standard.mono).family,
    _round((size ?? standard.size).clamp(minSize, maxSize)),
    _round((line ?? standard.line).clamp(minLine, maxLine)),
  );

  /// O pty como sempre foi: Hack, nos 13px do Warp sobre uma linha de 1.2.
  static const standard = MxType._('Hack', 13.0, 1.2);

  final String mono;
  final double size;
  final double line;

  static const minSize = 9.0;
  static const maxSize = 24.0;
  static const minLine = 1.0;
  static const maxLine = 1.8;

  /// De quanto em quanto o ⌘+ e os steppers da tela andam.
  static const sizeStep = 1.0;
  static const lineStep = 0.1;

  /// O zoom de um painel, contido pelo que a base deixa.
  ///
  /// Sem o teto, dez ⌘+ além do limite viram dez ⌘− pra voltar de um tamanho
  /// que nunca mudou. E é por guardar passos, e não tamanho, que trocar a base
  /// aqui leva todo painel junto sem apagar a diferença que cada um pediu.
  int clampZoom(int zoom) => zoom.clamp((minSize - size).ceil(), (maxSize - size).floor());

  double sizeAt(int zoom) => size + clampZoom(zoom);

  MxType copyWith({String? mono, double? size, double? line}) =>
      MxType(mono: mono ?? this.mono, size: size ?? this.size, line: line ?? this.line);

  /// Só o que difere do padrão vai pro disco, pelo mesmo motivo dos atalhos:
  /// um padrão que mude numa versão futura chega em quem já tem config.
  Map<String, dynamic> toJson() => {
    if (mono != standard.mono) 'mono': mono,
    if (size != standard.size) 'size': size,
    if (line != standard.line) 'line': line,
  };

  static MxType fromJson(Object? json) => json is! Map
      ? standard
      : MxType(
          mono: json['mono'] as String?,
          size: (json['size'] as num?)?.toDouble(),
          line: (json['line'] as num?)?.toDouble(),
        );

  /// 1.2000000000000002 não é uma entrelinha, é 0.1 somado três vezes.
  /// Arredondar na entrada mantém o config legível e a igualdade útil.
  static double _round(double value) => (value * 100).roundToDouble() / 100;

  @override
  bool operator ==(Object other) =>
      other is MxType && other.mono == mono && other.size == size && other.line == line;

  @override
  int get hashCode => Object.hash(mono, size, line);

  @override
  String toString() => '$mono ${size}px/$line';
}

/// The palette in force, plus the geometry every panel shares.
///
/// Reads as a bag of constants at the call sites — `Mx.fg`, `Mx.border` — but
/// each colour is a getter onto [current], so switching a theme repaints the
/// window instead of asking 108 call sites to be rewritten. The price is that
/// none of the colours are `const` any more; the compiler names every place
/// that assumed otherwise.
class Mx {
  /// The theme in force. Listened to above the [MaterialApp], so a change
  /// rebuilds the whole tree.
  static final ValueNotifier<MxPalette> current = ValueNotifier(MxThemes.maestria);

  static MxPalette get palette => current.value;

  static void apply(MxPalette p) => current.value = p;

  static void applyId(String? id) => current.value = MxThemes.byId(id);

  /// A tipografia em vigor, pelo mesmo desenho da paleta: um notifier só, e
  /// getters onde antes havia constantes. Ver [MxType].
  static final ValueNotifier<MxType> typography = ValueNotifier(MxType.standard);

  static MxType get type => typography.value;

  static void applyType(MxType t) => typography.value = t;

  /// O que repinta a janela. Escutado acima do [MaterialApp] (ver
  /// `main.dart`), porque nem a paleta nem a tipografia são de uma região só.
  static final Listenable chrome = Listenable.merge([current, typography]);

  static Color get canvas => palette.canvas;
  static Color get bg => palette.bg;
  static Color get bgSidebar => palette.bgSidebar;
  static Color get bgHover => palette.bgHover;
  static Color get bgActive => palette.bgActive;
  static Color get border => palette.border;
  static Color get fg => palette.fg;
  static Color get fgDim => palette.fgDim;
  static Color get fgFaint => palette.fgFaint;
  static Color get accent => palette.accent;
  static Color get green => palette.green;
  static Color get yellow => palette.yellow;
  static Color get red => palette.red;
  static Color get purple => palette.purple;
  static Color get shadow => palette.shadow;

  /// What the pty paints with. Follows the theme like everything else.
  static TerminalTheme get terminal => palette.terminal;

  /// As cores com que um grupo de painéis se marca. Ver `PaneGroup.color`.
  ///
  /// Saem do ansi da paleta, e não dos cinco acentos da interface: accent,
  /// verde, amarelo, vermelho e roxo já são os estados de uma sessão (ver
  /// `ClaudeStatusUi.color`), e um grupo não é um estado -- é uma etiqueta.
  /// O ansi existe em toda paleta, é escolhido pra ficar legível sobre o fundo
  /// dela e no chrome ainda não significa nada, então é a família de cor que
  /// dá pra gastar sem tirar sentido de outra.
  ///
  /// Quatro, e não uma por grupo: o que a cor precisa dizer é "estes três são
  /// um conjunto", não "este é o grupo número onze" -- e uma paleta de doze
  /// tons ninguém distingue. O quinto grupo repete a cor do primeiro.
  ///
  /// Vermelho fica de fora de propósito: é a única cor que o app reserva pro
  /// que tem risco (ver [ClaudeStatus.waitingPermission]), e uma linha lavada
  /// de vermelho leria como alarme em vez de etiqueta.
  static List<Color> get groupTints => [
    palette.ansi.cyan,
    palette.ansi.magenta,
    palette.ansi.blue,
    palette.ansi.brightGreen,
  ];

  /// Anthropic's orange. Reserved for the Claude mark itself — a session's
  /// *state* is said by the badge on it, never by recolouring the logo — and
  /// so the one colour a theme does not get to touch.
  static const claude = Color(0xFFD97757);

  /// The one monospace in the app: the pty and every mono label around it —
  /// the pane header, the result strip, a branch name in the sidebar. Two
  /// different monos inside the same card read as a bug, so there is one.
  ///
  /// Hack, bundled (see `pubspec.yaml`), até alguém escolher outra. Seu avanço
  /// é 1233/2048 em, o mesmo do Menlo — é por isso que a face sempre foi
  /// trocável sem nada que caiba hoje deixar de caber.
  static String get mono => type.mono;

  /// The pty's own text, Warp's defaults: 13px on a 1.2 line. Bigger than the
  /// 12.5 the panes used to be, and the extra leading is what makes a wall of
  /// tool output scannable instead of a block. Agora só o ponto de partida:
  /// cada painel anda a partir daqui com ⌘+ e ⌘− (ver [MxType.sizeAt]).
  static double get terminalFontSize => type.size;
  static double get terminalLineHeight => type.line;

  /// O estilo que o pty recebe, com [zoom] passos de ⌘+ somados — uma
  /// instância por combinação, e a mesma em todo rebuild.
  ///
  /// A memória é o ponto. [TerminalStyle] não tem igualdade de valor, então o
  /// painter do xterm compara por identidade: uma instância nova por build faz
  /// ele remedir a célula e remarcar o layout de todo painel a cada tique do
  /// relógio da lateral. Era o que o `const` de antes garantia de graça.
  static TerminalStyle ptyStyle([int zoom = 0]) {
    final key = (type.mono, type.sizeAt(zoom), type.line);
    return _ptyStyles.putIfAbsent(
      key,
      () => TerminalStyle(
        fontFamily: key.$1,
        fontSize: key.$2,
        height: key.$3,
        fontFamilyFallback: _ptyFallback,
      ),
    );
  }

  /// Não esvazia: são no máximo umas dezenas de combinações — uma face, um
  /// corpo e uma entrelinha por vez, mais um punhado de zooms de painel.
  static final Map<(String, double, double), TerminalStyle> _ptyStyles = {};

  /// A cascata pros glifos que a face do terminal não tem.
  ///
  /// A Hack não tem `⏺`, `✽`, `⎿`, `⏱` nem `☒` — medido, e é justamente o
  /// alfabeto de marcadores do Claude Code —, então sem uma cascata que os
  /// cubra o painel desenha o quadradinho do `.notdef` no lugar do ponto.
  ///
  /// É a lista de fábrica do xterm com as fontes de símbolo empurradas pra
  /// frente: no macOS a `STIX Two Math` tem todos eles menos o `✻`, que está
  /// na Menlo; no Linux do `.deb` quem cobre é a Noto de símbolos ou a DejaVu.
  /// Família que não está instalada é ignorada, então a mesma lista serve pros
  /// dois — e a face escolhida continua vindo primeiro: a cascata só entra no
  /// caractere que falta.
  static const _ptyFallback = [
    'Menlo',
    'Monaco',
    'STIX Two Math',
    'Apple Symbols',
    'Noto Sans Symbols 2',
    'Noto Sans Symbols',
    'DejaVu Sans',
    'Noto Color Emoji',
    'Liberation Mono',
    'Courier New',
    'monospace',
    'sans-serif',
  ];

  /// Panel geometry: the gutter between two panels, and their corner radius.
  /// Shared so the sidebar, the panes and the status bar line up.
  static const gap = 8.0;
  static const radius = 10.0;

  static ThemeData theme() {
    final p = palette;
    final base = p.dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      dividerColor: p.border,
      colorScheme: base.colorScheme.copyWith(
        primary: p.accent,
        surface: p.bgSidebar,
        onSurface: p.fg,
      ),
      textTheme: base.textTheme.apply(bodyColor: p.fg, displayColor: p.fg),
      dialogTheme: DialogThemeData(
        backgroundColor: p.bgSidebar,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: p.border),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.bgActive,
          borderRadius: BorderRadius.circular(6),
          border: Border.fromBorderSide(BorderSide(color: p.border)),
        ),
        textStyle: TextStyle(color: p.fg, fontSize: 11),
      ),
      // Os menus de contexto, no desenho do resto da janela.
      //
      // Sem isto eles vinham inteiros do Material: canto de 4, borda nenhuma e
      // a sombra rasa do M3 -- e um menu assim, aberto por cima de painéis de
      // canto 10 e borda visível, lê como coisa de outro programa. O raio é o
      // mesmo dos painéis ([radius]) porque é a mesma família de superfície: o
      // que flutua na janela tem esse canto.
      popupMenuTheme: PopupMenuThemeData(
        color: p.bgActive,
        surfaceTintColor: Colors.transparent,
        // Fundo do menu é um passo acima do da lateral e a diferença é de um
        // fio; a sombra é o que diz que ele está *em cima* e não dentro.
        elevation: 12,
        shadowColor: p.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: p.border),
        ),
        // O ar em volta das linhas é o que deixa o canto ser visto: a primeira
        // e a última param antes da curva em vez de encostar nela.
        menuPadding: const EdgeInsets.symmetric(vertical: 5),
        // O M3 lê `labelTextStyle` e ignora `textStyle`; sem isto a linha vem
        // com o corpo de um `labelLarge` (14) no meio de uma janela de 12.
        // O desligado sai no cinza da paleta em vez do onSurface a 38%, que
        // numa paleta clara fica lavado.
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            color: states.contains(WidgetState.disabled) ? p.fgFaint : p.fg,
          ),
        ),
      ),
    );
  }
}

/// A cor que alguém escolheu pra um painel.
///
/// Opcional de propósito, e é a diferença entre isto e `PaneGroup.color`: a
/// cor de um grupo sai do id dele porque um grupo *é* um conjunto e ninguém
/// precisa ser consultado pra dizer isso. Um painel não é nada disso -- ele é
/// um trabalho --, então pintar todos automaticamente seria a janela dizendo
/// que há um sentido nas cores que não há. Sem escolha, um painel não tem cor:
/// [MxTab.tint] é null e o cartão é o cartão de sempre.
///
/// Guardada pelo papel e não pelo valor, que é o mesmo princípio de
/// [MxPalette]: o config diz "ciano" e que ciano é isso quem responde é a
/// paleta em vigor. Um `Color` gravado no json seria o ciano do tema de ontem
/// sobrevivendo à troca de tema -- uma cor aceso sozinha no meio de uma paleta
/// que não é a dela.
///
/// Saem do ansi, pelo motivo escrito em [Mx.groupTints]: os cinco acentos da
/// interface já são os estados de uma sessão, e o ansi no chrome ainda não
/// significa nada. Mas saem dele só pela metade -- a claridade e a saturação --,
/// e o tom é fixo, de cada cor. É isso que deixa haver treze.
///
/// Treze tons tirados do ansi direto não existem: depois do preto, do branco e
/// do cinza ele tem cinco. E misturar dois vizinhos pra fazer um terceiro só
/// funciona onde os vizinhos são diferentes, o que nem toda paleta garante: no
/// Everforest o verde e o ciano são quase o mesmo verde, e o "ciano" do Rosé
/// Pine Dawn é rosa. Medido, a mistura deixava pares que o olho não separa.
/// Com o tom fixo e a claridade e a saturação médias do ansi da paleta, os
/// treze ficam a um ΔE de 11 ou mais um do outro em todo tema embutido (ver
/// `theme_test.dart`), e cada tema continua dando o jeito das suas cores: mais
/// apagadas no Nord, mais acesas no Synthwave, mais escuras num tema claro.
///
/// O cinza é a exceção, e sai do ansi inteiro: o `brightBlack` é o cinza que a
/// paleta escolheu pra ficar legível sobre o fundo dela.
///
/// Azul ficou de fora. Na paleta padrão ele é o mesmo valor do [Mx.accent], e
/// o accent é o anel do painel em foco -- uma cor que quer dizer "este painel
/// é aquele" não pode ser a mesma que já diz "o teclado está aqui". O
/// azul-petróleo e o violeta ficam um de cada lado dele.
///
/// Vermelho entrou, contra a regra do [Mx.groupTints], que o reserva pro que
/// tem risco ([ClaudeStatus.waitingPermission]). A diferença é quem pinta:
/// lá a cor é deduzida e cair em vermelho sem querer seria a janela dando um
/// alarme falso; aqui ela é pedida, e um painel vermelho quer dizer o que a
/// pessoa que o pintou quis dizer. O que ela custa está dito: um painel
/// vermelho e um pedido de permissão passam a dividir a mesma família de cor.
///
/// A ordem é a do círculo de cores, e o config guarda o nome: uma cor que
/// entra no meio da lista não muda a de ninguém.
enum MxTint {
  red('Vermelho', 25),
  orange('Laranja', 55),
  yellow('Amarelo', 95),
  lime('Lima', 125),
  green('Verde', 150),
  aqua('Verde-água', 175),
  cyan('Ciano', 205),
  petrol('Azul-petróleo', 235),
  violet('Violeta', 290),
  magenta('Magenta', 330),
  pink('Rosa', 0),
  // O laranja com menos luz e menos cor, que é o que um marrom é.
  brown('Marrom', 55),
  grey('Cinza', 0);

  const MxTint(this.label, this._hue);

  /// Como a linha do menu se chama. Em português, como o resto dos menus.
  final String label;

  /// O tom no círculo do OKLCH, em graus.
  final double _hue;

  Color get color => _tintsOf(Mx.palette)[index];

  /// As treze da paleta, calculadas uma vez por paleta: `color` é lido a cada
  /// build de cada linha pintada da lateral.
  static List<Color> _tintsOf(MxPalette palette) {
    if (identical(palette, _cachedFor)) return _cached;
    final a = palette.ansi;
    final base = [a.red, a.yellow, a.brightGreen, a.cyan, a.magenta].map(_Oklch.of);
    final lightness = base.map((c) => c.l).average;
    final chroma = base.map((c) => c.c).average;
    _cachedFor = palette;
    return _cached = [
      for (final tint in values)
        switch (tint) {
          MxTint.grey => a.brightBlack,
          MxTint.brown => _Oklch(lightness * 0.8, chroma * 0.6, tint._hue).toColor(),
          _ => _Oklch(lightness, chroma, tint._hue).toColor(),
        },
    ];
  }

  static MxPalette? _cachedFor;
  static List<Color> _cached = const [];

  /// O que o config diz, virado de volta em cor -- ou null, que é o painel
  /// sem cor. Um nome que não existe mais também volta null: um painel
  /// pintado de `blue` antes de o azul sair da lista reabre sem cor, que é o
  /// pior que pode acontecer com ele -- e melhor que uma exceção no meio da
  /// leitura do layout.
  static MxTint? byName(String? name) {
    for (final tint in values) {
      if (tint.name == name) return tint;
    }
    return null;
  }
}

/// Uma cor no OKLCH: claridade, croma e tom. É o espaço em que dois tons a
/// mesma distância no círculo parecem a mesma distância pro olho -- no HSL o
/// amarelo e o azul de mesma "luz" não têm a mesma luz nenhuma.
///
/// As matrizes são as do Björn Ottosson, que publicou o espaço.
class _Oklch {
  const _Oklch(this.l, this.c, this.hue);

  final double l, c, hue;

  static _Oklch of(Color color) {
    double linear(double v) =>
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = linear(color.r), g = linear(color.g), b = linear(color.b);
    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final okA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final okB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    return _Oklch(
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      sqrt(okA * okA + okB * okB),
      atan2(okB, okA) * 180 / pi,
    );
  }

  /// De volta pro sRGB. O que cair fora dele é cortado na borda -- com a croma
  /// média de um ansi, isso é raro e pouco.
  Color toColor() {
    final h = hue * pi / 180;
    final okA = c * cos(h), okB = c * sin(h);
    final l = pow(this.l + 0.3963377774 * okA + 0.2158037573 * okB, 3);
    final m = pow(this.l - 0.1055613458 * okA - 0.0638541728 * okB, 3);
    final s = pow(this.l - 0.0894841775 * okA - 1.2914855480 * okB, 3);
    double encoded(num v) {
      final x = v.clamp(0, 1).toDouble();
      return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
    }

    return Color.from(
      alpha: 1,
      red: encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
      green: encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      blue: encoded(-0.0041960771 * l - 0.7034186147 * m + 1.7076069010 * s),
    );
  }

  static double _cbrt(double v) => pow(v, 1 / 3).toDouble();
}
