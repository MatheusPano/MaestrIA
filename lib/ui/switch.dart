import 'package:flutter/material.dart';

import '../theme.dart';

/// O interruptor da janela: um trilho de 30×18 com a bolinha dentro.
///
/// O `Switch` do Material 3 tem 52×32 e não deixa o tema mudar o tamanho -- só
/// as cores --, então ao lado de um rótulo de 12.5 ele virava a coisa maior da
/// linha, e encolhido por um `FittedBox` ou um `Transform.scale` cada lugar
/// ficava de um tamanho. Este tem o tamanho de um controle de desktop e as
/// cores da paleta: aceso, o trilho é o acento; apagado, é um poço com a borda
/// dos painéis e a bolinha no cinza do texto apagado.
///
/// [onChanged] null deixa ele desligado: aparece pela metade e não responde.
class MxSwitch extends StatefulWidget {
  const MxSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  static const width = 30.0;
  static const height = 18.0;

  @override
  State<MxSwitch> createState() => _MxSwitchState();
}

class _MxSwitchState extends State<MxSwitch> {
  bool _hover = false;
  bool _focus = false;

  static const _inset = 2.0;
  static const _duration = Duration(milliseconds: 140);

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final on = widget.value;
    final enabled = widget.onChanged != null;
    // O mesmo critério do `onPrimary` do tema: numa paleta de acento claro a
    // bolinha branca sumia no trilho.
    final knobOn = Mx.accent.computeLuminance() > 0.5 ? Mx.canvas : Colors.white;
    final track = on
        ? (_hover ? Color.lerp(Mx.accent, Colors.white, 0.08)! : Mx.accent)
        : (_hover ? Mx.bgHover : Mx.bgActive);
    const knob = MxSwitch.height - 2 * _inset;
    return Semantics(
      toggled: on,
      enabled: enabled,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle())},
        child: GestureDetector(
          onTap: enabled ? _toggle : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: AnimatedContainer(
              duration: _duration,
              curve: Curves.easeOut,
              width: MxSwitch.width,
              height: MxSwitch.height,
              padding: const EdgeInsets.all(_inset - 1),
              decoration: BoxDecoration(
                color: track,
                borderRadius: BorderRadius.circular(MxSwitch.height / 2),
                // A borda fica nos dois estados, só muda de cor: sem ela o
                // trilho aceso era 2px maior que o apagado e a bolinha pulava.
                border: Border.all(color: on ? track : Mx.border),
                boxShadow: _focus
                    ? [BoxShadow(color: Mx.accent.withValues(alpha: 0.5), spreadRadius: 2)]
                    : null,
              ),
              child: AnimatedAlign(
                duration: _duration,
                curve: Curves.easeOut,
                alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: _duration,
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    color: on ? knobOn : Mx.fgDim,
                    shape: BoxShape.circle,
                    boxShadow: on
                        ? [BoxShadow(color: Mx.shadow, blurRadius: 2, offset: const Offset(0, 1))]
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
