import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_input.dart';
import 'package:maestria/ui/plugin_pane.dart';

/// O `TextInput` de `import maestria;` (o texto na janela, o envio pro plugin),
/// e a sessão que um plugin abre sem tirar você da tela dele.
void main() {
  const library = '''
    import core.widgets;
    import maestria;
    widget root = Column(children: [
      Text(text: data.title),
      TextInput(
        id: "chat",
        placeholder: "fale com ele",
        multiline: true,
        clear: data.sent,
        disabled: data.locked,
        hint: "responda no terminal",
        sendIcon: "send",
        onSubmit: event "send" {},
      ),
    ]);
  ''';

  MxTab chatTab(Map<String, Object?> data) {
    final tab = MxTab(
      id: 'tab1',
      folder: Folder(root: '/repo', name: 'repo'),
      kind: TabKind.plugin,
      cwd: '/repo',
      branch: '',
      view: PluginView(pluginId: 'p', pluginName: 'P', id: 'chat', title: 'chat', blocks: const []),
    );
    tab.view!.setRfw(library: library, data: data);
    return tab;
  }

  Future<void> pump(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, height: 400, child: PluginPane(store: store, tab: tab, bare: true)),
      ),
    ),
  );

  testWidgets('o enter manda o texto, e o clear do plugin esvazia o campo', (tester) async {
    final store = _ActionsStore();
    final tab = chatTab({'title': 'oi', 'sent': 0, 'locked': false});
    await pump(tester, store, tab);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'roda os testes');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(store.actions, ['send']);
    expect(store.values.single['text'], 'roda os testes');
    expect(textInputsOf(tab.view!)['chat']!.text, 'roda os testes', reason: 'só o plugin esvazia');

    // O plugin aceitou: aumenta o clear, e o campo fica vazio.
    tab.view!.setRfw(data: {'title': 'oi', 'sent': 1, 'locked': false});
    await pump(tester, store, tab);
    await tester.pump();
    expect(textInputsOf(tab.view!)['chat']!.text, '');

    // Os mesmos dados de novo não apagam o que se está digitando.
    textInputsOf(tab.view!)['chat']!.text = 'meio caminho';
    tab.view!.setRfw(data: {'title': 'outro', 'sent': 1, 'locked': false});
    await pump(tester, store, tab);
    await tester.pump();
    expect(textInputsOf(tab.view!)['chat']!.text, 'meio caminho');

    // Vazio não manda nada.
    textInputsOf(tab.view!)['chat']!.text = '   ';
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(store.actions, ['send']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('travado, o campo mostra o aviso e não manda', (tester) async {
    final store = _ActionsStore();
    final tab = chatTab({'title': 'oi', 'sent': 0, 'locked': true});
    await pump(tester, store, tab);
    await tester.pump();
    expect(find.text('responda no terminal'), findsOneWidget);
    textInputsOf(tab.view!)['chat']!.text = 'sim';
    await tester.tap(find.byIcon(Icons.send_rounded), warnIfMissed: false);
    await tester.pump();
    expect(store.actions, isEmpty);
  });

  /// A área de transferência: um texto, ou `null` -- um print, que não é texto.
  void clipboardHolds(String? text) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData' && text != null ? <String, dynamic>{'text': text} : null,
    );
  }

  testWidgets('o ⌘V cola texto no campo; um print vira o onPasteImage; com allowEmpty, o vazio vai', (tester) async {
    const pasting = '''
      import core.widgets;
      import maestria;
      widget root = TextInput(
        id: "chat",
        multiline: true,
        allowEmpty: data.empty,
        onSubmit: event "send" {},
        onPasteImage: event "image" {},
      );
    ''';
    final store = _ActionsStore();
    final tab = chatTab({});
    tab.view!.setRfw(library: pasting, data: {'empty': false});
    await pump(tester, store, tab);
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();

    clipboardHolds('olha isso');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(textInputsOf(tab.view!)['chat']!.text, 'olha isso');
    expect(store.actions, isEmpty);

    clipboardHolds(null);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(store.actions, ['image']);
    expect(textInputsOf(tab.view!)['chat']!.text, 'olha isso', reason: 'o print não mexe no texto');

    // Vazio não vai... a não ser que o plugin diga que pode (a imagem sozinha).
    textInputsOf(tab.view!)['chat']!.text = '';
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(store.actions, ['image']);
    tab.view!.setRfw(data: {'empty': true});
    await pump(tester, store, tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(store.actions, ['image', 'send']);
    expect(store.values.last['text'], '');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('o Markdown desenha o markdown, sem os asteriscos', (tester) async {
    final store = _ActionsStore();
    final tab = chatTab({});
    tab.view!.setRfw(
      library: '''
        import core.widgets;
        import maestria;
        widget root = Markdown(text: data.text);
      ''',
      data: {'text': 'Pronto, o **login** voltou.\n\n- um\n- dois'},
    );
    await pump(tester, store, tab);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('login', findRichText: true), findsOneWidget);
    expect(find.textContaining('dois', findRichText: true), findsOneWidget);
  });

  /// Arrasta de [from] até [to] e copia: o que foi pra área de transferência.
  Future<String?> dragAndCopy(WidgetTester tester, Finder from, Finder to) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
    final gesture = await tester.startGesture(tester.getTopLeft(from) + const Offset(2, 6), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(to) - const Offset(2, 6));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    return copied;
  }

  testWidgets('a seleção atravessa os parágrafos do markdown, e os balões dentro do Selectable', (tester) async {
    final store = _ActionsStore();
    final tab = chatTab({});
    tab.view!.setRfw(
      library: '''
        import core.widgets;
        import maestria;
        widget root = Selectable(child: Column(children: [
          Markdown(text: data.one),
          Text(text: "no meio"),
          Markdown(text: data.two),
        ]));
      ''',
      data: {'one': 'primeiro parágrafo\n\nsegundo parágrafo', 'two': '- um item\n- outro item'},
    );
    await pump(tester, store, tab);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(SelectableText), findsNothing, reason: 'cada parágrafo não é mais um selecionável à parte');
    final copied = await dragAndCopy(
      tester,
      find.textContaining('primeiro', findRichText: true),
      find.textContaining('outro item', findRichText: true),
    );
    // Cada pedaço na sua linha; o "•" e o texto do item, lado a lado.
    expect(copied, contains('primeiro parágrafo\nsegundo parágrafo\nno meio\n'));
    expect(copied, contains('• um item\n• outro item'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('com o campo vazio, as setas vão pro plugin (onArrow); com texto, são do campo', (tester) async {
    final arrows = <Object?>[];
    final view = PluginView(pluginId: 'p', pluginName: 'P', id: 'chat', title: 'chat', blocks: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PluginTextInput(view: view, id: 'setas', autofocus: true, onArrow: (args) => arrows.add(args['key'])),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(arrows, ['down', 'down', 'up']);

    await tester.enterText(find.byType(TextField), 'oi');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(arrows, hasLength(3));
  });

  testWidgets('com commands, o / abre a lista: setas, tab completa, enter manda, esc fecha', (tester) async {
    final sent = <Object?>[];
    final view = PluginView(pluginId: 'p', pluginName: 'P', id: 'chat', title: 'chat', blocks: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PluginTextInput(
            view: view,
            id: 'barra',
            autofocus: true,
            multiline: true,
            commands: const [
              (name: 'clear', description: 'limpa a conversa'),
              (name: 'compact', description: 'resume a conversa'),
              (name: 'context', description: 'o uso do contexto'),
            ],
            onSubmit: (args) => sent.add(args['text']),
          ),
        ),
      ),
    );
    await tester.pump();
    final text = textInputsOf(view)['barra']!;

    await tester.enterText(find.byType(TextField), '/co');
    await tester.pump();
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/context'), findsOneWidget);
    expect(find.text('/clear'), findsNothing);

    // A seta é da lista, e o tab completa o destacado com o espaço dos argumentos.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(text.text, '/context ');
    expect(find.text('/context'), findsNothing, reason: 'com espaço, já são os argumentos');

    // O enter manda o destacado.
    await tester.enterText(find.byType(TextField), '/comp');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, ['/compact']);

    // O esc fecha, e ela volta quando o texto muda.
    await tester.enterText(find.byType(TextField), '/c');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('/clear'), findsNothing);
    await tester.enterText(find.byType(TextField), '/cl');
    await tester.pump();
    expect(find.text('/clear'), findsOneWidget);

    // O clique completa.
    await tester.tap(find.text('/clear'));
    await tester.pump();
    expect(text.text, '/clear ');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
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

