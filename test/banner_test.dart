import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/store.dart';

/// Uma árvore qualquer, só pra `tester.pump(duração)` ter o que bombear: o que
/// se mede aqui é o relógio do recado, não o desenho dele.
Future<void> pumpClock(WidgetTester tester) =>
    tester.pumpWidget(const MaterialApp(home: SizedBox()));

void main() {
  group('o recado da janela', () {
    testWidgets('sai sozinho quando o prazo acaba', (tester) async {
      final store = AppStore();
      await pumpClock(tester);

      store.showBanner('caminho copiado');
      expect(store.banner, 'caminho copiado');

      // Um segundo antes ainda está lá: o prazo é pra ser lido, não piscado.
      await tester.pump(AppStore.bannerLife - const Duration(seconds: 1));
      expect(store.banner, isNotNull);

      await tester.pump(const Duration(seconds: 1));
      expect(store.banner, isNull);

      store.dispose();
    });

    testWidgets('o de erro espera o clique', (tester) async {
      final store = AppStore();
      await pumpClock(tester);

      store.showBanner('esse arquivo não está mais lá: /sumiu.md', sticky: true);
      await tester.pump(AppStore.bannerLife * 3);
      expect(store.banner, contains('/sumiu.md'));

      store.clearBanner();
      expect(store.banner, isNull);

      store.dispose();
    });

    // O prazo é do recado que está na tela, não do primeiro que apareceu: sem
    // isto, o segundo recado herdava os milissegundos que sobraram do primeiro
    // e sumia antes de ser lido.
    testWidgets('um recado novo começa o prazo do zero', (tester) async {
      final store = AppStore();
      await pumpClock(tester);

      store.showBanner('primeiro');
      await tester.pump(AppStore.bannerLife - const Duration(seconds: 1));
      store.showBanner('segundo');

      await tester.pump(const Duration(seconds: 2));
      expect(store.banner, 'segundo');

      await tester.pump(AppStore.bannerLife);
      expect(store.banner, isNull);

      store.dispose();
    });

    // Um recado de erro não tem prazo pendente pra estourar depois: era ele
    // que apagava, sozinho, o recado que viesse em seguida.
    testWidgets('o de erro não leva embora o recado seguinte', (tester) async {
      final store = AppStore();
      await pumpClock(tester);

      store.showBanner('não achei o vscode', sticky: true);
      store.showBanner('nome copiado: api');
      await tester.pump(AppStore.bannerLife - const Duration(seconds: 1));
      expect(store.banner, 'nome copiado: api');

      store.dispose();
    });
  });
}
