import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// The sixteen colours a pty speaks in.
///
/// The bright half is optional: several palettes (the Catppuccin family, most
/// notably) publish one set and let bright fall back onto it, and spelling
/// sixteen literals out to say eight of them twice helps nobody.
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
/// nothing else does: ink, sand-on-ink, forest, indigo, brown, teal, violet,
/// warm neon, steel, neon purple, rose — then four lights that are as far
/// apart, paper white through cream. Two palettes that differ only in how far
/// up the greyscale they sit are one palette; the second one goes.
///
/// Hue is only half of that spread, though, and the cheaper half. Thirteen
/// darks whose windows all sat between L\* 4 and L\* 22 read as one dark theme
/// wearing thirteen accents, because the background is most of what you see.
/// So the set also has to climb: [claudeDark] and [chatgptDark] sit on the
/// grey the desktop apps they come from use, and [zenburn] goes further up
/// than anything else here. [chatgptDark] holds the other gap those found —
/// it is the only window with no hue in it at all.
///
/// Catppuccin is the one exception, and it is deliberate: its four flavours
/// *are* one palette at four lightnesses, but people know them by flavour name
/// and arrive already knowing which one they want, so shipping Mocha alone
/// would read as the theme missing rather than as the set being tight. The
/// four sit apart in the picker so the grid still reads as a range.
class MxThemes {
  static const maestria = MxPalette(
    id: 'maestria',
    label: 'Maestria Dark',
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

  static const catppuccinMocha = MxPalette(
    id: 'catppuccin-mocha',
    label: 'Catppuccin Mocha',
    dark: true,
    canvas: Color(0xFF11111B),
    bg: Color(0xFF1E1E2E),
    bgSidebar: Color(0xFF181825),
    bgHover: Color(0xFF313244),
    bgActive: Color(0xFF45475A),
    border: Color(0xFF313244),
    fg: Color(0xFFCDD6F4),
    fgDim: Color(0xFFA6ADC8),
    fgFaint: Color(0xFF6C7086),
    accent: Color(0xFF89B4FA),
    green: Color(0xFFA6E3A1),
    yellow: Color(0xFFF9E2AF),
    red: Color(0xFFF38BA8),
    purple: Color(0xFFCBA6F7),
    ansi: MxAnsi(
      black: Color(0xFF45475A),
      red: Color(0xFFF38BA8),
      green: Color(0xFFA6E3A1),
      yellow: Color(0xFFF9E2AF),
      blue: Color(0xFF89B4FA),
      magenta: Color(0xFFF5C2E7),
      cyan: Color(0xFF94E2D5),
      white: Color(0xFFBAC2DE),
      brightBlack: Color(0xFF585B70),
      brightWhite: Color(0xFFA6ADC8),
    ),
  );

  /// Catppuccin Macchiato. Mocha's palette lifted off the black: the same
  /// hues, a step warmer and a step lighter, on a base that is visibly blue
  /// rather than near-ink.
  static const catppuccinMacchiato = MxPalette(
    id: 'catppuccin-macchiato',
    label: 'Catppuccin Macchiato',
    dark: true,
    canvas: Color(0xFF181926),
    bg: Color(0xFF24273A),
    bgSidebar: Color(0xFF1E2030),
    bgHover: Color(0xFF363A4F),
    bgActive: Color(0xFF494D64),
    border: Color(0xFF363A4F),
    fg: Color(0xFFCAD3F5),
    fgDim: Color(0xFFA5ADCB),
    fgFaint: Color(0xFF6E738D),
    accent: Color(0xFF8AADF4),
    green: Color(0xFFA6DA95),
    yellow: Color(0xFFEED49F),
    red: Color(0xFFED8796),
    purple: Color(0xFFC6A0F6),
    ansi: MxAnsi(
      black: Color(0xFF494D64),
      red: Color(0xFFED8796),
      green: Color(0xFFA6DA95),
      yellow: Color(0xFFEED49F),
      blue: Color(0xFF8AADF4),
      magenta: Color(0xFFF5BDE6),
      cyan: Color(0xFF8BD5CA),
      white: Color(0xFFB8C0E0),
      brightBlack: Color(0xFF5B6078),
      brightWhite: Color(0xFFA5ADCB),
    ),
  );

  /// Catppuccin Frappé. The light end of the family's dark half — a slate
  /// window rather than a black one, and the softest contrast of any dark
  /// theme here.
  static const catppuccinFrappe = MxPalette(
    id: 'catppuccin-frappe',
    label: 'Catppuccin Frappé',
    dark: true,
    canvas: Color(0xFF232634),
    bg: Color(0xFF303446),
    bgSidebar: Color(0xFF292C3C),
    bgHover: Color(0xFF414559),
    bgActive: Color(0xFF51576D),
    border: Color(0xFF414559),
    fg: Color(0xFFC6D0F5),
    fgDim: Color(0xFFA5ADCE),
    fgFaint: Color(0xFF737994),
    accent: Color(0xFF8CAAEE),
    green: Color(0xFFA6D189),
    yellow: Color(0xFFE5C890),
    red: Color(0xFFE78284),
    purple: Color(0xFFCA9EE6),
    ansi: MxAnsi(
      black: Color(0xFF51576D),
      red: Color(0xFFE78284),
      green: Color(0xFFA6D189),
      yellow: Color(0xFFE5C890),
      blue: Color(0xFF8CAAEE),
      magenta: Color(0xFFF4B8E4),
      cyan: Color(0xFF81C8BE),
      white: Color(0xFFB5BFE2),
      brightBlack: Color(0xFF626880),
      brightWhite: Color(0xFFA5ADCE),
    ),
  );

  static const catppuccinLatte = MxPalette(
    id: 'catppuccin-latte',
    label: 'Catppuccin Latte',
    dark: false,
    canvas: Color(0xFFDCE0E8),
    bg: Color(0xFFEFF1F5),
    bgSidebar: Color(0xFFE6E9EF),
    bgHover: Color(0xFFCCD0DA),
    bgActive: Color(0xFFBCC0CC),
    border: Color(0xFFCCD0DA),
    fg: Color(0xFF4C4F69),
    fgDim: Color(0xFF6C6F85),
    fgFaint: Color(0xFF9CA0B0),
    accent: Color(0xFF1E66F5),
    green: Color(0xFF40A02B),
    yellow: Color(0xFFDF8E1D),
    red: Color(0xFFD20F39),
    purple: Color(0xFF8839EF),
    ansi: MxAnsi(
      black: Color(0xFF5C5F77),
      red: Color(0xFFD20F39),
      green: Color(0xFF40A02B),
      yellow: Color(0xFFDF8E1D),
      blue: Color(0xFF1E66F5),
      magenta: Color(0xFFEA76CB),
      cyan: Color(0xFF179299),
      white: Color(0xFFACB0BE),
      brightBlack: Color(0xFF6C6F85),
      brightWhite: Color(0xFFBCC0CC),
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

  static const tokyoNight = MxPalette(
    id: 'tokyo-night',
    label: 'Tokyo Night',
    dark: true,
    canvas: Color(0xFF13141F),
    bg: Color(0xFF1A1B26),
    bgSidebar: Color(0xFF16161E),
    bgHover: Color(0xFF292E42),
    bgActive: Color(0xFF343B58),
    border: Color(0xFF292E42),
    fg: Color(0xFFC0CAF5),
    fgDim: Color(0xFF9AA5CE),
    fgFaint: Color(0xFF565F89),
    accent: Color(0xFF7AA2F7),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    red: Color(0xFFF7768E),
    purple: Color(0xFFBB9AF7),
    ansi: MxAnsi(
      black: Color(0xFF414868),
      red: Color(0xFFF7768E),
      green: Color(0xFF9ECE6A),
      yellow: Color(0xFFE0AF68),
      blue: Color(0xFF7AA2F7),
      magenta: Color(0xFFBB9AF7),
      cyan: Color(0xFF7DCFFF),
      white: Color(0xFFA9B1D6),
      brightBlack: Color(0xFF565F89),
      brightWhite: Color(0xFFC0CAF5),
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

  static const rosePine = MxPalette(
    id: 'rose-pine',
    label: 'Rosé Pine',
    dark: true,
    canvas: Color(0xFF121016),
    bg: Color(0xFF1F1D2E),
    bgSidebar: Color(0xFF191724),
    bgHover: Color(0xFF26233A),
    bgActive: Color(0xFF403D52),
    border: Color(0xFF26233A),
    fg: Color(0xFFE0DEF4),
    fgDim: Color(0xFF908CAA),
    fgFaint: Color(0xFF6E6A86),
    accent: Color(0xFFC4A7E7),
    green: Color(0xFF9CCFD8),
    yellow: Color(0xFFF6C177),
    red: Color(0xFFEB6F92),
    purple: Color(0xFFEBBCBA),
    ansi: MxAnsi(
      black: Color(0xFF26233A),
      red: Color(0xFFEB6F92),
      green: Color(0xFF31748F),
      yellow: Color(0xFFF6C177),
      blue: Color(0xFF9CCFD8),
      magenta: Color(0xFFC4A7E7),
      cyan: Color(0xFFEBBCBA),
      white: Color(0xFFE0DEF4),
      brightBlack: Color(0xFF6E6A86),
      brightWhite: Color(0xFFE0DEF4),
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
  /// refused here too: black stays a dark, as it does in [catppuccinLatte].
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

  /// ChatGPT. The one window here with no hue in it at all: every grey is
  /// r == g == b, which is what makes it read as grey rather than as a very
  /// dark blue — the trap every other dark theme in this set falls into.
  ///
  /// Same caveat as [claudeDark]: the greys are the app's, the ansi half is
  /// derived. It is deliberately the flat, saturated set a modern web app
  /// would use, because a muted one disappears against a neutral background.
  static const chatgptDark = MxPalette(
    id: 'chatgpt-dark',
    label: 'ChatGPT Dark',
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

  /// Zenburn. The lightest window in the set by a clear margin — an olive-grey
  /// panel where everything else is a near-black one — and the only theme here
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
    everforest,
    tokyoNight,
    gruvbox,
    solarizedDark,
    catppuccinMocha,
    chatgptDark,
    monokaiPro,
    nord,
    dracula,
    catppuccinMacchiato,
    rosePine,
    zenburn,
    catppuccinFrappe,
    githubLight,
    catppuccinLatte,
    rosePineDawn,
    gruvboxLight,
  ];

  /// An id from a config file written by a newer build — or by a hand — is not
  /// a reason to fail to start: fall back to the default.
  static MxPalette byId(String? id) => all.where((p) => p.id == id).firstOrNull ?? maestria;
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

  /// Anthropic's orange. Reserved for the Claude mark itself — a session's
  /// *state* is said by the badge on it, never by recolouring the logo — and
  /// so the one colour a theme does not get to touch.
  static const claude = Color(0xFFD97757);

  /// The one monospace in the app: the pty and every mono label around it —
  /// the pane header, the result strip, a branch name in the sidebar. Two
  /// different monos inside the same card read as a bug, so there is one.
  ///
  /// Hack, bundled (see `pubspec.yaml`). Its advance is 1233/2048 em, the same
  /// as Menlo's, so nothing that used to fit stopped fitting.
  static const mono = 'Hack';

  /// The pty's own text, Warp's defaults: 13px on a 1.2 line. Bigger than the
  /// 12.5 the panes used to be, and the extra leading is what makes a wall of
  /// tool output scannable instead of a block.
  static const terminalFontSize = 13.0;
  static const terminalLineHeight = 1.2;

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
    );
  }
}
