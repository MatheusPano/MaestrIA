import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
// --- ditado (vocalização) — fora desta versão --------------------------------
// Ver o cabeçalho de `services/dictation.dart`.
// import '../services/dictation.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'dialogs.dart';
import 'theme_gallery.dart';

/// As três metades da tela: como a janela se parece, o que o teclado faz, e o
/// que o + da lateral tem pra oferecer.
enum MxSection {
  appearance('aparência', Icons.palette_outlined),
  shortcuts('atalhos', Icons.keyboard_outlined),
  launchers('programas', Icons.rocket_launch_outlined);
  // --- ditado (vocalização) — fora desta versão -------------------------------
  // A quarta seção era o microfone. Ver o cabeçalho de
  // `services/dictation.dart`; quando ela voltar, o `;` acima vira `,` de novo.
  // dictation('ditado', Icons.mic_none_outlined);

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
    return AnimatedBuilder(
      // Rotas guardam a página que construíram, então o diálogo continuaria
      // nas cores — e no corpo — velhos enquanto o app atrás dele muda.
      animation: Mx.chrome,
      builder: (context, _) => AnimatedBuilder(
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
                              MxSection.launchers => _Launchers(store: widget.store),
                              // --- ditado (vocalização) — fora desta versão ---
                              // MxSection.dictation => _Dictation(store: widget.store),
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
        const SizedBox(height: 26),
        _Typography(store: store),
      ],
    );
  }
}

/// A tipografia do pty: a face, o corpo e a entrelinha.
///
/// Fica embaixo do tema e não numa seção própria porque é a mesma pergunta que
/// a galeria faz — como o terminal se parece —, e porque as duas se respondem
/// olhando: a amostra aqui é o pty escrito nas cores do tema que acabou de ser
/// escolhido logo acima.
class _Typography extends StatelessWidget {
  const _Typography({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final type = Mx.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Heading(
                'tipografia do pty',
                hint: 'vale pra todo painel. ⌘= e ⌘− mexem em um só, a partir '
                    'daqui — e o painel lembra o que você deixou.',
              ),
            ),
            if (type != MxType.standard)
              TextButton(
                onPressed: () => store.setTypography(MxType.standard),
                child: const Text('restaurar padrões', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
        _Sample(type: type),
        const SizedBox(height: 14),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final face in MxFaces.installed)
              _FaceChip(
                face: face,
                selected: face.family == type.mono,
                onTap: () => store.setTypography(type.copyWith(mono: face.family)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // Um nome que não existe na máquina não some calado: a face cai na
          // proporcional do sistema e o terminal desalinha inteiro. Por isso a
          // lista é medida antes de ser desenhada — ver [MxFaces.resolves].
          'só as que existem nesta máquina; a Hack vem no app',
          style: TextStyle(fontSize: 11, color: Mx.fgFaint),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _Stepper(
              label: 'corpo',
              // Sem decimal quando não há decimal, e com um quando um config
              // editado à mão trouxe 13.5: o número aqui é pra ser exato.
              value: type.size.toStringAsFixed(type.size == type.size.roundToDouble() ? 0 : 1),
              unit: 'px',
              onLess: type.size > MxType.minSize
                  ? () => store.setTypography(type.copyWith(size: type.size - MxType.sizeStep))
                  : null,
              onMore: type.size < MxType.maxSize
                  ? () => store.setTypography(type.copyWith(size: type.size + MxType.sizeStep))
                  : null,
            ),
            const SizedBox(width: 12),
            _Stepper(
              label: 'entrelinha',
              value: type.line.toStringAsFixed(2),
              onLess: type.line > MxType.minLine
                  ? () => store.setTypography(type.copyWith(line: type.line - MxType.lineStep))
                  : null,
              onMore: type.line < MxType.maxLine
                  ? () => store.setTypography(type.copyWith(line: type.line + MxType.lineStep))
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// O pty, escrito como ele vai ficar.
///
/// Três linhas e não uma: a entrelinha é a distância *entre* linhas, e uma
/// amostra de uma linha só seria a única escolha aqui que não dá pra ver.
class _Sample extends StatelessWidget {
  const _Sample({required this.type});

  final MxType type;

  @override
  Widget build(BuildContext context) {
    final term = Mx.terminal;
    final style = TextStyle(
      fontFamily: type.mono,
      fontSize: type.size,
      height: type.line,
      color: term.foreground,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: term.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: r'$ ', style: style.copyWith(color: term.brightBlack)),
                TextSpan(text: 'git', style: style.copyWith(color: term.green)),
                const TextSpan(text: ' status --short'),
              ],
            ),
            style: style,
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: ' M ', style: style.copyWith(color: term.yellow)),
                const TextSpan(text: 'lib/ui/settings.dart'),
              ],
            ),
            style: style,
          ),
          Text('?? Il1 O0 — {} => (i:M)', style: style.copyWith(color: term.brightBlack)),
        ],
      ),
    );
  }
}

