import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/elixir.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/haskell.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/r.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/vue.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:rfw/rfw.dart';

import '../services/plugins.dart';
import '../theme.dart';
import 'menus.dart';

/// O editor de código de um plugin: o `CodeEditor` de `import maestria;`.
///
/// Um campo de texto (o bloco `input`) serve pra uma mensagem de commit, não
/// pra um arquivo: sem cor de sintaxe, sem número de linha, sem buscar e
/// trocar, e lento a partir de umas mil linhas. Este é o `re_editor`, que
/// desenha só as linhas na tela, com as cores do tema da Maestria.
///
/// A divisão de trabalho:
///
/// - **o texto enquanto você digita é da janela.** Cada documento (`doc`) tem
///   um buffer -- o texto, o desfazer, o cursor e a rolagem -- preso à janela
///   e não ao widget: trocar de aba no plugin, ir pras sessões e voltar, nada
///   disso perde o que você escreveu;
/// - **o arquivo é do plugin.** Ele manda o texto (`text`) e recebe de volta o
///   que mudou (`onChange`, um pouco depois de você parar de digitar) e o ⌘S
///   (`onSave`, na hora), sempre com o texto inteiro. Gravar no disco, dizer
///   se está sujo e perguntar antes de fechar é com ele;
/// - **`revision` é como o plugin troca o texto de um buffer que já existe**:
///   o arquivo mudou no disco (o claude mexeu nele), reverter. Com a mesma
///   `revision`, o `text` só vale na primeira vez que o `doc` aparece -- o
///   plugin pode mandar os dados de novo sem apagar o que você digitou.
///
/// ```
/// CodeEditor(
///   doc: data.file.path, text: data.file.text, revision: data.file.rev,
///   language: "dart", line: data.file.line, jump: data.file.jump,
///   onChange: event "change" {}, onSave: event "save" {}, onCursor: event "cursor" {},
/// )
/// ```
Widget buildPluginCodeEditor(PluginView view, DataSource source) =>
    PluginCodeEditor(view: view, spec: _readSpec(source));

typedef CodeEditorSpec = ({
  String doc,
  String? text,
  int revision,
  String? language,
  bool readOnly,
  bool wordWrap,
  bool lineNumbers,
  bool autofocus,
  double fontSize,
  int? line,
  int? column,
  int jump,
  String? hint,
  void Function(DynamicMap)? onChange,
  void Function(DynamicMap)? onSave,
  void Function(DynamicMap)? onCursor,
});

// O rfw exige que a fonte seja lida no builder, e não depois, no build de um
// filho: tudo o que o editor vai usar sai daqui de uma vez.
CodeEditorSpec _readSpec(DataSource s) {
  void Function(DynamicMap)? handler(String name) => s.handler<void Function(DynamicMap)>(
    [name],
    (trigger) =>
        (extra) => trigger(extra),
  );
  return (
    doc: s.v<String>(['doc']) ?? '',
    text: s.v<String>(['text']),
    revision: s.v<int>(['revision']) ?? 0,
    language: s.v<String>(['language']),
    readOnly: s.v<bool>(['readOnly']) == true,
    wordWrap: s.v<bool>(['wordWrap']) == true,
    lineNumbers: s.v<bool>(['lineNumbers']) != false,
    autofocus: s.v<bool>(['autofocus']) != false,
    // Num `data` do plugin, um 13.0 chega pelo json como o inteiro 13: o
    // tamanho da letra é a configuração do plugin, e vem de lá.
    fontSize: s.v<double>(['fontSize']) ?? s.v<int>(['fontSize'])?.toDouble() ?? 13,
    line: s.v<int>(['line']),
    column: s.v<int>(['column']),
    jump: s.v<int>(['jump']) ?? 0,
    hint: s.v<String>(['hint']),
    onChange: handler('onChange'),
    onSave: handler('onSave'),
    onCursor: handler('onCursor'),
  );
}

/// O que sobrevive ao widget: um por documento, por janela.
class EditorBuffer {
  EditorBuffer(String text, this.revision) : controller = CodeLineEditingController.fromText(text) {
    sent = controller.codeLines;
  }

  final CodeLineEditingController controller;

  /// A `revision` do plugin que este texto atende.
  int revision;

