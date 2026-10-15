import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rfw/rfw.dart';

import '../services/plugins.dart';
import '../theme.dart';
import 'plugin_pane.dart' show pluginIcon;

/// O `TextInput` de `import maestria;`: um campo de texto numa janela de widgets
/// -- o chat de um plugin, uma busca.
///
/// O rfw só tem o que mostra, nada que se digita. O texto mora aqui na janela,
/// por `id` (como o buffer do `CodeEditor`), e o plugin só o recebe quando você
/// manda: o enter (ou o botão de enviar) dispara o `onSubmit` com o `text`. O
/// shift+enter, num campo de várias linhas, quebra a linha.
///
/// ```
/// TextInput(
///   id: "chat", placeholder: "fale com ele…", multiline: true,
///   clear: data.chat.sent, sendIcon: "send", autofocus: true,
///   onSubmit: event "send" {},
/// )
/// ```
///
/// - **`clear`**: um número do plugin. Quando ele muda, o campo se esvazia -- o
///   plugin aumenta depois de aceitar o que foi mandado (e não esvazia se a
///   mensagem não pôde ir).
/// - **`value`** só é lido quando o `id` aparece pela primeira vez.
/// - **`disabled`** trava o campo e o botão; `hint` aparece no lugar do
///   `placeholder` enquanto isso (o "responda no terminal").
/// - **`sendIcon`** põe um botão de ícone na ponta do campo que faz o mesmo que
///   o enter.
/// - **`onPasteImage`**: o ⌘V com uma imagem na área de transferência (um print)
///   não tem o que colar num campo de texto -- avisa o plugin, que decide o que
///   fazer com ela (no chat do escritório, o `terminal.pasteClipboard` a entrega
///   ao claude). Texto continua colando como sempre.
/// - **`allowEmpty`**: o enter manda mesmo com o campo vazio (`text: ""`) -- a
///   imagem colada que vai sozinha.
/// - **`onArrow`**: com o campo vazio, a seta pra cima ou pra baixo vai pro
///   plugin (`key: "up"` ou `"down"`) em vez de mexer no cursor -- andar pelas
///   opções de uma pergunta, como no terminal. Com texto, a seta é do campo.
/// - **`commands`**: `[{ name, description? }]`, os comandos de barra do que
///   está do outro lado (o `/compact` de um claude). Com o campo começando por
///   `/` e ainda sem espaço, a lista dos que combinam abre em cima dele, como no
///   terminal: as setas andam, o tab completa, o enter manda o escolhido e o
///   esc fecha. O plugin não fica sabendo de nada até o enter -- o filtro é aqui.
Widget buildPluginTextInput(PluginView view, DataSource source) {
  final id = source.v<String>(['id']) ?? '';
  int? i(String k) => source.v<int>([k]) ?? source.v<double>([k])?.round();
  return PluginTextInput(
    key: ValueKey('text-input:$id'),
    view: view,
    id: id,
    value: source.v<String>(['value']),
    placeholder: source.v<String>(['placeholder']),
    hint: source.v<String>(['hint']),
    multiline: source.v<bool>(['multiline']) == true,
    maxLines: i('maxLines') ?? 6,
    autofocus: source.v<bool>(['autofocus']) == true,
    disabled: source.v<bool>(['disabled']) == true,
    clear: i('clear'),
    sendIcon: source.v<String>(['sendIcon']),
    fontSize: source.v<double>(['fontSize']) ?? 13,
    allowEmpty: source.v<bool>(['allowEmpty']) == true,
    commands: [
      for (var k = 0; k < source.length(['commands']); k++)
        if (source.v<String>(['commands', k, 'name']) case final name? when name.trim().isNotEmpty)
          (
            name: name.trim().replaceFirst(RegExp(r'^/'), ''),
            description: source.v<String>(['commands', k, 'description']) ?? '',
          ),
    ],
    onSubmit: source.handler<void Function(DynamicMap)>(
      ['onSubmit'],
      (trigger) =>
          (extra) => trigger(extra),
    ),
    onPasteImage: source.handler<void Function(DynamicMap)>(
      ['onPasteImage'],
      (trigger) =>
          (extra) => trigger(extra),
    ),
    onArrow: source.handler<void Function(DynamicMap)>(
      ['onArrow'],
      (trigger) =>
          (extra) => trigger(extra),
    ),
  );
}

