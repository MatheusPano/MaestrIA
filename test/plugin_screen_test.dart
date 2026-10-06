import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/panes.dart';

/// Um plugin com tela própria, como o Wiboor: o quadro é o comando de abertura.
Map<String, dynamic> board({Object? screen = const {'home': 'quadro'}, List<String>? main}) => {
  'id': 'wiboor',
  'name': 'Wiboor',
  'version': '1',
  'icon': 'terminal',
  'main': main ?? ['true'],
  'contributes': {
    'screen': ?screen,
    'commands': [
      {'id': 'quadro', 'title': 'wiboor: o quadro'},
    ],
  },
};

/// Um plugin sem tela: a aba dele é da tela das sessões, como a do git.
const git = {
  'id': 'git',
  'name': 'Git',
  'version': '1',
  'icon': 'terminal',
  'contributes': {
    'commands': [
      {'id': 'status', 'title': 'git: status', 'run': 'true'},
    ],
  },
};

void writePlugin(Directory parent, String name, Map<String, dynamic> manifest, [String? script]) {
  final dir = Directory('${parent.path}/$name')..createSync(recursive: true);
  File('${dir.path}/$mxManifestName').writeAsStringSync(jsonEncode(manifest));
  if (script != null) {
    File('${dir.path}/plugin.sh').writeAsStringSync(script);
    Process.runSync('chmod', ['+x', '${dir.path}/plugin.sh']);
  }
}

/// A janela com duas sessões lado a lado, a da direita em foco, e os plugins
/// de [tmp] instalados.
({AppStore store, MxTab left, MxTab right}) desk(Directory tmp) {
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
  return (store: store, left: left, right: right);
}

