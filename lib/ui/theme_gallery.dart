import 'package:flutter/material.dart';

import '../services/store.dart';
import '../theme.dart';

/// A galeria de temas: uma janelinha por paleta, clicável.
///
/// Picking is applying: o clique repinta a janela atrás do diálogo, que fica
/// aberto pra dois temas serem provados um atrás do outro. Não há OK pra
/// apertar nem preview em que ficar preso — quando você vê a escolha, ela já
/// está salva.
class ThemeGallery extends StatelessWidget {
  const ThemeGallery({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MxPalette>(
      // Rotas guardam a página que construíram, então o diálogo continuaria
      // nas cores velhas enquanto o app atrás dele muda. É isto que o repinta.
      valueListenable: Mx.current,
      builder: (context, palette, _) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final p in MxThemes.all)
            _Swatch(palette: p, selected: p.id == palette.id, onTap: () => store.setTheme(p)),
        ],
      ),
    );
  }
}

/// One theme, drawn as the window it makes.
///
/// A row of colour chips says which colours a theme has; it does not say what
/// the app looks like in it — the greys carry that, and they are exactly what
/// a chip row leaves out. So the swatch is a small maestria instead: canvas,
/// sidebar, pane, and the three status colours in the places they show up.
class _Swatch extends StatefulWidget {
  const _Swatch({required this.palette, required this.selected, required this.onTap});

  final MxPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Swatch> createState() => _SwatchState();
}

class _SwatchState extends State<_Swatch> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final lit = widget.selected || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 176,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                height: 104,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: p.canvas,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.selected ? Mx.accent : (lit ? Mx.fgFaint : Mx.border),
                    width: widget.selected ? 2 : 1,
                  ),
                ),
                child: _MiniWindow(p),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (widget.selected) ...[
                    Icon(Icons.check, size: 13, color: Mx.accent),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      p.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: widget.selected ? Mx.fg : Mx.fgDim,
                        fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (!p.dark) Icon(Icons.light_mode_outlined, size: 12, color: Mx.fgFaint),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The app in miniature: sidebar on the left, a pane on the right, a status
/// strip under both — the same three regions the real window has.
class _MiniWindow extends StatelessWidget {
  const _MiniWindow(this.p);

  final MxPalette p;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 52,
                child: _Card(
                  color: p.bgSidebar,
                  border: p.border,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(p.fg, 26),
                      _bar(p.fgDim, 34),
                      _bar(p.accent, 22),
                      _bar(p.fgFaint, 30),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _Card(
                  color: p.bg,
                  border: p.border,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // A prompt line, then output — in the pty's own colours,
                      // since those are half of what a theme is here.
                      Row(
                        children: [
                          _dot(p.green),
                          const SizedBox(width: 3),
                          _bar(p.ansi.blue, 30, pad: false),
                        ],
                      ),
                      _bar(p.fg, 44),
                      _bar(p.ansi.magenta, 24),
                      _bar(p.yellow, 34),
                      _bar(p.fgFaint, 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(
          height: 10,
          child: _Card(
            color: p.bgSidebar,
            border: p.border,
            child: Row(
              children: [
                _dot(p.green, 3),
                const SizedBox(width: 3),
                _bar(p.fgFaint, 18, pad: false, height: 2),
                const Spacer(),
                _dot(p.red, 3),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bar(Color color, double width, {bool pad = true, double height = 3}) => Padding(
    padding: EdgeInsets.only(top: pad ? 4 : 0),
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1.5)),
    ),
  );

  Widget _dot(Color color, [double size = 4]) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.color, required this.border, required this.child});

  final Color color;
  final Color border;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.hardEdge,
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: border, width: 0.5),
    ),
    child: child,
  );
}
