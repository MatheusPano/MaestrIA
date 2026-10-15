import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/plugin_editor.dart';
import 'package:maestria/ui/plugin_pane.dart';
import 'package:re_editor/re_editor.dart';

/// O `CodeEditor` de `import maestria;`: o texto na janela, o arquivo no
/// plugin. Ver `ui/plugin_editor.dart`.
void main() {
  const library = '''
    import core.widgets;
    import maestria;
    widget root = Column(children: [
      Text(text: data.file.path),
      Expanded(child: CodeEditor(
        doc: data.file.path,
        text: data.file.text,
        revision: data.file.rev,
        language: "dart",
        line: data.file.line,
        jump: data.file.jump,
        onChange: event "change" {},
        onSave: event "save" {},
        onCursor: event "cursor" {},
      )),
    ]);
  ''';

  MxTab editorTab(Map<String, Object?> file) {
    final tab = MxTab(
      id: 'tab1',
      folder: Folder(root: '/repo', name: 'repo'),
      kind: TabKind.plugin,
      cwd: '/repo',
      branch: '',
      view: PluginView(pluginId: 'p', pluginName: 'P', id: 'editor', title: 'editor', blocks: const []),
    );
    tab.view!.setRfw(library: library, data: {'file': file});
    return tab;
  }

  Future<void> pump(WidgetTester tester, AppStore store, MxTab tab, {bool shown = true}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 500,
              child: shown ? PluginPane(store: store, tab: tab, bare: true) : const SizedBox(),
            ),
          ),
        ),
      );

  String text(MxTab tab, String doc) => editorBuffersOf(tab.view!)[doc]!.controller.text;

  testWidgets('digitar manda o texto depois de parar; o ⌘S manda na hora', (tester) async {
    final store = _ActionsStore();
    final tab = editorTab({'path': '/repo/a.dart', 'text': 'void main() {}\n', 'rev': 1});
    await pump(tester, store, tab);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('/repo/a.dart'), findsOneWidget);
    expect(text(tab, '/repo/a.dart'), 'void main() {}\n');
    expect(store.actions.where((a) => a == 'change'), isEmpty, reason: 'o texto que veio do plugin não volta');

    await tester.pump();
    final c = editorBuffersOf(tab.view!)['/repo/a.dart']!.controller;
    c.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    c.replaceSelection('// oi\n');
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.actions.where((a) => a == 'change'), isEmpty, reason: 'ainda digitando');
    await tester.pump(const Duration(milliseconds: 400));
    final change = store.values[store.actions.indexOf('change')];
    expect(change['doc'], '/repo/a.dart');
    expect(change['text'], '// oi\nvoid main() {}\n');

    await tester.tap(find.byType(CodeEditor));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(store.actions, contains('save'));
    expect(store.values[store.actions.lastIndexOf('save')]['text'], '// oi\nvoid main() {}\n');
    // O toque deixa timers do próprio editor (o duplo clique, o cursor piscando).
    await tester.pump(const Duration(seconds: 1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('o buffer fica com a janela: sair da tela e voltar não perde o que mudou', (tester) async {
    final store = _ActionsStore();
    final tab = editorTab({'path': '/repo/a.dart', 'text': 'a\n', 'rev': 1});
    await pump(tester, store, tab);
    await tester.pump();
    editorBuffersOf(tab.view!)['/repo/a.dart']!.controller.text = 'a\nb\n';

    await pump(tester, store, tab, shown: false);
    expect(store.actions, contains('change'), reason: 'desmontar não espera o debounce');
    await pump(tester, store, tab);
    await tester.pump();
    expect(text(tab, '/repo/a.dart'), 'a\nb\n', reason: 'o mesmo text com a mesma revision não apaga nada');

    // Outro documento na mesma janela é outro buffer; voltar ao primeiro o acha como estava.
    tab.view!.setRfw(data: {
      'file': {'path': '/repo/b.dart', 'text': 'b\n', 'rev': 1},
    });
    await pump(tester, store, tab);
    await tester.pump();
    expect(text(tab, '/repo/b.dart'), 'b\n');
    tab.view!.setRfw(data: {
      'file': {'path': '/repo/a.dart', 'text': 'a\n', 'rev': 1},
    });
    await pump(tester, store, tab);
    await tester.pump();
    expect(text(tab, '/repo/a.dart'), 'a\nb\n');
  });

  testWidgets('uma revision nova troca o texto; um jump novo leva o cursor à linha', (tester) async {
    final store = _ActionsStore();
    final tab = editorTab({'path': '/repo/a.dart', 'text': 'um\n', 'rev': 1});
    await pump(tester, store, tab);
    await tester.pump();

    tab.view!.setRfw(data: {
      'file': {'path': '/repo/a.dart', 'text': 'um\ndois\ntrês\n', 'rev': 2, 'line': 3, 'jump': 1},
    });
    await pump(tester, store, tab);
    await tester.pump();
    final c = editorBuffersOf(tab.view!)['/repo/a.dart']!.controller;
    expect(c.text, 'um\ndois\ntrês\n');
    expect(c.selection.extentIndex, 2);
    await tester.pump(const Duration(milliseconds: 500));
    expect(store.actions.where((a) => a == 'change'), isEmpty, reason: 'recarregar não é editar');
    final cursor = store.values[store.actions.lastIndexOf('cursor')];
    expect(cursor['line'], 3);
  });

  test('as cores da sintaxe vêm das do terminal do tema', () {
    final styles = codeHighlightStyles(Mx.palette);
    expect(styles['keyword']!.color, Mx.palette.ansi.magenta);
    expect(styles['string']!.color, Mx.palette.ansi.green);
    expect(codeLanguage('dart'), isNotNull);
    expect(codeLanguage('klingon'), isNull);
  });
}

class _ActionsStore extends AppStore {
  final actions = <String>[];
  final values = <Map<String, dynamic>>[];

  @override
  void pluginViewAction(MxTab tab, String action, Map<String, dynamic> values) {
    actions.add(action);
    this.values.add(values);
  }
}
