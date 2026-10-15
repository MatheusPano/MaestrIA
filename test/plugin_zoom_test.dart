import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/ui/plugin_zoom.dart';

/// O `ZoomView` de `import maestria;`: o zoom de mapa da janela de um plugin.
/// Ver `ui/plugin_zoom.dart`.
void main() {
  final reports = <double>[];

  Widget view({String? command, int rev = 0}) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: 400,
        height: 200,
        child: PluginZoomView(
          maxScale: 4,
          command: command,
          commandRev: rev,
          onZoom: (args) => reports.add(args['scale']! as double),
          child: const ColoredBox(color: Colors.red),
        ),
      ),
    ),
  );

  double scaleOf(WidgetTester tester) =>
      tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.getMaxScaleOnAxis();

  setUp(reports.clear);

  testWidgets('a bolinha aproxima, e o plugin fica sabendo quando assenta', (tester) async {
    await tester.pumpWidget(view());
    final at = tester.getCenter(find.byType(PluginZoomView));
    await tester.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: const Offset(0, -100)));
    await tester.pump();
    expect(scaleOf(tester), greaterThan(1.2));
    expect(reports, isEmpty);
    await tester.pump(const Duration(milliseconds: 250));
    expect(reports.single, closeTo(scaleOf(tester), 1e-6));
  });

  testWidgets('não afasta além de caber', (tester) async {
    await tester.pumpWidget(view());
    final at = tester.getCenter(find.byType(PluginZoomView));
    await tester.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: const Offset(0, 300)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(scaleOf(tester), 1);
  });

  testWidgets('os botões do plugin valem quando o commandRev muda, até o maxScale', (tester) async {
    await tester.pumpWidget(view(command: 'in'));
    await tester.pumpAndSettle();
    expect(scaleOf(tester), 1, reason: 'o comando de quando a janela abriu já valeu antes');

    await tester.pumpWidget(view(command: 'in', rev: 1));
    await tester.pumpAndSettle();
    expect(scaleOf(tester), closeTo(1.5, 1e-6));

    for (var rev = 2; rev < 8; rev++) {
      await tester.pumpWidget(view(command: 'in', rev: rev));
      await tester.pumpAndSettle();
    }
    expect(scaleOf(tester), closeTo(4, 1e-6));

    await tester.pumpWidget(view(command: 'fit', rev: 8));
    await tester.pumpAndSettle();
    expect(scaleOf(tester), 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(reports.last, 1);
  });
}