  /// O último `jump` atendido: um número novo é "vá pra `line`".
  int? jump;

  /// O texto que o plugin já conhece -- o que veio dele ou o último que foi
  /// pra ele. Comparado por identidade: o `re_editor` troca o objeto das linhas
  /// quando o texto muda, e não quando só o cursor anda.
  CodeLines? sent;

  double top = 0;
  double left = 0;
}

/// Os buffers de cada janela. Presos à [PluginView], que vive enquanto a
/// janela está aberta, e não ao estado do widget, que o Flutter desmonta
/// quando o painel sai da tela.
final Expando<Map<String, EditorBuffer>> _buffers = Expando('editor buffers');

Map<String, EditorBuffer> editorBuffersOf(PluginView view) => _buffers[view] ??= {};

class PluginCodeEditor extends StatefulWidget {
  const PluginCodeEditor({super.key, required this.view, required this.spec});

  final PluginView view;
  final CodeEditorSpec spec;

  @override
  State<PluginCodeEditor> createState() => _PluginCodeEditorState();
}

class _PluginCodeEditorState extends State<PluginCodeEditor> {
  /// Quanto esperar você parar de digitar antes de mandar o texto: o bastante
  /// pra uma palavra não virar dez mensagens, pouco pra o plugin não ficar
  /// atrás de quem fecha a aba logo depois de escrever.
  static const _settle = Duration(milliseconds: 350);

  final FocusNode _focus = FocusNode(debugLabel: 'plugin editor');
  late EditorBuffer _buffer;
  late CodeScrollController _scroll;
  late CodeFindController _find;
  Timer? _changeTimer;
  Timer? _cursorTimer;
  CodeLineSelection? _lastSelection;

  CodeEditorSpec get _spec => widget.spec;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(PluginCodeEditor old) {
    super.didUpdateWidget(old);
    if (old.spec.doc != _spec.doc || !identical(old.view, widget.view)) {
      _detach();
      _attach();
      return;
    }
    _sync();
  }

  @override
  void dispose() {
    _detach();
    _focus.dispose();
    super.dispose();
  }

