import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
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

MxTab panel(AppStore store, String name, {Folder? folder}) {
  final where = folder ?? store.folders.first;
  final tab = MxTab(
    id: name,
    folder: where,
    kind: TabKind.claude,
    cwd: where.root,
    branch: '',
    customLabel: name,
  );
  store.tabs.add(tab);
  return tab;
}

/// Wide enough for the header rows to fit — see worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(width: 660, height: 900, child: Sidebar(store: store)),
    ),
  ),
);

/// Parks a mouse on a row and leaves it there: the + only exists while the
/// pointer is on the header it rides on.
Future<void> hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  // Not pumpAndSettle: a claude row's mark animates forever, so a settle with
  // one of them on screen never comes.
  await tester.pump(const Duration(milliseconds: 200));
}

double opacityOf(WidgetTester tester, String tooltip) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

void main() {
  group('the loose tray', () {
    testWidgets('is a divider, not a folder', (tester) async {
      final store = storeWithFolder();
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      expect(find.text('avulsos'), findsOneWidget);
      // Nothing to fold: the one open chevron on screen is the real folder's.
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      // And nothing that says "directory": no glyph, no explaining subtitle.
      expect(find.byIcon(Icons.scatter_plot_outlined), findsNothing);
      expect(find.text('fora de qualquer pasta'), findsNothing);
      expect(find.byType(RepoGlyph), findsOneWidget);
    });

    testWidgets('hangs its panels at the top level, not stepped in', (tester) async {
      final store = storeWithFolder();
      panel(store, 'na pasta');
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      // A folder's panels are inside it and carry the step to prove it. The
      // tray's are inside nothing, so they start further left.
      final nested = tester.getTopLeft(find.text('na pasta')).dx;
      final loose = tester.getTopLeft(find.text('solto')).dx;
      expect(loose, lessThan(nested));
    });

    testWidgets('counts what is in it, and keeps quiet when empty', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);
      // The folder's own zero is the only count on screen.
      expect(find.text('0'), findsOneWidget);

      panel(store, 'solto', folder: store.loose);
      panel(store, 'outro', folder: store.loose);
      await pumpSidebar(tester, store);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('offers what you can start here behind one +', (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);

      // No chips under the rows any more: one + on the tray's own line.
      expect(find.text('terminal'), findsNothing);
      await tester.tap(find.byTooltip('abrir algo sem pasta'));
      await tester.pumpAndSettle();

      expect(find.text('sessão do claude'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      // The tray stops at those two: there is nothing for a project to be in.
      expect(find.text('projeto…'), findsNothing);
    });

    testWidgets("and a folder's + adds the project the tray cannot", (tester) async {
      final store = storeWithFolder();
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('abrir algo nessa pasta'));
      await tester.pumpAndSettle();
      expect(find.text('projeto…'), findsOneWidget);
    });

    testWidgets('the + waits for the pointer once there is a row to hover', (tester) async {
      final store = storeWithFolder();
      panel(store, 'na pasta');
      panel(store, 'solto', folder: store.loose);
      await pumpSidebar(tester, store);

      // Something in both groups, so neither + is the only thing to aim at.
      expect(opacityOf(tester, 'abrir algo nessa pasta'), 0);
      expect(opacityOf(tester, 'abrir algo sem pasta'), 0);

      await hover(tester, find.text('meu-repo'));
      expect(opacityOf(tester, 'abrir algo nessa pasta'), 1);
      // One row at a time: the tray's stays down.
      expect(opacityOf(tester, 'abrir algo sem pasta'), 0);
    });
  });
}
