import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/sidebar.dart';

(AppStore, MxTab) storeWithPanel() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')..isRepo = true;
  store.folders.add(folder);
  final tab = MxTab(
    id: 't1',
    folder: folder,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'implementa',
  );
  store.tabs.add(tab);
  return (store, tab);
}

/// Põe [tab] na tela e o teclado dentro dele: é o que [AppStore.watching]
/// mede, e nenhum teste tem janela pra chegar lá sozinho.
void look(AppStore store, MxTab tab) {
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
}

void turn(AppStore store, MxTab tab) {
  store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));
  store.applyHook(HookEvent(tab.id, 'Stop', {}));
}

Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

void main() {
  // O aviso de ociosidade acende o badge do dock, e o dock é um
  // `MethodChannel`: sem binding ele estoura antes do primeiro expect.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shortAgo', () {
    final at = DateTime(2026, 9, 9, 12);

    test('conta em minutos, horas e dias, e depois vira data', () {
      String ago(Duration d) => shortAgo(at, now: at.add(d));
      expect(ago(const Duration(seconds: 3)), 'agora');
      // O último segundo que ainda é "agora": sem este limite, 45s virava
      // "0min" -- um número que diz menos que a palavra.
      expect(ago(const Duration(seconds: 59)), 'agora');
      expect(ago(const Duration(minutes: 1)), '1min');
      expect(ago(const Duration(minutes: 59)), '59min');
      expect(ago(const Duration(hours: 3)), '3h');
      expect(ago(const Duration(days: 2)), '2d');
      expect(ago(const Duration(days: 9)), '9/9');
    });
  });

  group('uma sessão que para', () {
    test('carimba a hora da parada e se anuncia como não vista', () {
      final (store, tab) = storeWithPanel();
      expect(tab.restedAt, isNull);
      expect(tab.rested, isFalse);

      turn(store, tab);

      expect(tab.restedAt, isNotNull);
      expect(tab.rested, isTrue);
      expect(tab.restedAgo, 'agora');
      // A janela estava aqui, mas o teclado não estava neste painel: você não
      // estava olhando pra ele.
      expect(tab.unseen, isTrue);
      store.dispose();
    });

    test('não é novidade quando você estava olhando pra ela', () {
      final (store, tab) = storeWithPanel();
      look(store, tab);

      turn(store, tab);

      expect(tab.rested, isTrue);
      expect(tab.unseen, isFalse);
      store.dispose();
    });

    test('não é novidade nenhuma se a janela estava atrás', () {
      final (store, tab) = storeWithPanel();
      look(store, tab);
      store.setWindowActive(false);

      turn(store, tab);

      // Mesmo painel, mesmo foco: o que mudou é que você não estava aqui.
      expect(tab.unseen, isTrue);
      store.dispose();
    });

    test('perde o carimbo no próximo prompt', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      expect(tab.unseen, isTrue);

      store.applyHook(HookEvent(tab.id, 'UserPromptSubmit', {}));

      // A idade é *deste* repouso. Uma sessão que voltou a trabalhar não
      // parou faz dois minutos -- ela não parou.
      expect(tab.restedAt, isNull);
      expect(tab.rested, isFalse);
      expect(tab.unseen, isFalse);
      store.dispose();
    });

    test('um segundo Stop não reinicia a contagem', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      final first = tab.restedAt;

      store.applyHook(HookEvent(tab.id, 'Stop', {}));

      expect(tab.restedAt, first);
      store.dispose();
    });
  });

  group('dar por visto', () {
    test('só vale pro painel em foco, com a janela na frente', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      expect(tab.unseen, isTrue);

      // Fora da tela: olhar a lateral não é ler a resposta.
      expect(store.seeFocused(), isFalse);
      expect(tab.unseen, isTrue);

      look(store, tab);
      store.setWindowActive(false);
      expect(store.seeFocused(), isFalse);
      expect(tab.unseen, isTrue);

      store.setWindowActive(true);
      expect(store.seeFocused(), isTrue);
      expect(tab.unseen, isFalse);
      // E a segunda passada não tem nada a dizer -- é o que evita um
      // notifyListeners por segundo pra sempre.
      expect(store.seeFocused(), isFalse);
      store.dispose();
    });
  });

  group('voltar pra janela', () {
    test('conta o que parou enquanto você estava fora', () {
      final (store, tab) = storeWithPanel();
      store.setWindowActive(false);
      turn(store, tab);

      store.setWindowActive(true);

      expect(store.banner, 'implementa terminou enquanto você estava fora');
      // A faixa é o aviso; a marca continua até você olhar pro painel.
      expect(tab.unseen, isTrue);
      store.dispose();
    });

    test('cala sobre o que já estava parado antes de você sair', () {
      final (store, tab) = storeWithPanel();
      turn(store, tab);
      store.clearBanner();

      store.setWindowActive(false);
      store.setWindowActive(true);

      // Continua não vista, e continua não sendo notícia: ela não é do
      // intervalo em que você esteve fora.
      expect(tab.unseen, isTrue);
      expect(store.banner, isNull);
      store.dispose();
    });
  });

  group('a linha da lateral', () {
    testWidgets('mostra a idade da parada', (tester) async {
      final (store, tab) = storeWithPanel();
      turn(store, tab);

      await pumpSidebar(tester, store);

      expect(find.text('agora'), findsOneWidget);
      // Verde enquanto não vista: é o que separa a que terminou agora das
      // quatro que dizem "pronto" faz meia hora.
      final stamp = tester.widget<Text>(find.text('agora'));
      expect(stamp.style?.color, Mx.green);

      look(store, tab);
      store.seeFocused();
      // De novo e não um `pump`: quem escuta a store é o `AnimatedBuilder` do
      // `main.dart`, que não está nesta árvore.
      await pumpSidebar(tester, store);

      expect(tab.unseen, isFalse);
      expect(tester.widget<Text>(find.text('agora')).style?.color, isNot(Mx.green));
      store.dispose();
    });
  });
}