  void _attach() {
    final buffers = editorBuffersOf(widget.view);
    final fresh = !buffers.containsKey(_spec.doc);
    _buffer = buffers[_spec.doc] ??= EditorBuffer(_spec.text ?? '', _spec.revision);
    _scroll = CodeScrollController(
      verticalScroller: ScrollController(initialScrollOffset: _buffer.top),
      horizontalScroller: ScrollController(initialScrollOffset: _buffer.left),
    );
    _scroll.verticalScroller.addListener(_rememberScroll);
    _scroll.horizontalScroller.addListener(_rememberScroll);
    _find = CodeFindController(_buffer.controller);
    _lastSelection = _buffer.controller.selection;
    _buffer.controller.addListener(_changed);
    // Um documento novo pede o teclado: abrir um arquivo é pra escrever nele.
    if (fresh || _spec.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _spec.autofocus) _focus.requestFocus();
      });
    }
    _sync();
  }

  void _detach() {
    _flush();
    _cursorTimer?.cancel();
    _buffer.controller.removeListener(_changed);
    _scroll.verticalScroller.removeListener(_rememberScroll);
    _scroll.horizontalScroller.removeListener(_rememberScroll);
    _scroll.verticalScroller.dispose();
    _scroll.horizontalScroller.dispose();
    _scroll.dispose();
    _find.dispose();
  }

  void _rememberScroll() {
    if (_scroll.verticalScroller.hasClients) _buffer.top = _scroll.verticalScroller.offset;
    if (_scroll.horizontalScroller.hasClients) _buffer.left = _scroll.horizontalScroller.offset;
  }

  /// O que o plugin pediu e o buffer ainda não fez: o texto de uma `revision`
  /// nova e o pulo pra uma linha. Depois do quadro, porque mexer no
  /// controlador avisa o editor, e o editor não pode se redesenhar no meio do
  /// build de quem o contém.
  void _sync() {
    final b = _buffer;
    final spec = _spec;
    final reload = spec.revision != b.revision && spec.text != null;
    final jump = spec.line != null && spec.jump != b.jump;
    if (!reload && !jump) return;
    b.revision = spec.revision;
    if (jump) b.jump = spec.jump;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(b, _buffer)) return;
      final c = b.controller;
      if (reload && c.text != spec.text) {
        _changeTimer?.cancel();
        // Guarda o lugar do cursor: recarregar porque outro alguém salvou não
        // é motivo pra você perder onde estava.
        final at = c.selection.extentIndex;
        c.text = spec.text!;
        b.sent = c.codeLines;
        if (!jump) _goTo(c, at, 0, center: false);
      }
      if (jump) {
        _goTo(c, spec.line! - 1, (spec.column ?? 1) - 1, center: true);
        _focus.requestFocus();
      }
    });
  }

  void _goTo(CodeLineEditingController c, int index, int offset, {required bool center}) {
    final line = index.clamp(0, c.lineCount - 1);
    final col = offset.clamp(0, c.codeLines[line].length);
    c.selection = CodeLineSelection.collapsed(index: line, offset: col);
    if (center) {
      c.makeCursorCenterIfInvisible();
    } else {
      c.makeCursorVisible();
    }
  }

  void _changed() {
    final c = _buffer.controller;
    if (!identical(c.codeLines, _buffer.sent)) {
      _changeTimer?.cancel();
      _changeTimer = Timer(_settle, _flush);
    }
    if (c.selection != _lastSelection) {
      _lastSelection = c.selection;
      _cursorTimer?.cancel();
      _cursorTimer = Timer(const Duration(milliseconds: 120), _cursor);
    }
  }

  /// Manda o texto se ele mudou desde a última vez -- o fim do debounce, e
  /// também a saída de um documento: a aba trocada não espera o timer.
  void _flush() {
    _changeTimer?.cancel();
    _changeTimer = null;
    final c = _buffer.controller;
    if (identical(c.codeLines, _buffer.sent)) return;
    _buffer.sent = c.codeLines;
    _spec.onChange?.call(<String, Object?>{'doc': _spec.doc, 'text': c.text});
  }

  void _save() {
    _flush();
    final c = _buffer.controller;
    _spec.onSave?.call(<String, Object?>{'doc': _spec.doc, 'text': c.text});
  }

  void _cursor() {
    if (!mounted) return;
    final s = _buffer.controller.selection;
    _spec.onCursor?.call(<String, Object?>{
      'doc': _spec.doc,
      'line': s.extentIndex + 1,
      'column': s.extentOffset + 1,
      'selected': s.isCollapsed ? 0 : _buffer.controller.selectedText.length,
    });
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final language = codeLanguage(spec.language);
    final mono = TextStyle(fontFamily: Mx.mono, fontSize: spec.fontSize - 1, color: Mx.fgFaint);
    return ColoredBox(
      color: Mx.bg,
      child: CodeEditor(
        key: ObjectKey(_buffer),
        controller: _buffer.controller,
        scrollController: _scroll,
        findController: _find,
        focusNode: _focus,
        readOnly: spec.readOnly,
        wordWrap: spec.wordWrap,
        hint: spec.hint,
        padding: const EdgeInsets.only(left: 6, right: 10, top: 6, bottom: 40),
        style: CodeEditorStyle(
          fontFamily: Mx.mono,
          fontSize: spec.fontSize,
          fontHeight: 1.5,
          textColor: Mx.fg,
          hintTextColor: Mx.fgFaint,
          backgroundColor: Mx.bg,
          selectionColor: Mx.accent.withValues(alpha: 0.28),
          highlightColor: Mx.yellow.withValues(alpha: 0.30),
          cursorColor: Mx.accent,
          cursorLineColor: Mx.fg.withValues(alpha: 0.045),
          chunkIndicatorColor: Mx.fgFaint,
          codeTheme: language == null
              ? null
              : CodeHighlightTheme(
                  languages: {spec.language!: CodeHighlightThemeMode(mode: language.mode)},
                  theme: codeHighlightStyles(Mx.palette),
                ),
        ),
        commentFormatter: language?.comment,
        indicatorBuilder: spec.lineNumbers
            ? (context, editing, chunks, notifier) => Row(
                children: [
                  DefaultCodeLineNumber(
                    controller: editing,
                    notifier: notifier,
                    textStyle: mono,
                    focusedTextStyle: mono.copyWith(color: Mx.fgDim),
                  ),
                  DefaultCodeChunkIndicator(width: 18, controller: chunks, notifier: notifier),
                ],
              )
            : null,
        findBuilder: (context, controller, readOnly) =>
            _FindBar(controller: controller, readOnly: readOnly),
        toolbarController: const _ContextMenu(),
        shortcutOverrideActions: {
          CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
            onInvoke: (_) {
              _save();
              return null;
            },
          ),
        },
      ),
    );
  }
}

