import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_modal.dart';

/// Um plugin com tela própria, como o Wiboor, e a janela com duas sessões lado
/// a lado, a da direita em foco.
({AppStore store, MxPlugin plugin, MxTab right}) desk(Directory tmp) {
  final dir = Directory('${tmp.path}/wiboor')..createSync(recursive: true);
  File('${dir.path}/$mxManifestName').writeAsStringSync(
    jsonEncode({
      'id': 'wiboor',
      'name': 'Wiboor',
      'version': '1',
      'icon': 'terminal',
      'main': ['true'],
      'contributes': {
        'screen': {'home': 'quadro'},
        'commands': [
          {'id': 'quadro', 'title': 'wiboor: o quadro'},
        ],
      },
    }),
  );
  final store = AppStore();
  store.plugins.all.addAll((Plugins(root: tmp.path)..scan()).all);
  final folder = Folder(root: '/repo/app', name: 'app');
  store.folders.add(folder);
  MxTab session(String id) => MxTab(
    id: id,
    folder: folder,
    kind: TabKind.shell,
    cwd: folder.root,
    branch: '',
    customLabel: id,
  );
  final left = session('esquerda');
  final right = session('direita');
  store.tabs.addAll([left, right]);
  store.panes = PaneSplit(PaneAxis.row, [PaneLeaf(left.id), PaneLeaf(right.id)], [0.3, 0.7]);
  store.focusedPaneId = right.id;
  return (store: store, plugin: store.plugins.byId('wiboor')!, right: right);
}

List<Map<String, dynamic>> text(String t) => [
  {'type': 'text', 'text': t},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mx-modal-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('a janela em modal', () {
    test('fica fora da grade, atualiza e, fechada, o plugin fica sabendo', () {
      final d = desk(tmp);
      final tab = d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('a'),
        modal: true,
      );
      expect(d.store.pluginModal, tab);
      expect(d.store.tabs, isNot(contains(tab)), reason: 'não é painel de grade nenhuma');
      expect(Panes.has(d.store.panes, tab.id), isFalse);
      expect(d.store.focusedPaneId, d.right.id, reason: 'o foco da grade fica onde estava');

      expect(d.store.updatePluginView(d.plugin, 'tarefa.1', blocks: text('b')), isTrue);
      expect(tab.view!.blocks.single['text'], 'b');

      // Pedir de novo a mesma: continua em modal, com o conteúdo novo.
      final again = d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('c'),
      );
      expect(again, same(tab));
      expect(d.store.pluginModal, tab);
      expect(d.store.tabs, isNot(contains(tab)));

      d.store.closeModal();
      expect(d.store.pluginModal, isNull);
      expect(d.store.updatePluginView(d.plugin, 'tarefa.1', blocks: text('d')), isFalse);
    });

    test('"abrir como painel" a põe na grade, em foco, com o mesmo viewId', () {
      final d = desk(tmp);
      final tab = d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('a'),
        modal: true,
      );
      d.store.dockModal();
      expect(d.store.pluginModal, isNull);
      expect(d.store.tabs, contains(tab));
      expect(Panes.has(d.store.panes, tab.id), isTrue);
      expect(d.store.focusedPaneId, tab.id);
      expect(d.store.updatePluginView(d.plugin, 'tarefa.1', blocks: text('b')), isTrue);
      // Já é painel: pedir em modal de novo só a traz pra frente.
      d.store.openPluginView(d.plugin, 'tarefa.1', title: 'TASK#1', blocks: text('c'), modal: true);
      expect(d.store.pluginModal, isNull);
    });

    test('um modal novo toma o lugar do outro; view.close fecha o modal', () {
      final d = desk(tmp);
      d.store.openPluginView(d.plugin, 'tarefa.1', title: '1', blocks: text('a'), modal: true);
      final two = d.store.openPluginView(
        d.plugin,
        'tarefa.2',
        title: '2',
        blocks: text('b'),
        modal: true,
      );
      expect(d.store.pluginModal, two);
      expect(d.store.updatePluginView(d.plugin, 'tarefa.1', blocks: text('x')), isFalse);
      d.store.closePluginView(d.plugin, 'tarefa.2');
      expect(d.store.pluginModal, isNull);
      expect(d.store.tabs.where((t) => t.isPluginView), isEmpty);
    });

    testWidgets('o desenho: o conteúdo, o "abrir como painel", o esc e o clique fora', (
      tester,
    ) async {
      final d = desk(tmp);
      Future<void> pump() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 1200, height: 900, child: PluginModalLayer(store: d.store)),
          ),
        ),
      );
      d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('o conteúdo'),
        modal: true,
      );
      await pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('o conteúdo'), findsOneWidget);
      expect(find.text('TASK#1'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(d.store.pluginModal, isNull);
      expect(find.text('o conteúdo'), findsNothing);

      d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('o conteúdo'),
        modal: true,
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(d.store.pluginModal, isNull, reason: 'o clique fora fecha');

      final tab = d.store.openPluginView(
        d.plugin,
        'tarefa.1',
        title: 'TASK#1',
        blocks: text('o conteúdo'),
        modal: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('o conteúdo'));
      await tester.pumpAndSettle();
      expect(d.store.pluginModal, tab, reason: 'o clique dentro não fecha');
      await tester.tap(find.text('abrir como painel'));
      await tester.pumpAndSettle();
      expect(d.store.pluginModal, isNull);
      expect(d.store.tabs, contains(tab));
    });
  });
}
