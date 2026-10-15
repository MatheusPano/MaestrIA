import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_pane.dart';

/// Duas janelas de widgets na tela -- a aba da lateral e um modal, como o
/// escritório faz -- com o `SingleChildScrollView` do rfw no padrão dele
/// (`primary: true`). A roda numa delas não pode derrubar a barra de rolagem.
void main() {
  const library = '''
    import core.widgets;
    widget root = SingleChildScrollView(
      child: Column(children: [
        ...for i in data.rows:
          SizedBox(height: 60.0, child: Text(text: i)),
      ]),
    );
  ''';

  MxTab tab(String id) {
    final t = MxTab(
      id: id,
      folder: Folder(root: '/repo', name: 'repo'),
      kind: TabKind.plugin,
      cwd: '/repo',
      branch: '',
      view: PluginView(pluginId: 'p', pluginName: 'P', id: id, title: id, blocks: const []),
    );
    t.view!.setRfw(library: library, data: {
      'rows': [for (var i = 0; i < 40; i++) 'linha $i'],
    });
    return t;
  }

  testWidgets('duas janelas roláveis lado a lado, e a roda gira sem erro', (tester) async {
    final store = AppStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(width: 300, height: 500, child: PluginPane(store: store, tab: tab('lateral'), bare: true)),
              SizedBox(width: 300, height: 500, child: PluginPane(store: store, tab: tab('chat'), bare: true)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.text('linha 2').last)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
