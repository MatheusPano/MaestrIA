import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'theme_gallery.dart';

/// As duas metades da tela: como a janela se parece, e o que o teclado faz.
enum MxSection {
  appearance('aparência', Icons.palette_outlined),
  shortcuts('atalhos', Icons.keyboard_outlined);

  const MxSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

bool _open = false;

/// A tela de configurações.
///
/// Aberta como diálogo e não como uma quinta região da janela porque é o que
/// ela é: um lugar em que você entra, mexe em duas coisas e sai. O barrier é
/// quase transparente pelo mesmo motivo de sempre — a janela atrás é o preview
/// do tema, e escurecê-la seria esconder justamente o que está sendo escolhido.
Future<void> showSettings(
  BuildContext context,
  AppStore store, {
  MxSection section = MxSection.appearance,
}) {
  // O atalho que abre esta tela continua valendo enquanto ela está aberta;
  // sem isto, segurar ⌘, empilharia diálogos idênticos. Quem baixa a bandeira
  // é o próprio widget ao sair de cena — um `whenComplete` na rota deixaria a
  // bandeira de pé se a árvore fosse embora sem a rota ser fechada.
  if (_open) return Future.value();
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x33000000),
    builder: (ctx) => _Settings(store: store, initial: section),
  );
}

class _Settings extends StatefulWidget {
  const _Settings({required this.store, required this.initial});

  final AppStore store;
  final MxSection initial;

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  late MxSection _section = widget.initial;

  @override
  void initState() {
    super.initState();
    _open = true;
  }

