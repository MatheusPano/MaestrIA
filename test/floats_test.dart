import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/services/plugin_floats.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_float.dart';

const library = '''
  import core.widgets;
  import maestria;
  widget root = Row(children: [
    Text(text: data.clock),
    IconButton(icon: "play", tooltip: "iniciar", onPressed: event "toggle" {}),
  ]);
''';

MxPlugin pomodoro() => MxPlugin(
  dir: '/p',
  manifest: const PluginManifest(id: 'pomodoro', name: 'Pomodoro', version: '1', main: ['node']),
);

void main() {
  group('o flutuante de plugin', () {
    test('float.show mostra, float.update junta os dados, float.hide tira', () async {
      final store = AppStore();
      final plugin = pomodoro();
      final api = PluginApi(store);

      expect(
        await api.handle(plugin, 'float.update', {
          'id': 'timer',
          'data': {'clock': '25:00'},
        }),
        {'shown': false},
        reason: 'antes do show não há o que atualizar',
      );

      final said = await api.handle(plugin, 'float.show', {
        'id': 'timer',
        'width': 180,
        'height': 1000,
        'corner': 'topLeft',
        'rfw': {'library': library},
        'data': {'clock': '25:00'},
      });
      expect(said, {'shown': true});
      final f = store.floats.shown.single;
      expect(f.width, 180);
      expect(f.height, PluginFloat.maxHeight, reason: 'o tamanho tem teto');
      expect(f.start, FloatCorner.topLeft);
      expect(f.view.rfwLibrary, library);

      await api.handle(plugin, 'float.update', {
        'id': 'timer',
        'data': {'phase': 'foco'},
      });
      expect(f.view.rfwData, {'clock': '25:00', 'phase': 'foco'});

      await expectLater(
        api.handle(plugin, 'float.show', {'id': 'x', 'corner': 'meio'}),
        throwsA(isA<PluginRpcError>()),
      );
      await expectLater(api.handle(plugin, 'float.show', {}), throwsA(isA<PluginRpcError>()));

      await api.handle(plugin, 'float.hide', {'id': 'timer'});
      expect(store.floats.shown, isEmpty);
      store.dispose();
    });

    test('o lugar vai pro config e volta, e um lixo no config é ignorado', () {
      final floats = PluginFloats(onMoved: () {});
      floats.readJson({
        'pomodoro/timer': {'corner': 'bottomRight', 'dx': 8, 'dy': 120.4},
        'x/y': {'corner': 'meio', 'dx': 1, 'dy': 1},
        'z/w': 'nada',
      });
      expect(floats.spots.keys, ['pomodoro/timer']);
      expect(floats.toJson(), {
        'pomodoro/timer': {'corner': 'bottomRight', 'dx': 8.0, 'dy': 120.0},
      });
      floats.dispose();
    });

    testWidgets('desenha por cima, arrasta, gruda na borda e guarda o lugar', (tester) async {
      final store = AppStore();
      final plugin = pomodoro();
      store.plugins.all.add(plugin);
      final floats = store.floats;
      floats.show(
        plugin,
        'timer',
        width: 160,
        height: 50,
        rfw: (library: library, root: null, data: {'clock': '24:59'}),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: Stack(children: [Positioned.fill(child: PluginFloatLayer(store: store))]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('24:59'), findsOneWidget);
      // O primeiro lugar: embaixo à direita, na margem.
      expect(tester.getTopLeft(find.text('24:59').first).dx, greaterThan(800 - 160 - 8));

      // Arrasta pra perto do canto de cima à esquerda: gruda nas duas bordas.
      floats.spots.clear();
      await tester.dragFrom(
        tester.getTopLeft(find.text('24:59')),
        const Offset(-(800.0 - 160 - 8 - 20), -(600.0 - 50 - 8 - 20)),
      );
      await tester.pumpAndSettle();
      final spot = floats.spots['pomodoro/timer']!;
      expect(spot.corner, FloatCorner.topLeft);
      expect(spot.dx, 8.0);
      expect(spot.dy, 8.0);

      // Um toque parado é do botão, não arraste.
      await tester.tap(find.byTooltip('iniciar'));
      await tester.pump();
      expect(floats.spots['pomodoro/timer'], spot);

      // Desligado, o plugin leva o flutuante junto; o lugar fica pra volta.
      await store.setPluginEnabled(plugin, false);
      await tester.pumpAndSettle();
      expect(find.text('24:59'), findsNothing);
      expect(floats.spots, contains('pomodoro/timer'));
      store.dispose();
    });
  });
}