// --- as linguagens ----------------------------------------------------------------

/// Uma linguagem: as regras das cores e o comentário do ⌘/.
typedef CodeLanguage = ({Mode mode, CodeCommentFormatter comment});

CodeCommentFormatter _comment(String? line, [String? open, String? close]) =>
    DefaultCodeCommentFormatter(
      singleLinePrefix: line ?? '',
      multiLinePrefix: open ?? '',
      multiLineSuffix: close ?? '',
    );

final _slashes = _comment('//', '/*', '*/');
final _hash = _comment('#');
final _dashes = _comment('--');
final _markup = _comment(null, '<!--', '-->');

/// As que o editor colore, pelo nome que o plugin manda. Escolhidas a dedo, e
/// não as quase duzentas do `re_highlight`: cada uma é código no binário do
/// app. O plugin traduz a extensão do arquivo pra um destes nomes; um nome que
/// não está aqui abre o texto sem cor.
final Map<String, CodeLanguage> codeLanguages = {
  'dart': (mode: langDart, comment: _slashes),
  'javascript': (mode: langJavascript, comment: _slashes),
  'typescript': (mode: langTypescript, comment: _slashes),
  'json': (mode: langJson, comment: _slashes),
  'yaml': (mode: langYaml, comment: _hash),
  'markdown': (mode: langMarkdown, comment: _markup),
  'python': (mode: langPython, comment: _hash),
  'ruby': (mode: langRuby, comment: _hash),
  'go': (mode: langGo, comment: _slashes),
  'rust': (mode: langRust, comment: _slashes),
  'java': (mode: langJava, comment: _slashes),
  'kotlin': (mode: langKotlin, comment: _slashes),
  'swift': (mode: langSwift, comment: _slashes),
  'c': (mode: langC, comment: _slashes),
  'cpp': (mode: langCpp, comment: _slashes),
  'csharp': (mode: langCsharp, comment: _slashes),
  'objectivec': (mode: langObjectivec, comment: _slashes),
  'php': (mode: langPhp, comment: _slashes),
  'bash': (mode: langBash, comment: _hash),
  'powershell': (mode: langPowershell, comment: _hash),
  'css': (mode: langCss, comment: _comment(null, '/*', '*/')),
  'scss': (mode: langScss, comment: _slashes),
  'less': (mode: langLess, comment: _slashes),
  'xml': (mode: langXml, comment: _markup),
  'vue': (mode: langVue, comment: _markup),
  'sql': (mode: langSql, comment: _dashes),
  'dockerfile': (mode: langDockerfile, comment: _hash),
  'makefile': (mode: langMakefile, comment: _hash),
  'ini': (mode: langIni, comment: _hash),
  'properties': (mode: langProperties, comment: _hash),
  'graphql': (mode: langGraphql, comment: _hash),
  'protobuf': (mode: langProtobuf, comment: _slashes),
  'gradle': (mode: langGradle, comment: _slashes),
  'groovy': (mode: langGroovy, comment: _slashes),
  'lua': (mode: langLua, comment: _dashes),
  'elixir': (mode: langElixir, comment: _hash),
  'scala': (mode: langScala, comment: _slashes),
  'haskell': (mode: langHaskell, comment: _dashes),
  'perl': (mode: langPerl, comment: _hash),
  'r': (mode: langR, comment: _hash),
  'nginx': (mode: langNginx, comment: _hash),
  'diff': (mode: langDiff, comment: _comment(null)),
  'plaintext': (mode: langPlaintext, comment: _comment(null)),
};

CodeLanguage? codeLanguage(String? name) => name == null ? null : codeLanguages[name];

