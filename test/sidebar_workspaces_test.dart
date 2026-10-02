import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/sidebar.dart';

AppStore storeWith(List<String> names) {
  final store = AppStore();
  for (final n in names) {
    store.folders.add(Folder(root: '/repos/$n', name: n)..isRepo = true);
  }
  return store;
}

Folder named(AppStore s, String name) => s.folders.firstWhere((f) => f.name == name);

/// Como a janela monta a lateral: dentro de um [AnimatedBuilder] que escuta o
/// store, senão dobrar muda o estado e não redesenha nada.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 660,
        height: 900,
        child: AnimatedBuilder(animation: store, builder: (_, _) => Sidebar(store: store)),
      ),
    ),
  ),
);

/// O cabeçalho de um workspace na tela, pelo nome.
Rect header(WidgetTester tester, String name) => tester.getRect(
  find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first,
);

/// Pega [from] pelo meio e solta em [to], como um mouse faria.
Future<void> dragTo(WidgetTester tester, String from, Offset to) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(from).first),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  // O store descartado no fim do corpo, não num addTearDown: o salvamento com
  // atraso que criar um workspace agenda tem que ser cancelado antes de o
  // teste conferir os timers pendentes -- e deixá-lo disparar gravaria o
  // config de verdade.
  testWidgets('a pasta espelhada aparece completa nos dois workspaces', (tester) async {
    final store = storeWith(['atrium-api', 'infra']);
    store.createWorkspace('ATRIUM', folders: [named(store, 'atrium-api'), named(store, 'infra')]);
    store.createWorkspace('UPLII', folders: [named(store, 'infra')]);

    await pumpSidebar(tester, store);

    expect(find.text('ATRIUM'), findsOneWidget);
    expect(find.text('UPLII'), findsOneWidget);
    expect(find.text('infra'), findsNWidgets(2));
    expect(find.text('2 pastas'), findsOneWidget);
    expect(find.text('1 pasta'), findsOneWidget);
    store.dispose();
  });

  testWidgets('dobrar a pasta num workspace não dobra no outro', (tester) async {
    final store = storeWith(['infra']);
    final infra = named(store, 'infra');
    final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
    store.createWorkspace('UPLII', folders: [infra]);
    store.tabs.add(
      MxTab(id: 't1', folder: infra, kind: TabKind.shell, cwd: infra.root, branch: '', customLabel: 'servidor'),
    );
    await pumpSidebar(tester, store);
    expect(find.text('servidor'), findsNWidgets(2));

    await tester.tap(find.text('infra').first);
    await tester.pump();

    expect(store.isFolderCollapsed(infra, within: atrium), isTrue);
    expect(find.text('servidor'), findsOneWidget);
    store.dispose();
  });

  testWidgets('o workspace vazio continua na lateral', (tester) async {
    final store = storeWith(['solta']);
    store.createWorkspace('ATRIUM');

    await pumpSidebar(tester, store);

    expect(find.text('ATRIUM'), findsOneWidget);
    expect(find.text('0 pastas'), findsOneWidget);
    expect(find.text('arraste uma pasta pra cá'), findsOneWidget);
    store.dispose();
  });

  testWidgets('a pasta sem cor pega a do workspace na linha dela', (tester) async {
    final store = storeWith(['infra']);
    store.setWorkspaceTint(store.createWorkspace('ATRIUM', folders: [named(store, 'infra')]), MxTint.red);

    await pumpSidebar(tester, store);

    final glyph = tester.widget<RepoGlyph>(find.byType(RepoGlyph));
    expect(glyph.color, MxTint.red.color);
    store.dispose();
  });

  testWidgets('solta no meio do cabeçalho, a pasta entra no workspace', (tester) async {
    final store = storeWith(['solta', 'api']);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await dragTo(tester, 'solta', header(tester, 'ATRIUM').center);

    expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta']);
    store.dispose();
  });

  // Review Focus 4.
  testWidgets('solta na borda do cabeçalho, a pasta só reordena', (tester) async {
    final store = storeWith(['solta', 'api']);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    final h = header(tester, 'ATRIUM');
    await dragTo(tester, 'solta', Offset(h.center.dx, h.bottom - 2));

    expect(store.foldersOf(ws).map((f) => f.name), ['api']);
    expect(store.sidebarRows.first, ws);
    store.dispose();
  });

  testWidgets('arrastada pra uma linha da raiz, a pasta sai do workspace', (tester) async {
    final store = storeWith(['api', 'solta']);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await dragTo(tester, 'api', tester.getCenter(find.text('solta')));

    expect(store.foldersOf(ws), isEmpty);
    expect(store.standsAlone(named(store, 'api')), isTrue);
    store.dispose();
  });
}