/// Um comando de barra do `commands`, sem a barra.
typedef SlashCommand = ({String name, String description});

/// Quantos comandos a lista mostra de uma vez.
const _shownCommands = 8;

final Expando<Map<String, TextEditingController>> _texts = Expando('rfw text inputs');

/// O texto de cada `TextInput` de [view], por `id`.
Map<String, TextEditingController> textInputsOf(PluginView view) => _texts[view] ??= {};

class PluginTextInput extends StatefulWidget {
  const PluginTextInput({
    super.key,
    required this.view,
    required this.id,
    this.value,
    this.placeholder,
    this.hint,
    this.multiline = false,
    this.maxLines = 6,
    this.autofocus = false,
    this.disabled = false,
    this.clear,
    this.sendIcon,
    this.fontSize = 13,
    this.allowEmpty = false,
    this.commands = const [],
    this.onSubmit,
    this.onPasteImage,
    this.onArrow,
  });

  final PluginView view;
  final String id;
  final String? value;
  final String? placeholder;
  final String? hint;
  final bool multiline;
  final int maxLines;
  final bool autofocus;
  final bool disabled;
  final int? clear;
  final String? sendIcon;
  final double fontSize;
  final bool allowEmpty;
  final List<SlashCommand> commands;
  final void Function(DynamicMap)? onSubmit;
  final void Function(DynamicMap)? onPasteImage;
  final void Function(DynamicMap)? onArrow;

  @override
  State<PluginTextInput> createState() => _PluginTextInputState();
}

/// O `clear` que cada campo já viu, pra só esvaziar quando ele muda.
final Expando<Map<String, int?>> _cleared = Expando('rfw text input clears');

class _PluginTextInputState extends State<PluginTextInput> {
  final FocusNode _focus = FocusNode();

  TextEditingController get _controller =>
      textInputsOf(widget.view).putIfAbsent(widget.id, () => TextEditingController(text: widget.value ?? ''));

  /// A linha em destaque na lista de comandos.
  int _pick = 0;

  /// O texto em que o esc fechou a lista: ela volta quando ele muda.
  String? _dismissed;

  @override
  void initState() {
    super.initState();
    _seen();
    _controller.addListener(_typed);
  }

  @override
  void didUpdateWidget(PluginTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    _seen();
  }

  void _typed() {
    if (!mounted) return;
    setState(() => _pick = 0);
  }

  /// Os comandos que combinam com o que foi digitado: os que começam com ele
  /// primeiro, depois os que o têm no meio. Vazia sem `/` no começo, com
  /// espaço (já são os argumentos) ou depois do esc.
  List<SlashCommand> get _matches {
    final text = _controller.text;
    if (widget.commands.isEmpty || widget.disabled || _dismissed == text) return const [];
    final m = RegExp(r'^/(\S*)$').firstMatch(text);
    if (m == null) return const [];
    final q = m.group(1)!.toLowerCase();
    final starts = <SlashCommand>[];
    final inside = <SlashCommand>[];
    for (final c in widget.commands) {
      final name = c.name.toLowerCase();
      if (name.startsWith(q)) {
        starts.add(c);
      } else if (name.contains(q)) {
        inside.add(c);
      }
    }
    return [...starts, ...inside].take(_shownCommands).toList();
  }

  /// Põe [c] no campo, com o espaço dos argumentos.
  void _complete(SlashCommand c) {
    _controller.value = TextEditingValue(
      text: '/${c.name} ',
      selection: TextSelection.collapsed(offset: c.name.length + 2),
    );
    _focus.requestFocus();
  }

  /// Esvazia o campo quando o `clear` do plugin mudou desde a última vez.
  void _seen() {
    final seen = _cleared[widget.view] ??= {};
    if (seen.containsKey(widget.id) && seen[widget.id] != widget.clear) _controller.clear();
    seen[widget.id] = widget.clear;
  }