  @override
  void dispose() {
    _open = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MxPalette>(
      valueListenable: Mx.current,
      builder: (context, _, _) => AnimatedBuilder(
        animation: widget.store,
        builder: (context, _) => Dialog(
          backgroundColor: Mx.bgSidebar,
          insetPadding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800, maxHeight: 620),
            child: SizedBox(
              width: 800,
              height: 620,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Rail(
                    section: _section,
                    onPick: (s) => setState(() => _section = s),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
                            child: switch (_section) {
                              MxSection.appearance => _Appearance(store: widget.store),
                              MxSection.shortcuts => _Shortcuts(store: widget.store),
                            },
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: Mx.border)),
                          ),
                          child: Row(
                            children: [
                              // O que muda aqui já está salvo antes de você
                              // ler — o botão fecha, não confirma.
                              Text(
                                'tudo aqui vale na hora',
                                style: TextStyle(fontSize: 11, color: Mx.fgFaint),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('pronto'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A lateral do diálogo. A mesma ideia da lateral da janela: o que existe
/// fica à esquerda, o que está aberto fica à direita.
class _Rail extends StatelessWidget {
  const _Rail({required this.section, required this.onPick});

  final MxSection section;
  final ValueChanged<MxSection> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 184,
      decoration: BoxDecoration(
        color: Mx.bg,
        border: Border(right: BorderSide(color: Mx.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Text(
              'configurações',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Mx.fg),
            ),
          ),
          for (final s in MxSection.values)
            _RailItem(section: s, selected: s == section, onTap: () => onPick(s)),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({required this.section, required this.selected, required this.onTap});

  final MxSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.selected || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected ? Mx.bgActive : (_hover ? Mx.bgHover : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                widget.section.icon,
                size: 15,
                color: widget.selected ? Mx.accent : (lit ? Mx.fg : Mx.fgDim),
              ),
              const SizedBox(width: 9),
              Text(
                widget.section.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: lit ? Mx.fg : Mx.fgDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cabeçalho de bloco: o nome do que vem abaixo e a frase que explica.
class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Mx.fg)),
          if (hint != null) ...[
            const SizedBox(height: 3),
            Text(hint!, style: TextStyle(fontSize: 11.5, color: Mx.fgFaint, height: 1.35)),
          ],
        ],
      ),
    );
  }
}

class _Appearance extends StatelessWidget {
  const _Appearance({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(
          'tema',
          hint: 'clicar já aplica — a janela atrás deste diálogo é o preview, '
              'e o pty vai junto: a paleta pinta o scrollback, não só a moldura.',
        ),
        ThemeGallery(store: store),
      ],
    );
  }
}

/// A lista de atalhos, agrupada como o teclado é usado e não como o código é
/// escrito: o que abre sessão, o que anda entre elas, e o que é da janela.
class _Shortcuts extends StatefulWidget {
  const _Shortcuts({required this.store});

  final AppStore store;

  @override
  State<_Shortcuts> createState() => _ShortcutsState();
}

class _ShortcutsState extends State<_Shortcuts> {
  /// A ação esperando uma combinação, e a que vai ser substituída — null ali
  /// é "somando mais uma", e não "trocando esta".
  MxAction? _recording;
  MxChord? _replacing;

  /// Por que a última tecla não serviu. Fica visível até a próxima tentativa:
  /// gravar de novo sem explicação faria a tecla parecer não ter chegado.
  String? _rejected;

  void _record(MxAction action, {MxChord? replacing}) => setState(() {
    _recording = action;
    _replacing = replacing;
    _rejected = null;
  });

  void _stop() => setState(() {
    _recording = null;
    _replacing = null;
    _rejected = null;
  });

  void _captured(MxChord chord) {
    if (chord.rejection case final why?) {
      setState(() => _rejected = why);
      return;
    }
    widget.store.bindShortcut(_recording!, chord, replacing: _replacing);
    _stop();
  }

  @override
  Widget build(BuildContext context) {
    final keymap = widget.store.keymap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Heading(
                'atalhos',
                hint: 'clique numa tecla pra trocar, no + pra dar uma segunda '
                    'combinação à mesma ação. Uma tecla só tem um dono: dar a '
                    'outra ação tira de quem a tinha.',
              ),
            ),
            if (!keymap.allDefault)
              TextButton(
                onPressed: () {
                  _stop();
                  widget.store.resetShortcuts();
                },
                child: const Text('restaurar padrões', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
        for (final group in MxGroup.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 4),
            child: Text(
              group.label,
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600,
                color: Mx.fgFaint,
              ),
            ),
          ),
          for (final action in MxAction.values.where((a) => a.group == group))
            _Row(
              action: action,
              chords: keymap[action],
              store: widget.store,
              recording: _recording == action,
              replacing: _replacing,
              rejected: _recording == action ? _rejected : null,
              onRecord: (replacing) => _record(action, replacing: replacing),
              onCancel: _stop,
              onCaptured: _captured,
            ),
        ],
        const SizedBox(height: 18),
        const _Fixed(),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.action,
    required this.chords,
    required this.store,
    required this.recording,
    required this.replacing,
    required this.rejected,
    required this.onRecord,
    required this.onCancel,
    required this.onCaptured,
  });

  final MxAction action;
  final List<MxChord> chords;
  final AppStore store;
  final bool recording;
  final MxChord? replacing;
  final String? rejected;
  final ValueChanged<MxChord?> onRecord;
  final VoidCallback onCancel;
  final ValueChanged<MxChord> onCaptured;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: recording ? Mx.bgActive : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.label, style: TextStyle(fontSize: 12.5, color: Mx.fg)),
                if (action.hint != null) ...[
                  const SizedBox(height: 2),
                  Text(action.hint!, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                ],
                if (rejected != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.block, size: 11, color: Mx.yellow),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          rejected!,
                          style: TextStyle(fontSize: 11, color: Mx.yellow),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (recording && replacing == null)
            _Recorder(onCaptured: onCaptured, onCancel: onCancel)
          else
            // Um teto pra coluna das teclas. Sem ele o Row entrega largura
            // infinita ao Wrap, que então nunca quebra a linha: uma ação com
            // três combinações empurraria o próprio nome pra fora do diálogo.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final chord in chords)
                    if (recording && chord == replacing)
                      _Recorder(onCaptured: onCaptured, onCancel: onCancel)
                    else
                      _Cap(
                        chord: chord,
                        onTap: () => onRecord(chord),
                        // Nunca tirar a última: uma ação sem tecla nenhuma some
                        // do teclado sem deixar rastro na lista.
                        onRemove: chords.length > 1
                            ? () => store.unbindShortcut(action, chord)
                            : null,
                      ),
                  if (!recording)
                    _AddChord(
                      onTap: () => onRecord(null),
                      onReset: store.keymap.isDefault(action)
                          ? null
                          : () => store.resetShortcuts(action),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Uma combinação desenhada como a tecla que ela é.
class _Cap extends StatefulWidget {
  const _Cap({required this.chord, required this.onTap, required this.onRemove});

  final MxChord chord;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  State<_Cap> createState() => _CapState();
}

class _CapState extends State<_Cap> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: 'trocar',
          waitDuration: const Duration(milliseconds: 600),
          child: Container(
            height: 26,
            padding: const EdgeInsets.only(left: 9, right: 5),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Mx.bgActive,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _hover ? Mx.accent : Mx.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.chord.label,
                  style: TextStyle(
                    fontFamily: Mx.mono,
                    fontSize: 12,
                    color: _hover ? Mx.fg : Mx.fgDim,
                  ),
                ),
                SizedBox(
                  width: 18,
                  child: _hover && widget.onRemove != null
                      ? InkWell(
                          onTap: widget.onRemove,
                          child: Icon(Icons.close, size: 12, color: Mx.fgFaint),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O `+` no fim da linha, com o "voltar ao padrão" escondido ao lado dele —
/// só aparece quando há padrão pra voltar.
class _AddChord extends StatelessWidget {
  const _AddChord({required this.onTap, required this.onReset});

  final VoidCallback onTap;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onReset != null)
          _Ghost(icon: Icons.undo, tooltip: 'voltar ao padrão', onTap: onReset!),
        _Ghost(icon: Icons.add, tooltip: 'adicionar outra combinação', onTap: onTap),
      ],
    );
  }
}

