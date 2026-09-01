import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/ui/confetti.dart';

/// A window with one button that throws the party.
Future<void> pumpWithButton(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => Confetti.fire(ctx),
          child: const Text('concluir'),
        ),
      ),
    ),
  ),
);

/// The burst is private, and should stay that way: what the app promises is
/// that it shows up and then is gone, not which widget draws it.
final _burst = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Burst');

void main() {
  group('the confetti', () {
    testWidgets('shows up over the window and then takes itself off it', (tester) async {
      await pumpWithButton(tester);
      expect(_burst, findsNothing);

      await tester.tap(find.text('concluir'));
      await tester.pump();
      expect(_burst, findsOneWidget);

      // Mid-air. Still painting, and still not the app's problem to clean up.
      await tester.pump(const Duration(milliseconds: 1200));
      expect(_burst, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(_burst, findsNothing);
    });

    testWidgets('does not eat the clicks that land on it', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: TextButton(
                  onPressed: () {
                    taps++;
                    Confetti.fire(ctx);
                  },
                  child: const Text('concluir'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('concluir'));
      await tester.pump(const Duration(milliseconds: 300));
      // The sheet is up, covering the whole window. A button under it still
      // answers -- confetti is scenery, not a modal.
      await tester.tap(find.text('concluir'));
      expect(taps, 2);

      await tester.pump(const Duration(seconds: 4));
    });
  });
}