/// Uma face, escrita nela mesma.
///
/// O nome de uma monoespaçada não diz nada sobre ela; a forma do `g` e do `1`
/// diz tudo. Então o rótulo do chip *é* o preview.
class _FaceChip extends StatefulWidget {
  const _FaceChip({required this.face, required this.selected, required this.onTap});

  final MxFace face;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FaceChip> createState() => _FaceChipState();
}

class _FaceChipState extends State<_FaceChip> {
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected ? Mx.bgActive : (_hover ? Mx.bgHover : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: widget.selected ? Mx.accent : Mx.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.face.family,
                style: TextStyle(
                  fontFamily: widget.face.family,
                  fontSize: 12,
                  color: lit ? Mx.fg : Mx.fgDim,
                ),
              ),
              if (widget.face.note case final note?) ...[
                const SizedBox(width: 6),
                Text(note, style: TextStyle(fontSize: 10.5, color: Mx.fgFaint)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `−  13px  +`. Um número que só anda de um passo por vez não precisa de
/// campo de texto, e um slider erraria o valor que a pessoa quer.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onLess,
    required this.onMore,
    this.unit = '',
  });

  final String label;
  final String value;
  final String unit;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: Mx.bg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Mx.border),
          ),
          child: Row(
            children: [
              _Ghost(icon: Icons.remove, tooltip: 'menos', onTap: onLess),
              SizedBox(
                width: 58,
                child: Text(
                  '$value$unit',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: Mx.mono, fontSize: 12, color: Mx.fg),
                ),
              ),
              _Ghost(icon: Icons.add, tooltip: 'mais', onTap: onMore),
            ],
          ),
        ),
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

  /// Null é o fim de curso de um [_Stepper]: o botão continua no lugar,
  /// apagado. Tirá-lo faria o número pular de lado ao chegar no limite.
  final VoidCallback? onTap;

  @override
  State<_Ghost> createState() => _GhostState();
}

class _GhostState extends State<_Ghost> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final off = widget.onTap == null;
    final lit = _hover && !off;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: off ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: lit ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: lit ? Mx.border : Colors.transparent),
            ),
            child: Icon(
              widget.icon,
              size: 13,
              color: off ? Mx.border : (lit ? Mx.fg : Mx.fgFaint),
            ),
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

/// Os programas do usuário: a lista, e os gestos que mexem nela.
///
/// Uma seção própria e não um canto da aparência porque o que se responde aqui
/// não é como a janela se parece -- é o que o + da lateral oferece. É a única
/// tela do app em que se acrescenta um jeito novo de abrir painel.
class _Launchers extends StatelessWidget {
  const _Launchers({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(
          'programas',
          hint: 'um painel que já abre dentro de um comando — é o que a sessão '
              'do claude sempre foi, com o comando vindo daqui. cada um vira '
              'uma linha no + da lateral, e volta rodando quando o app reabre.',
        ),
        if (store.launchers.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            decoration: BoxDecoration(
              color: Mx.bg,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Mx.border),
            ),
            child: Text(
              'nenhum ainda. um `btop` aqui é um painel de monitor a um clique '
              'de distância; um `npm run dev` é o servidor do projeto sempre '
              'no mesmo lugar.',
              style: TextStyle(fontSize: 12, color: Mx.fgFaint, height: 1.5),
            ),
          ),
        for (final launcher in store.launchers)
          _LauncherRow(store: store, launcher: launcher),
        const SizedBox(height: 12),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 15),
          label: const Text('novo programa…'),
          onPressed: () => showNewLauncher(context, store),
        ),
      ],
    );
  }
}

class _LauncherRow extends StatefulWidget {
  const _LauncherRow({required this.store, required this.launcher});

  final AppStore store;
  final Launcher launcher;

  @override
  State<_LauncherRow> createState() => _LauncherRowState();
}

