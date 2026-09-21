import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/keys.dart';
import 'package:maestria/ui/sidebar.dart';

AppStore storeWithFolder() {
  final store = AppStore();
  store.folders.add(
    Folder(root: '/repo', name: 'meu-repo')
      ..isRepo = true
      ..branch = 'master',
  );
  return store;
}

/// O config que o store acabou de gravar. O save é debounced, então o arquivo
/// sai do caminho primeiro e a leitura espera ele reaparecer.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// A lateral sozinha, larga o bastante pro rodapé caber inteiro.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    theme: Mx.theme(),
    home: Scaffold(
      body: SizedBox(
        width: 660,
        height: 700,
        child: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Sidebar(store: store),
        ),
      ),
    ),
  ),
);

/// A janela reduzida ao que um atalho precisa: o mapa montado do store.
Future<void> pumpKeys(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Mx.theme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => CallbackShortcuts(
            bindings: MxKeys.bindings(store, ctx),
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> holding = const [],
}) async {
  for (final m in holding) {
    await tester.sendKeyDownEvent(m, platform: 'macos');
  }
  await tester.sendKeyDownEvent(key, platform: 'macos');
  await tester.sendKeyUpEvent(key, platform: 'macos');
  for (final m in holding.reversed) {
    await tester.sendKeyUpEvent(m, platform: 'macos');
  }
  await tester.pumpAndSettle();
}

/// Desmonta a tela e recolhe o store: esconder a lateral agenda a gravação do
/// config, e um timer desses vivo no fim do teste é um teste que falha.
Future<void> closeWindow(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  store.dispose();
}

void main() {
  group('esconder a lateral', () {
    testWidgets('o glifo do rodapé é o interruptor, nos dois sentidos', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);

      expect(store.sidebarHidden, isFalse);
      await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
      await tester.pump();
      expect(store.sidebarHidden, isTrue);

      // Quem tira da tela é o `main.dart`, um nível acima -- a lateral montada
      // sozinha neste teste continua desenhada, e é por ela que se volta.
      await tester.tap(find.byIcon(Icons.view_sidebar_outlined));
      await tester.pump();
      expect(store.sidebarHidden, isFalse);
      await closeWindow(tester, store);
    });

    test('escondida, ela guarda a largura que tinha', () {
      final store = storeWithFolder();
      addTearDown(store.dispose);

      store.setSidebarWidth(420);
      store.toggleSidebar();

      // Duas coisas e não uma: quem volta pela aba da borda volta na largura
      // que deixou, e não no padrão.
      expect(store.sidebarHidden, isTrue);
      expect(store.sidebarWidth, 420);
    });

    test('e continua escondida na próxima abertura', () async {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      final file = File(store.configPath);
      if (file.existsSync()) file.deleteSync();

      store.toggleSidebar();
      expect((await savedConfig(store))['sidebarHidden'], isTrue);

      // De volta à tela, o config volta a não falar do assunto: o padrão é
      // ela estar aqui.
      file.deleteSync();
      store.toggleSidebar();
      expect((await savedConfig(store)).containsKey('sidebarHidden'), isFalse);
    });

    testWidgets('a busca traz a lateral de volta antes de procurar', (tester) async {
      final store = storeWithFolder();
      await pumpKeys(tester, store);
      store.toggleSidebar();

      // Sem isto o ⌘F mandava o foco pra um campo que não estava na árvore, e
      // a tecla não fazia nada em tela nenhuma.
      await press(tester, LogicalKeyboardKey.keyF, holding: [LogicalKeyboardKey.metaLeft]);
      expect(store.sidebarHidden, isFalse);
      await closeWindow(tester, store);
    });
  });
}