/// As cores da sintaxe, tiradas do tema em vigor -- as oito do terminal mais
/// as do texto. Um tema fixo (o One Dark, o GitHub) brigaria com o resto da
/// janela no Catppuccin Latte; assim o código pinta com a mesma paleta que o
/// `ls` e o claude usam no terminal ao lado.
///
/// As chaves são as classes do `re_highlight` como o `re_editor` as entrega:
/// cortadas no primeiro ponto (`title.function_` chega `title`) e, aninhadas,
/// com a de fora na frente (`class-title`). Uma que não está aqui perde a
/// frente até achar (`params-built_in` acha `built_in`), e sem nada fica na cor
/// do texto.
Map<String, TextStyle> codeHighlightStyles(MxPalette p) {
  final a = p.ansi;
  final keyword = TextStyle(color: a.magenta);
  final type = TextStyle(color: a.yellow);
  final fn = TextStyle(color: a.blue);
  final string = TextStyle(color: a.green);
  final number = TextStyle(color: a.cyan);
  final comment = TextStyle(color: p.fgFaint, fontStyle: FontStyle.italic);
  final name = TextStyle(color: a.red);
  return {
    'root': TextStyle(color: p.fg),
    'comment': comment,
    'quote': comment,
    'doctag': keyword,
    'keyword': keyword,
    'formula': keyword,
    'selector-tag': keyword,
    'built_in': type,
    'type': type,
    'selector-class': type,
    // O nome de uma classe é um tipo, e não a função que `title` sozinho é.
    'class-title': type,
    'title': fn,
    'function': fn,
    'section': fn.copyWith(fontWeight: FontWeight.w600),
    'string': string,
    'regexp': string,
    'addition': string,
    'meta-string': string,
    'number': number,
    'literal': number,
    'literal-keyword': number,
    'symbol': number,
    'bullet': number,
    'attr': TextStyle(color: a.cyan),
    'attribute': TextStyle(color: a.cyan),
    'property': TextStyle(color: a.cyan),
    'params': TextStyle(color: p.fg),
    'variable': name,
    'template-variable': name,
    'name': name,
    'tag': TextStyle(color: p.fgDim),
    'selector-id': name,
    'selector-attr': type,
    'selector-pseudo': type,
    'deletion': name,
    'subst': TextStyle(color: p.fg),
    'meta': TextStyle(color: p.fgDim),
    'link': fn.copyWith(decoration: TextDecoration.underline),
    'code': string,
    'emphasis': const TextStyle(fontStyle: FontStyle.italic),
    'strong': const TextStyle(fontWeight: FontWeight.bold),
  };
}

// --- o menu do botão direito ------------------------------------------------------

/// Recortar, copiar, colar e selecionar tudo, no menu da Maestria em vez do do
/// Material: o mesmo de qualquer outro botão direito da janela.
class _ContextMenu implements SelectionToolbarController {
  const _ContextMenu();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) async {
    final selected = !controller.selection.isCollapsed;
    final meta = defaultTargetPlatform == TargetPlatform.macOS ? '⌘' : 'Ctrl+';
    Widget glyph(IconData icon) => Icon(icon, size: 14, color: Mx.fgDim);
    final choice = await mxMenu<String>(
      context,
      at: anchors.primaryAnchor,
      items: [
        mxItem(
          'cut',
          label: 'Recortar',
          chord: '${meta}X',
          enabled: selected,
          glyph: glyph(Icons.content_cut_rounded),
        ),
        mxItem(
          'copy',
          label: 'Copiar',
          chord: '${meta}C',
          enabled: selected,
          glyph: glyph(Icons.content_copy_rounded),
        ),
        mxItem(
          'paste',
          label: 'Colar',
          chord: '${meta}V',
          glyph: glyph(Icons.content_paste_rounded),
        ),
        mxDivider(),
        mxItem(
          'all',
          label: 'Selecionar tudo',
          chord: '${meta}A',
          glyph: glyph(Icons.select_all_rounded),
        ),
      ],
    );
    switch (choice) {
      case 'cut':
        controller.cut();
      case 'copy':
        controller.copy();
      case 'paste':
        controller.paste();
      case 'all':
        controller.selectAll();
    }
  }
}

// --- buscar e trocar --------------------------------------------------------------

