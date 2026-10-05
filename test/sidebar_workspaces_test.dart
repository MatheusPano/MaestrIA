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

/// O campo do diálogo aberto: a lateral tem o dela (a busca), e `byType` sozinho
/// acharia os dois.
final dialogField = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

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
    expect(find.text('Arraste uma pasta pra cá'), findsOneWidget);
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

  // Só pasta entra num workspace: um workspace no meio do cabeçalho de outro
  // reordena, como o cabeçalho inteiro fazia antes das duas zonas.
  testWidgets('um workspace solto no meio do cabeçalho de outro só reordena', (tester) async {
    final store = storeWith(['api', 'web']);
    final atrium = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    final uplii = store.createWorkspace('UPLII', folders: [named(store, 'web')]);
    await pumpSidebar(tester, store);
    List<String> order() => store.sidebarRows.map((r) => (r as Workspace).name).toList();
    expect(order(), ['ATRIUM', 'UPLII']);

    await dragTo(tester, 'ATRIUM', header(tester, 'UPLII').center);

    expect(order(), ['UPLII', 'ATRIUM']);
    expect(store.foldersOf(atrium).map((f) => f.name), ['api']);
    expect(store.foldersOf(uplii).map((f) => f.name), ['web']);
    store.dispose();
  });

  testWidgets('o + do rodapé oferece pasta, import e workspace', (tester) async {
    final store = storeWith([]);
    addTearDown(store.dispose);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('Adicionar pasta ou workspace'));
    await tester.pumpAndSettle();

    expect(find.text('Adicionar pasta…'), findsOneWidget);
    expect(find.text('Importar .code-workspace…'), findsOneWidget);
    expect(find.text('Novo workspace…'), findsOneWidget);
  });

  testWidgets('o diálogo cria o workspace com o nome e as pastas marcadas', (tester) async {
    final store = storeWith(['atrium-api', 'atrium-web', 'infra']);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('Adicionar pasta ou workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo workspace…'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, 'ATRIUM');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'atrium-api'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'atrium-web'));
    await tester.tap(find.text('Criar'));
    await tester.pumpAndSettle();

    final ws = store.workspaces.single;
    expect(ws.name, 'ATRIUM');
    expect(store.foldersOf(ws).map((f) => f.name), ['atrium-api', 'atrium-web']);
    store.dispose();
  });

  testWidgets('o menu da pasta põe e tira de um workspace', (tester) async {
    final store = storeWith(['infra']);
    final ws = store.createWorkspace('ATRIUM');
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('O que fazer com essa pasta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar a workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ATRIUM').last);
    await tester.pumpAndSettle();
    expect(store.foldersOf(ws).single.name, 'infra');

    // Agora desenhada dentro do ATRIUM, o menu dela oferece sair.
    await tester.tap(find.byTooltip('O que fazer com essa pasta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tirar deste workspace'));
    await tester.pumpAndSettle();
    expect(store.foldersOf(ws), isEmpty);
    store.dispose();
  });

  testWidgets('o menu do workspace renomeia e desfaz', (tester) async {
    final store = storeWith(['api']);
    store.createWorkspace('atrium', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('O que fazer com esse workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Associar .code-workspace…'), findsOneWidget);
    expect(find.text('Abrir no vscode'), findsNothing);
    await tester.tap(find.text('Renomear…'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, 'ATRIUM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.workspaces.single.name, 'ATRIUM');

    await tester.tap(find.byTooltip('O que fazer com esse workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desfazer workspace'));
    await tester.pumpAndSettle();
    expect(store.workspaces, isEmpty);
    expect(store.folders.single.name, 'api');
    store.dispose();
  });

  testWidgets('com arquivo associado, o menu oferece abrir no vscode e desassociar', (tester) async {
    final store = storeWith(['api']);
    store.createWorkspace('ATRIUM', codeWorkspacePath: '/repos/atrium.code-workspace');
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('O que fazer com esse workspace'));
    await tester.pumpAndSettle();

    expect(find.text('Abrir no vscode'), findsOneWidget);
    expect(find.text('Desassociar .code-workspace'), findsOneWidget);
    store.dispose();
  });
}