MxTab open(AppStore store, String viewId) =>
    store.openPluginView(store.plugins.byId('wiboor')!, viewId, title: viewId, blocks: const []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mx-screen-'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('o manifesto', () {
    PluginManifest read(Map<String, dynamic> manifest) {
      writePlugin(tmp, 'p', manifest);
      return PluginManifest.read('${tmp.path}/p');
    }

    test('true, ou o comando que monta a tela', () {
      expect(read(board(screen: true)).screen, isTrue);
      expect(read(board(screen: true)).screenHome, isNull);
      final home = read(board());
      expect(home.screen, isTrue);
      expect(home.screenHome, 'quadro');
      expect(read(board(screen: null)).screen, isFalse);
    });

    test('um "home" que não é comando do plugin, ou tela sem processo, é recusado', () {
      expect(() => read(board(screen: {'home': 'outro'})), throwsFormatException);
      expect(() => read(board(screen: 'sim')), throwsFormatException);
      final noMain = board(screen: true)..remove('main');
      (noMain['contributes'] as Map)['commands'] = [
        {'id': 'quadro', 'title': 'quadro', 'run': 'true'},
      ];
      expect(() => read(noMain), throwsFormatException);
    });
  });

  group('a tela do plugin', () {
    test('o terminal do plugin mora na tela dele, ao lado da janela, e não toma o lugar dela', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      MxTab owned(String id) {
        final t = MxTab(id: id, folder: store.loose, kind: TabKind.shell, cwd: '/', branch: '')
          ..owner = 'wiboor';
        store.tabs.add(t);
        return t;
      }

      final grade = open(store, 'hosts');
      final um = owned('ssh-1');
      store.select(um);
      expect(store.screen, 'wiboor', reason: 'não leva pra tela das sessões');
      expect(store.shownPlugin?.id, 'wiboor', reason: 'a lateral continua a do plugin');
      expect(store.openPanes, [grade, um], reason: 'ao lado da grade');

      // Com a grade em foco, a segunda conexão troca a primeira em vez de
      // picar a tela.
      store.focusPane(grade);
      final dois = owned('ssh-2');
      store.select(dois);
      expect(store.openPanes, [grade, dois]);

      store.showSidebarView(null);
      expect(store.openPanes, [left, right]);
      store.dispose();
    });

    test('levar a janela pras sessões a põe ao lado do painel em foco lá, e ela volta', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      final quadro = open(store, 'quadro');
      final tarefa = open(store, 'tarefa-1');

      store.releaseView(tarefa);
      expect(store.screen, isNull, reason: 'vai junto pra tela das sessões');
      expect(store.shownPlugin, isNull);
      expect(store.openPanes, [left, right, tarefa], reason: 'à direita da que estava em foco');
      expect(store.focusedTab, tarefa);
      expect(store.screenOf(tarefa), isNull);

      // O quadro ficou sozinho na tela dele.
      store.showSidebarView('wiboor');
      expect(store.openPanes, [quadro]);

      // Clicar de novo na tarefa no quadro leva pra onde ela mora agora.
      open(store, 'tarefa-1');
      expect(store.screen, isNull);
      expect(store.openPanes, [left, right, tarefa], reason: 'sem abrir uma segunda');

      store.returnView(tarefa);
      expect(store.screen, 'wiboor');
      expect(store.openPanes, [quadro, tarefa]);
      store.showSidebarView(null);
      expect(store.openPanes, [left, right]);
      store.dispose();
    });

    test('a janela dele abre numa tela só dela, e voltar devolve a grade como estava', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      final before = store.panes;

      final quadro = open(store, 'quadro');
      expect(store.screen, 'wiboor');
      expect(store.shownPlugin?.id, 'wiboor', reason: 'a lateral vai junto');
      expect(store.openPanes, [quadro], reason: 'o quadro ocupa a tela inteira');
      expect(store.isOpen(right), isFalse);

      final tarefa = open(store, 'tarefa-1');
      expect(store.openPanes, [quadro, tarefa], reason: 'a tarefa abre ao lado do quadro');

      store.showSidebarView(null);
      expect(store.screen, isNull);
      expect(store.panes, same(before), reason: 'a mesma árvore, com os mesmos cortes');
      expect((store.panes! as PaneSplit).weights, [0.3, 0.7]);
      expect(store.focusedPaneId, right.id);
      expect(store.openPanes, [left, right]);

      store.showSidebarView('wiboor');
      expect(store.openPanes, [quadro, tarefa]);
      expect(store.focusedPaneId, tarefa.id, reason: 'o foco que a tela tinha');
      store.dispose();
    });

    test('escolher uma sessão sai do quadro e volta pra grade das sessões', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      open(store, 'quadro');

      store.select(left);
      expect(store.screen, isNull);
      expect(store.shownPlugin, isNull, reason: 'a lateral volta pra lista das sessões');
      expect(store.openPanes, [left, right]);
      expect(store.focusedPaneId, left.id);
      store.dispose();
    });

    test('a aba de um plugin sem tela é da tela das sessões', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      writePlugin(tmp, 'git', git);
      final (:store, :left, :right) = desk(tmp);
      open(store, 'quadro');

      store.showSidebarView('git');
      expect(store.screen, isNull);
      expect(store.shownPlugin?.id, 'git');
      expect(store.openPanes, [left, right]);

      // E a janela do quadro, pedida com a aba do git na lateral, leva pra
      // tela dela -- a lateral junto.
      open(store, 'quadro');
      expect(store.screen, 'wiboor');
      expect(store.shownPlugin?.id, 'wiboor');

      // Uma sessão escolhida a partir daí volta com a lista das sessões, e não
      // com a aba do git que estava antes: quem estava na lateral era o quadro.
      store.select(right);
      expect(store.shownPlugin, isNull);
      store.dispose();
    });

    test('andar pelas sessões não cai no quadro, nem andar pelas janelas cai numa sessão', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      final quadro = open(store, 'quadro');
      final tarefa = open(store, 'tarefa-1');

      store.cycle(1);
      expect(store.screen, 'wiboor');
      expect(store.focusedTab, quadro, reason: 'da tarefa, a volta é o quadro');

      store.select(right);
      store.cycle(1);
      expect(store.screen, isNull);
      expect(store.focusedTab, left);
      expect(store.isOpen(tarefa), isFalse);
      store.dispose();
    });

    test('um plugin sem tela continua abrindo as janelas na grade das sessões', () {
      writePlugin(tmp, 'wiboor', board(screen: null));
      final (:store, :left, :right) = desk(tmp);
      final quadro = open(store, 'quadro');
      expect(store.screen, isNull);
      expect(store.openPanes, [left, right, quadro]);
      store.dispose();
    });

    test('fechar o que mora na tela guardada tira da tela guardada', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      final quadro = open(store, 'quadro');

      store.closeTab(right);
      expect(store.openPanes, [quadro], reason: 'a tela do quadro não muda');
      store.showSidebarView(null);
      expect(store.openPanes, [left], reason: 'sem um buraco onde a sessão estava');
      expect(store.focusedTab, left);
      store.dispose();
    });

    test('fechar a última janela do quadro não joga você numa sessão', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      final quadro = open(store, 'quadro');

      store.closeTab(quadro);
      expect(store.screen, 'wiboor');
      expect(store.panes, isNull);
      store.showSidebarView(null);
      expect(store.openPanes, [left, right]);
      store.dispose();
    });

    test('um painel preso na grade das sessões continua preso enquanto você está no quadro', () {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      store.togglePin(left);
      open(store, 'quadro');
      // O save roda a faxina dos presos fora da tela.
      store.showSidebarView('wiboor');
      expect(left.pinned, isTrue);
      store.showSidebarView(null);
      expect(store.isPinned(left), isTrue);
      store.dispose();
    });

    test('desligar o plugin com a tela dele na vista volta pras sessões', () async {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      open(store, 'quadro');

      await store.setPluginEnabled(store.plugins.byId('wiboor')!, false);
      expect(store.screen, isNull);
      expect(store.shownPlugin, isNull);
      expect(store.openPanes, [left, right]);
      store.dispose();
    });

    test('o config guarda a grade das sessões, mesmo com o quadro na vista', () async {
      writePlugin(tmp, 'wiboor', board(screen: true));
      final (:store, :left, :right) = desk(tmp);
      open(store, 'quadro');
      store.showSidebarView('wiboor');
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final j = jsonDecode(File(store.configPath).readAsStringSync()) as Map<String, dynamic>;
      final layout = j['layout'] as Map<String, dynamic>;
      final saved = [for (final p in layout['panes'] as List) (p as Map)['label']];
      expect(saved, ['esquerda', 'direita'], reason: 'a janela do plugin não vai pro config');
      expect(layout['tree'], isNotNull);
      expect(layout['focused'], 1, reason: 'o foco que a grade das sessões tinha');
      expect(j['sidebarView'], 'wiboor');
      store.dispose();
    });

    testWidgets('a tela vazia diz de quem é, e oferece o comando de abertura', (tester) async {
      writePlugin(tmp, 'wiboor', board());
      final (:store, left: _, right: _) = desk(tmp);
      final quadro = open(store, 'quadro');
      store.closeTab(quadro);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: store,
              builder: (context, _) => PaneArea(store: store),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('nada aberto do Wiboor'), findsOneWidget);
      expect(find.text('wiboor: o quadro'), findsOneWidget);
      store.dispose();
    });
  });

  test('o clique no ícone abre a tela vazia já com o comando de abertura', () async {
    // O quadro de verdade: o comando chega no processo, e ele responde abrindo
    // a janela do quadro.
    const script = r'''#!/bin/sh
idof() { echo "$1" | sed 's/.*"id":\([0-9]*\).*/\1/'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":{}}" ;;
    *'"method":"command.invoke"'*)
      echo '{"jsonrpc":"2.0","id":"p1","method":"view.open","params":{"viewId":"quadro","title":"Quadro","blocks":[]}}'
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":null}" ;;
    *'"method":"shutdown"'*)
      exit 0 ;;
  esac
done
''';
    writePlugin(tmp, 'wiboor', board(main: ['./plugin.sh']), script);
    final (:store, :left, :right) = desk(tmp);
    store.plugins.onCall = PluginApi(store).handle;
    addTearDown(store.plugins.stopAll);

    store.showSidebarView('wiboor');
    expect(store.screen, 'wiboor');
    for (var i = 0; i < 100 && store.panes == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(store.openPanes.map((t) => t.view?.id), ['quadro']);

    // Com o quadro aberto, voltar e vir de novo não abre outro.
    store.showSidebarView(null);
    expect(store.openPanes, [left, right]);
    store.showSidebarView('wiboor');
    expect(store.openPanes.map((t) => t.view?.id), ['quadro']);
  });
}
