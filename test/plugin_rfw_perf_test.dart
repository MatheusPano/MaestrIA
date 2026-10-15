import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_pane.dart';
import 'package:maestria/ui/plugin_sprite.dart';

/// Uma janela de widgets que se atualiza muitas vezes por segundo (o
/// escritório, com os bonecos andando) não pode custar o app inteiro a cada vez.
void main() {
  const library = '''
    import core.widgets;
    import maestria;
    widget root = Stack(children: [
      Svg(svg: data.scene, width: 40.0, height: 40.0),
      Positioned(start: 0.0, top: 0.0, child: Text(text: data.label)),
      Positioned(start: 10.0, top: 10.0, child: Sprite(sheet: "x.png", frames: 4, fps: 8.0, width: 16.0, height: 24.0)),
    ]);
  ''';
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#336699"/></svg>';

  testWidgets('um view.update só de dados redesenha a janela, e não o app', (tester) async {
    final store = AppStore();
    final plugin = MxPlugin(dir: '/p', manifest: const PluginManifest(id: 'p', name: 'P', version: '1'));
    final tab = store.openPluginView(
      plugin,
      'cena',
      title: 'cena',
      blocks: const [],
      rfw: (library: library, root: null, data: {'scene': svg, 'label': 'um'}),
    );
    var notified = 0;
    store.addListener(() => notified++);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SizedBox(width: 300, height: 300, child: PluginPane(store: store, tab: tab, bare: true)))),
    );
    await tester.pump();
    expect(find.text('um'), findsOneWidget);
    final background = tester.widget<SvgPicture>(find.byType(SvgPicture));

    expect(store.updatePluginView(plugin, 'cena', rfw: (library: null, root: null, data: {'label': 'dois'})), isTrue);
    await tester.pump();
    expect(find.text('dois'), findsOneWidget, reason: 'a janela se redesenhou sozinha');
    expect(notified, 0, reason: 'o app não foi avisado');
    expect(
      identical(tester.widget<SvgPicture>(find.byType(SvgPicture)), background),
      isTrue,
      reason: 'o fundo, que não mudou, não foi reconstruído',
    );

    // Trocar o título é coisa que o app mostra: aí ele é avisado.
    store.updatePluginView(plugin, 'cena', title: 'outra');
    expect(notified, 1);
    store.dispose();
  });

  testWidgets('o fundo e cada boneco ficam numa camada de pintura só deles', (tester) async {
    final store = AppStore();
    final tab = MxTab(
      id: 't',
      folder: Folder(root: '/r', name: 'r'),
      kind: TabKind.plugin,
      cwd: '/r',
      branch: '',
      view: PluginView(pluginId: 'p', pluginName: 'P', id: 'cena', title: 'cena', blocks: const []),
    );
    tab.view!.setRfw(library: library, data: {'scene': svg, 'label': 'um'});
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SizedBox(width: 300, height: 300, child: PluginPane(store: store, tab: tab, bare: true)))),
    );
    await tester.pump();
    expect(find.ancestor(of: find.byType(SvgPicture), matching: find.byType(RepaintBoundary)), findsWidgets);
    expect(
      find.descendant(of: find.byType(PluginSprite), matching: find.byType(RepaintBoundary)),
      findsNothing,
      reason: 'sem a folha carregada não há o que pintar',
    );
    store.dispose();
  });
}
