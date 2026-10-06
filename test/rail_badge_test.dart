import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar_rail.dart';

/// Um plugin com aba na faixa, e o selo que ele pediu nela.
AppStore withBadge(Directory tmp, String badge) {
  final dir = Directory('${tmp.path}/ssh')..createSync(recursive: true);
  File('${dir.path}/$mxManifestName').writeAsStringSync(
    jsonEncode({
      'id': 'ssh',
      'name': 'SSH',
      'version': '1',
      'icon': 'terminal',
      'contributes': {
        'commands': [
          {'id': 'hosts', 'title': 'ssh: hosts…', 'run': 'true', 'sidebar': true},
        ],
      },
    }),
  );
  final store = AppStore();
  store.plugins.all.addAll((Plugins(root: tmp.path)..scan()).all);
  store.sidebarBadges['ssh'] = badge;
  return store;
}

Future<void> pumpRail(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 700, child: SidebarRail(store: store)),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('maestria-rail'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // O teto do selo fez todo selo crescer até ele: um Container com
  // `alignment` ocupa a largura máxima que tiver, e o "▶" de um plugin virou
  // uma pílula da largura do ícone.
  testWidgets('um selo curto é do tamanho do texto, não do teto', (tester) async {
    final store = withBadge(tmp, '▶');
    await pumpRail(tester, store);
    final badge = find.ancestor(of: find.text('▶'), matching: find.byType(Container)).first;
    expect(tester.getSize(badge).width, lessThan(24));
    store.dispose();
  });

  testWidgets('um selo comprido para no teto e não vaza da faixa', (tester) async {
    final store = withBadge(tmp, 'três arquivos');
    await pumpRail(tester, store);
    final badge = find.ancestor(of: find.text('três arquivos'), matching: find.byType(Container));
    expect(tester.getSize(badge.first).width, lessThanOrEqualTo(SidebarRail.width - 4));
    store.dispose();
  });
}
