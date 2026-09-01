# Hack

Hack v3.003 — https://github.com/source-foundry/Hack (release `v3.003`, `Hack-v3.003-ttf.zip`).

Licença: Hack Open Font License / MIT (Bitstream Vera Sans Mono e Hack modifications).
Redistribuir as `.ttf` dentro do app é permitido.

Declarada como `family: Hack` no `pubspec.yaml` e usada por `Mx.mono` (`lib/theme.dart`).
As quatro faces estão aqui porque a `TerminalStyle` do xterm pede negrito e itálico
reais — sem elas o Flutter sintetiza os dois, e o negrito de uma célula do pty fica
mais largo que a célula.