class _LauncherRowState extends State<_LauncherRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final launcher = widget.launcher;
    // Quantos painéis abertos são deste programa: é o que faz "apagar" uma
    // decisão informada, e não uma surpresa três painéis adiante.
    final open = widget.store.tabs.where((t) => t.launcher == launcher).length;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _hover ? Mx.bgHover : Mx.bg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Mx.border),
        ),
        child: Row(
          children: [
            Icon(launcher.icon.glyph, size: 17, color: launcher.color),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    launcher.name,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    launcher.command,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, fontFamily: Mx.mono, color: Mx.fgDim),
                  ),
                ],
              ),
            ),
            if (open > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  open == 1 ? '1 painel aberto' : '$open painéis abertos',
                  style: TextStyle(fontSize: 11, color: Mx.fgFaint),
                ),
              ),
            IconButton(
              tooltip: 'editar',
              iconSize: 15,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: () => showEditLauncher(context, widget.store, launcher),
              icon: Icon(Icons.edit_outlined, color: Mx.fgDim),
            ),
            IconButton(
              // Os painéis não vão junto: apagar o programa é esquecer o
              // atalho, não matar o que está rodando. Ver
              // [AppStore.removeLauncher].
              tooltip: open == 0
                  ? 'apagar'
                  : 'apagar — os $open painéis continuam abertos, como terminais',
              iconSize: 15,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: () => widget.store.removeLauncher(launcher),
              icon: Icon(Icons.close, color: Mx.fgDim),
            ),
          ],
        ),
      ),
    );
  }
}

// --- ditado (vocalização) — fora desta versão --------------------------------
// Ver o cabeçalho de `services/dictation.dart`. Daqui até o fim do arquivo é
// a seção do ditado: o bloco de setup, os campos, e os três widgets que só
// ela usa (`_Setup`, `_Command` e `_Line`).