/// O ⌘F (e o ⌘⌥F, com o trocar): a caixa no canto de cima, como a do VS Code.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar({required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  static const double _row = 30;
  static const double _gap = 6;

  @override
  Size get preferredSize {
    final v = controller.value;
    if (v == null) return Size.zero;
    final rows = v.replaceMode && !readOnly ? 2 : 1;
    return Size(double.infinity, rows * _row + (rows - 1) * 4 + _gap * 2 + 8);
  }

  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    if (v == null) return const SizedBox.shrink();
    final r = v.result;
    final count = v.option.pattern.isEmpty
        ? ''
        : r == null || r.matches.isEmpty
        ? 'nenhum'
        : '${r.index + 1} de ${r.matches.length}';
    final replace = v.replaceMode && !readOnly;
    return Align(
      alignment: Alignment.topRight,
      child: Container(
        width: 400,
        margin: const EdgeInsets.only(top: _gap, right: 14, bottom: _gap),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Mx.bgSidebar,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Mx.border),
          boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _Icon(
                  icon: replace ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                  tooltip: 'trocar',
                  onTap: readOnly ? null : controller.toggleMode,
                ),
                Expanded(
                  child: _Field(
                    controller: controller.findInputController,
                    focusNode: controller.findInputFocusNode,
                    hint: 'buscar',
                    onSubmit: controller.nextMatch,
                    onEscape: controller.close,
                    trailing: [
                      _Toggle(
                        label: 'Aa',
                        tooltip: 'maiúsculas',
                        on: v.option.caseSensitive,
                        onTap: controller.toggleCaseSensitive,
                      ),
                      _Toggle(
                        label: '.*',
                        tooltip: 'expressão regular',
                        on: v.option.regex,
                        onTap: controller.toggleRegex,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    count,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: r != null && r.matches.isEmpty && count.isNotEmpty ? Mx.red : Mx.fgDim,
                    ),
                  ),
                ),
                _Icon(
                  icon: Icons.arrow_upward_rounded,
                  tooltip: 'anterior',
                  onTap: controller.previousMatch,
                ),
                _Icon(
                  icon: Icons.arrow_downward_rounded,
                  tooltip: 'próximo',
                  onTap: controller.nextMatch,
                ),
                _Icon(icon: Icons.close_rounded, tooltip: 'fechar', onTap: controller.close),
              ],
            ),
            if (replace) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 26),
                  Expanded(
                    child: _Field(
                      controller: controller.replaceInputController,
                      focusNode: controller.replaceInputFocusNode,
                      hint: 'trocar por',
                      onSubmit: controller.replaceMatch,
                      onEscape: controller.close,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _Icon(
                    icon: Icons.find_replace_rounded,
                    tooltip: 'trocar este',
                    onTap: controller.replaceMatch,
                  ),
                  _Icon(
                    icon: Icons.done_all_rounded,
                    tooltip: 'trocar todos',
                    onTap: controller.replaceAllMatches,
                  ),
                  const SizedBox(width: 52),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSubmit,
    required this.onEscape,
    this.trailing = const [],
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSubmit;
  final VoidCallback onEscape;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _FindBar._row,
      decoration: BoxDecoration(
        color: Mx.bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Mx.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): onEscape},
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onSubmitted: (_) {
                  onSubmit();
                  focusNode.requestFocus();
                },
                style: TextStyle(fontSize: 12.5, color: Mx.fg),
                cursorColor: Mx.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: hint,
                  hintStyle: TextStyle(fontSize: 12.5, color: Mx.fgFaint),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
              ),
            ),
          ),
          ...trailing,
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.on,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 24,
            height: 22,
            margin: const EdgeInsets.only(left: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Mx.accent.withValues(alpha: 0.18) : null,
              borderRadius: BorderRadius.circular(4),
              border: on ? Border.all(color: Mx.accent.withValues(alpha: 0.6)) : null,
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 11, fontFamily: Mx.mono, color: on ? Mx.accent : Mx.fgDim),
            ),
          ),
        ),
      ),
    );
  }
}

class _Icon extends StatelessWidget {
  const _Icon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: onTap,
      icon: Icon(icon, color: onTap == null ? Mx.fgFaint : Mx.fgDim),
    );
  }
}