class _Ghost extends StatefulWidget {
  const _Ghost({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_Ghost> createState() => _GhostState();
}

class _GhostState extends State<_Ghost> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _hover ? Mx.border : Colors.transparent),
            ),
            child: Icon(widget.icon, size: 13, color: _hover ? Mx.fg : Mx.fgFaint),
          ),
        ),
      ),
    );
  }
}

/// O campo que escuta o teclado.
///
/// Devolve `handled` em tudo enquanto está no ar: gravar um atalho é o único
/// momento em que a tecla não deve fazer o que ela faz — inclusive o ⏎ que
/// fecharia o diálogo e o ⇥ que mudaria o foco.
class _Recorder extends StatelessWidget {
  const _Recorder({required this.onCaptured, required this.onCancel});

  final ValueChanged<MxChord> onCaptured;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        final chord = MxChord.fromEvent(event);
        if (chord == null) return KeyEventResult.handled;
        // ⎋ sozinho desiste; com modificador, é um atalho como outro qualquer.
        if (chord.key == LogicalKeyboardKey.escape && !chord.meta && !chord.control && !chord.alt) {
          onCancel();
          return KeyEventResult.handled;
        }
        // Um ⌘ segurado ainda não é nada: a combinação chega quando a tecla
        // de verdade descer.
        if (MxChord.isModifier(chord.key)) return KeyEventResult.handled;
        onCaptured(chord);
        return KeyEventResult.handled;
      },
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Mx.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Mx.accent),
        ),
        child: Text(
          'pressione a combinação   ⎋ cancela',
          style: TextStyle(fontSize: 11, color: Mx.accent),
        ),
      ),
    );
  }
}

/// O que não é escolha.
///
/// Está aqui pelo mesmo motivo que o resto da lista: uma tecla que funciona e
/// não aparece em lugar nenhum é uma tecla que ninguém descobre. O que separa
/// estas das outras é que cada uma é a metade de um par (nove teclas, uma
/// régua) ou pertence a quem está embaixo — o pty e o macOS.
class _Fixed extends StatelessWidget {
  const _Fixed();

  @override
  Widget build(BuildContext context) {
    final fixed = <(String, String)>[
      ('⌘1 … ⌘9', 'ir pra enésima sessão da lateral'),
      ('⌘V', 'colar no painel — imagem inclusa, que o claude recebe como ^V'),
      ('⇧⏎', 'quebrar linha no prompt sem enviar'),
      ('⌃C', 'do processo, como em qualquer terminal'),
      ('⌘Q ⌘W ⌘H ⌘M', 'do macOS: sair, fechar, esconder, minimizar'),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: Mx.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'fixos',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: Mx.fgFaint,
            ),
          ),
          const SizedBox(height: 6),
          for (final (keys, what) in fixed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      keys,
                      style: TextStyle(fontFamily: Mx.mono, fontSize: 11.5, color: Mx.fgDim),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(what, style: TextStyle(fontSize: 11.5, color: Mx.fgFaint)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