/*
/// O microfone: o que ele precisa pra funcionar, e o que ele faz com o texto.
///
/// Uma seção própria porque quase tudo aqui é setup, e setup é a única coisa
/// nesta tela que pode estar *errada* -- as outras três só têm preferências.
/// Daí o bloco de cima, que não pergunta nada: ele responde "por que o ⌘⇧D não
/// faz nada", que é a pergunta que traz alguém aqui.
class _Dictation extends StatefulWidget {
  const _Dictation({required this.store});

  final AppStore store;

  @override
  State<_Dictation> createState() => _DictationState();
}

class _DictationState extends State<_Dictation> {
  late final _bin = TextEditingController(text: widget.store.dictation.config.bin);
  late final _model = TextEditingController(text: widget.store.dictation.config.model);
  late final _lang = TextEditingController(text: widget.store.dictation.config.lang);
  late final _prompt = TextEditingController(text: widget.store.dictation.config.prompt);

  /// O que a máquina tem, relido a cada vez que a seção abre -- e depois só a
  /// pedido. É uma resposta que muda por fora do app: quem sai daqui pra rodar
  /// o `brew install` volta pra clicar em "verificar de novo".
  String? _missing;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _bin.dispose();
    _model.dispose();
    _lang.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final missing = await widget.store.dictation.problem();
    if (mounted) {
      setState(() {
        _missing = missing;
        _checking = false;
      });
    }
  }

  /// Guarda e reconfere: trocar o caminho do modelo é justamente o gesto de
  /// quem está tentando resolver o que o bloco de cima está apontando.
  void _apply(DictationConfig config) {
    widget.store.setDictation(config);
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.store.dictation.config;
    final chord = widget.store.keymap[MxAction.dictate].firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(
          'ditado',
          hint: 'falar em vez de digitar: o microfone abre, o whisper.cpp '
              'transcreve na sua máquina, e o texto é colado no prompt do '
              'painel — sem sair daqui e sem mandar áudio pra lugar nenhum. '
              '${chord == null ? 'sem atalho — escolha um em atalhos.' : '${chord.label} liga e desliga.'}',
        ),
        _Setup(
          missing: _missing,
          checking: _checking,
          model: config.model,
          onRecheck: _check,
        ),
        const SizedBox(height: 22),
        _Line(
          label: 'binário',
          hint: 'o nome no PATH basta — o app roda tudo por um login shell',
          controller: _bin,
          onChanged: (v) => _apply(config.copyWith(bin: v)),
        ),
        _Line(
          label: 'modelo',
          hint: 'o .bin do whisper.cpp. large-v3-turbo é o que vale a pena: '
              'roda em Metal e transcreve mais rápido do que se fala',
          controller: _model,
          onChanged: (v) => _apply(config.copyWith(model: v)),
        ),
        _Line(
          label: 'idioma',
          hint: 'fixo, não `auto`: numa frase em português com nome de branch '
              'no meio, o detector escolhe inglês e traduz a frase inteira',
          controller: _lang,
          width: 90,
          onChanged: (v) => _apply(config.copyWith(lang: v)),
        ),
        _Line(
          label: 'vocabulário',
          hint: 'não é uma instrução: é um trecho que o whisper finge ter '
              'acabado de transcrever, e que por isso enviesa o que ele '
              'escuta. É o que faz "worktree" e "BUG#45902" saírem inteiros em '
              'vez de "UASC Trade" e "Bag 45902". Vazio, é o whisper cru.',
          controller: _prompt,
          lines: 3,
          onChanged: (v) => _apply(config.copyWith(prompt: v)),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          value: config.submit,
          onChanged: (v) => _apply(config.copyWith(submit: v)),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            'enviar sozinho ao terminar de falar',
            style: TextStyle(fontSize: 12.5, color: Mx.fg),
          ),
          subtitle: Text(
            'desligado, o texto só é colado e você confere antes do enter — '
            'que é o que vale a pena enquanto você não confia no microfone: '
            'nome de arquivo e nome de branch são o que ele mais erra.',
            style: TextStyle(fontSize: 11.5, color: Mx.fgFaint, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// O que falta pra ditar, e como resolver -- ou o verde de que não falta nada.
class _Setup extends StatelessWidget {
  const _Setup({
    required this.missing,
    required this.checking,
    required this.model,
    required this.onRecheck,
  });

  final String? missing;
  final bool checking;
  final String model;
  final VoidCallback onRecheck;

  /// Os dois comandos do setup, o segundo montado em cima do caminho que está
  /// configurado -- copiar um comando que baixa pra outro lugar seria pior do
  /// que não oferecer comando nenhum.
  List<(String, String)> get _steps => [
    ('o whisper.cpp', 'brew install whisper-cpp'),
    (
      'o modelo (1,6 GB, uma vez)',
      'mkdir -p ${_dir(model)} && curl -L -o $model '
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin',
    ),
  ];

  static String _dir(String path) {
    final cut = path.lastIndexOf('/');
    return cut <= 0 ? '.' : path.substring(0, cut);
  }

  @override
  Widget build(BuildContext context) {
    final ok = missing == null && !checking;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 13),
      decoration: BoxDecoration(
        color: Mx.bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: ok ? Mx.green.withValues(alpha: 0.4) : Mx.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                checking ? Icons.hourglass_empty : (ok ? Icons.check_circle : Icons.error_outline),
                size: 14,
                color: checking ? Mx.fgFaint : (ok ? Mx.green : Mx.yellow),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  checking ? 'conferindo…' : (missing ?? 'tudo no lugar — é só falar'),
                  style: TextStyle(fontSize: 12, color: ok ? Mx.green : Mx.fg, height: 1.35),
                ),
              ),
              TextButton(
                onPressed: checking ? null : onRecheck,
                child: const Text('verificar de novo'),
              ),
            ],
          ),
          // As instruções só enquanto elas resolvem alguma coisa: com o setup
          // pronto, esta seção é sobre preferências e mais nada.
          if (!ok && !checking) ...[
            const SizedBox(height: 6),
            for (final (what, command) in _steps) _Command(what: what, command: command),
          ],
        ],
      ),
    );
  }
}

/// Um passo do setup: o que ele instala, o comando, e o botão que o copia.
///
/// Copiar e não rodar: baixar 1,6 GB é uma decisão de quem está na
/// frente da máquina, e o terminal em que isso roda é o do usuário -- que está
/// a um painel de distância daqui.
class _Command extends StatefulWidget {
  const _Command({required this.what, required this.command});

  final String what;
  final String command;

  @override
  State<_Command> createState() => _CommandState();
}

class _CommandState extends State<_Command> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.what, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  widget.command,
                  style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgDim, height: 1.4),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: widget.command));
                  if (context.mounted) setState(() => _copied = true);
                },
                child: Text(_copied ? 'copiado' : 'copiar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Um campo desta seção: rótulo, o porquê dele, e a caixa.
class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.hint,
    required this.controller,
    required this.onChanged,
    this.width,
    this.lines = 1,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final double? width;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
          ),
          const SizedBox(height: 2),
          Text(hint, style: TextStyle(fontSize: 11.5, color: Mx.fgFaint, height: 1.35)),
          const SizedBox(height: 7),
          SizedBox(
            width: width,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              minLines: lines,
              maxLines: lines,
              style: TextStyle(fontFamily: Mx.mono, fontSize: 12, color: Mx.fg),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
    );
  }
}
*/
