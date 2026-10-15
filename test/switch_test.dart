import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/ui/switch.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('o clique inverte o valor', (tester) async {
    bool? got;
    await tester.pumpWidget(host(MxSwitch(value: false, onChanged: (v) => got = v)));
    await tester.tap(find.byType(MxSwitch));
    expect(got, isTrue);
  });

  testWidgets('sem onChanged não responde', (tester) async {
    await tester.pumpWidget(host(const MxSwitch(value: true, onChanged: null)));
    await tester.tap(find.byType(MxSwitch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tem o tamanho de um controle de desktop', (tester) async {
    await tester.pumpWidget(host(MxSwitch(value: true, onChanged: (_) {})));
    expect(tester.getSize(find.byType(MxSwitch)), const Size(MxSwitch.width, MxSwitch.height));
  });
}