  @override
  void dispose() {
    _controller.removeListener(_typed);
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.disabled) return;
    final text = _controller.text.trim();
    if (text.isEmpty && !widget.allowEmpty) return;
    widget.onSubmit?.call(<String, Object?>{'text': text, 'id': widget.id});
  }

  /// O ⌘V: texto entra no campo; sem texto (um print), o plugin fica sabendo.
  Future<void> _paste() async {
    if (widget.disabled) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    if (text != null && text.isNotEmpty) {
      final c = _controller;
      final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
      c.value = TextEditingValue(
        text: c.text.replaceRange(sel.start, sel.end, text),
        selection: TextSelection.collapsed(offset: sel.start + text.length),
      );
      return;
    }
    widget.onPasteImage?.call(<String, Object?>{'id': widget.id});
  }

  /// As teclas antes do campo: com a lista de comandos aberta, as setas, o tab,
  /// o enter e o esc são dela; senão, a seta com o campo vazio vai pro plugin
  /// que pediu (`onArrow`).
  KeyEventResult _arrow(FocusNode node, KeyEvent event) {
    final matches = event is KeyUpEvent ? const <SlashCommand>[] : _matches;
    if (matches.isNotEmpty) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        final step = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
        setState(() => _pick = (_pick.clamp(0, matches.length - 1) + step) % matches.length);
        return KeyEventResult.handled;
      }
      final chosen = matches[_pick.clamp(0, matches.length - 1)];
      if (key == LogicalKeyboardKey.tab) {
        _complete(chosen);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
        _controller.text = '/${chosen.name}';
        _submit();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => _dismissed = _controller.text);
        return KeyEventResult.handled;
      }
    }
    final onArrow = widget.onArrow;
    if (onArrow == null || widget.disabled || event is KeyUpEvent || _controller.text.isNotEmpty) {
      return KeyEventResult.ignored;
    }
    final key = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => 'up',
      LogicalKeyboardKey.arrowDown => 'down',
      _ => null,
    };
    if (key == null) return KeyEventResult.ignored;
    onArrow(<String, Object?>{'key': key, 'id': widget.id});
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final send = pluginIcon(widget.sendIcon);
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      enabled: !widget.disabled,
      minLines: 1,
      maxLines: widget.multiline ? widget.maxLines : 1,
      textInputAction: widget.multiline ? TextInputAction.newline : TextInputAction.send,
      onSubmitted: widget.multiline ? null : (_) => _submit(),
      style: TextStyle(fontSize: widget.fontSize, color: Mx.fg, height: 1.35),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: Mx.bgActive,
        hintText: widget.disabled ? (widget.hint ?? widget.placeholder) : widget.placeholder,
        hintStyle: TextStyle(color: Mx.fgFaint, fontSize: widget.fontSize - 0.5),
        contentPadding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Mx.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Mx.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Mx.accent, width: 1.4),
        ),
        suffixIcon: send == null
            ? null
            : IconButton(
                tooltip: 'enviar (enter)',
                iconSize: 17,
                onPressed: widget.disabled ? null : _submit,
                icon: Icon(send, color: widget.disabled ? Mx.fgFaint : Mx.accent),
              ),
      ),
    );
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final matches = _matches;
    final input = CallbackShortcuts(
      bindings: {
        // O enter manda; o shift+enter passa reto e o campo quebra a linha.
        if (widget.multiline) const SingleActivator(LogicalKeyboardKey.enter): _submit,
        // Só quem quer saber de imagem toma o ⌘V do campo.
        if (widget.onPasteImage != null)
          SingleActivator(LogicalKeyboardKey.keyV, meta: mac, control: !mac): _paste,
      },
      child: Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _arrow, child: field),
    );
    if (matches.isEmpty) return input;
    final pick = _pick.clamp(0, matches.length - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            border: Border.all(color: Mx.border),
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < matches.length; k++)
                _CommandRow(command: matches[k], on: k == pick, onTap: () => _complete(matches[k])),
            ],
          ),
        ),
        input,
      ],
    );
  }
}

/// Uma linha da lista de comandos: o `/nome` e o que ele faz.
class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command, required this.on, required this.onTap});

  final SlashCommand command;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: on ? Mx.bgActive : Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(7)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(7)),
          hoverColor: Mx.bgHover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
            child: Row(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 140),
                  child: Text(
                    '/${command.name}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: on ? Mx.accent : Mx.fg,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    command.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Mx.fgFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
