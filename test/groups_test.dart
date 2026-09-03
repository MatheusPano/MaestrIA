import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/sidebar.dart';

/// A grade do relato da task: três terminais, um à esquerda e dois empilhados
/// à direita.
///
/// Os painéis são montados à mão, sem [AppStore.openShell], porque o que está
/// em teste é o arranjo e não o pty: um painel de verdade sobe um processo, e
/// um painel montado aqui tem tudo que uma receita de grupo precisa saber.
AppStore gridOfThree() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo');
  store.folders.add(folder);
  for (final name in ['um', 'dois', 'tres']) {
    store.tabs.add(
      MxTab(
        id: name,
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: name,
      ),
    );
  }
  store.panes = PaneSplit(
    PaneAxis.row,
    [
      PaneLeaf('um'),
      PaneSplit(PaneAxis.column, [PaneLeaf('dois'), PaneLeaf('tres')], [0.5, 0.5]),
    ],
    [0.6, 0.4],
  );
  store.focusedPaneId = 'um';
  return store;
}

/// Uma quarta sessão, na lateral e fora da tela: é nela que se clica pra ver o
/// que um clique fora do grupo faz.
MxTab fourth(AppStore store) {
  final tab = MxTab(
    id: 'quatro',
    folder: store.folders.first,
    kind: TabKind.shell,
    cwd: '/repo',
    branch: '',
    customLabel: 'quatro',
  );
  store.tabs.add(tab);
  return tab;
}

/// O config que o store acabou de gravar. O save é debounced, então a leitura
/// espera o arquivo aparecer com os grupos dentro.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60; i++) {
    if (file.existsSync()) {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (j['groups'] case final List saved when saved.isNotEmpty) return j;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return const {};
}

/// Larga o bastante pros números e o ⋯ caberem na linha -- ver worktrees_test.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
  ),
);

/// O gesto novo: botão direito num painel da grade.
Future<void> openPanelMenu(WidgetTester tester, String row) async {
  await tester.tap(find.text(row), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  group('agrupar os painéis da tela', () {
    // Nenhum diálogo no meio do gesto: ele aponta pra grade montada e diz que
    // aqueles painéis andam juntos.
    test('batiza o grupo pelo que ele abre, sem perguntar nada', () {
      final store = gridOfThree();
      addTearDown(store.dispose);

      final group = store.groupPanes()!;
      expect(group.name, '3 terminais');
      expect(group.count, 3);
      expect(store.groups, hasLength(1));
      // A marca é o que faz a linha de cada painel ter a cor do grupo e abrir
      // o grupo em vez de trocar o quadro.
      expect(store.tabs.map((t) => t.groupId), everyElement(group.id));
    });

    test('um painel sozinho não é um conjunto', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      store.panes = PaneLeaf('um');
      expect(store.groupPanes(), isNull);
      expect(store.groups, isEmpty);
    });

    // Cair no nome do outro faria o segundo *atualizar* o primeiro.
    test('duas grades iguais não viram o mesmo grupo', () {
      final store = gridOfThree();
      addTearDown(store.dispose);

      final first = store.groupPanes()!;
      final second = store.groupPanes()!;
      expect(store.groups, hasLength(2));
      expect(first.name, '3 terminais');
      expect(second.name, '3 terminais (2)');
      expect(second.id, isNot(first.id));
    });

    test('desagrupar solta os painéis e não fecha nada', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;

      store.ungroup(group);
      expect(store.groups, isEmpty);
      expect(store.tabs, hasLength(3));
      expect(store.tabs.map((t) => t.groupId), everyElement(isNull));
      expect(Panes.count(store.panes), 3);
    });

    // A marca vale pelo grupo inteiro: um grupo atualizado com dois painéis
    // não pode deixar o terceiro pintado de um conjunto de que ele saiu.
    test('o painel que sai do grupo perde a marca', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;

      final left = store.tabs.last;
      store.dismiss(left);
      store.saveGroup(group.name);

      expect(left.groupId, isNull);
      expect(store.tabs.take(2).map((t) => t.groupId), everyElement(group.id));
      expect(store.groups.single.count, 2);
    });
  });

  group('a cor do grupo', () {
    test('é a mesma nos painéis dele, e não vaza pros de fora', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;
      final fora = fourth(store);

      final cores = store.tabs
          .where((t) => t.id != fora.id)
          .map((t) => store.groupOf(t)?.color)
          .toSet();
      expect(cores, hasLength(1));
      expect(cores.single, group.color);
      expect(Mx.groupTints, contains(group.color));
      expect(store.groupOf(fora), isNull);
    });

    // Sai do id, que está salvo: o grupo de ontem abre com a cor de ontem.
    test('é a mesma entre execuções', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;

      final back = PaneGroup.fromJson(jsonDecode(jsonEncode(group.toJson())))!;
      expect(back.color, group.color);
    });
  });

  group('a tela que é um grupo', () {
    test('é o grupo enquanto todos os painéis forem dele', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;
      expect(store.showing(group), isTrue);

      // Um painel de fora ocupando um dos quadros e a tela deixa de ser o
      // grupo -- sem ninguém ter que se lembrar de apagar a resposta.
      Panes.swap(store.panes, 'tres', fourth(store).id);
      expect(store.activeGroup, isNull);
      expect(store.showing(group), isFalse);
    });

    // O pedido: "se eu clicar em outro painel que não está no grupo, ele
    // substitui o grupo inteiro por esse".
    test('escolher uma sessão de fora substitui a tela toda', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final group = store.groupPanes()!;
      final fora = fourth(store);

      store.select(fora);
      expect(Panes.order(store.panes), ['quatro']);
      expect(store.focusedPaneId, 'quatro');
      // Substituir a tela não encerra nada: os três continuam na lateral, e o
      // grupo continua guardado pra voltar.
      expect(store.tabs, hasLength(4));
      expect(store.groups, contains(group));
      expect(store.activeGroup, isNull);
    });

    test('escolher um painel do próprio grupo não desmancha a grade', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      store.groupPanes();

      store.select(store.tabs.last);
      expect(Panes.count(store.panes), 3);
    });

    // O outro lado da regra, e o que ela protege: uma grade que você montou à
    // mão e não agrupou continua trocando o que está no lugar em foco.
    test('uma grade não agrupada continua trocando no lugar em foco', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final fora = fourth(store);

      store.select(fora);
      expect(Panes.count(store.panes), 3);
      // O quadro que estava em foco -- o primeiro -- é o que trocou de dono.
      expect(Panes.order(store.panes), ['quatro', 'dois', 'tres']);
    });
  });

  group('um grupo', () {
    test('guarda o arranjo da tela, e só o arranjo', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      // História da sessão: nada disto é o arranjo, e nada disto entra.
      store.tabs.first.hooks.touched.add('lib/main.dart');
      store.tabs.first.done = true;

      final saved = store.saveGroup('grid de 3')!;
      expect(saved.count, 3);
      expect(saved.summary, '3 terminais');
      expect(saved.where, 'repo');
      expect(saved.panes.map((p) => p['label']), ['um', 'dois', 'tres']);
      expect(saved.panes.first.containsKey('touched'), isFalse);
      expect(saved.panes.first.containsKey('done'), isFalse);
      // Nem a marca de grupo: um grupo que guardasse a que grupo o painel
      // pertence seria ele apontando pra si mesmo.
      expect(saved.panes.first.containsKey('group'), isFalse);

      // A árvore é a que estava na tela, com as folhas dizendo o índice do
      // painel na lista salva -- não o id da sessão, que não sobrevive ao
      // fechamento da janela.
      final tree = saved.tree! as Map;
      expect(tree['axis'], 'row');
      expect((tree['children'] as List).first, 0);
      expect(((tree['children'] as List)[1] as Map)['axis'], 'column');
      expect(((tree['children'] as List)[1] as Map)['children'], [1, 2]);
    });

    test('volta inteiro do config e remonta a grade', () async {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final file = File(store.configPath);
      if (file.existsSync()) file.deleteSync();

      final saved = store.groupPanes()!;
      final config = await savedConfig(store);
      final written = (config['groups'] as List).cast<Map<String, dynamic>>();
      expect(written, hasLength(1));

      final back = PaneGroup.fromJson(written.single)!;
      expect(back.id, saved.id);
      expect(back.name, '3 terminais');
      expect(back.count, 3);
      expect(jsonEncode(back.tree), jsonEncode(saved.tree));

      // A marca de cada painel viaja no layout, que é onde ela pertence: é o
      // que devolve a cor e o clique da linha depois de fechar a janela.
      final panes = ((config['layout'] as Map)['panes'] as List).cast<Map<String, dynamic>>();
      expect(panes.map((p) => p['group']), everyElement(saved.id));

      // E o grupo que voltou do disco abre a mesma grade que o que foi salvo.
      store.panes = null;
      store.openGroup(back);
      expect(Panes.order(store.panes), ['um', 'dois', 'tres']);
    });

    // O relato da task, inteiro: a grade de três, uma aba comum ocupando a
    // tela sozinha, e o grupo trazendo os três de volta como estavam.
    test('acionado, devolve os painéis e os cortes que tinha', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final saved = store.groupPanes()!;

      final fora = fourth(store);
      store.select(fora);
      expect(Panes.count(store.panes), 1);

      store.openGroup(saved);
      expect(Panes.order(store.panes), ['um', 'dois', 'tres']);
      // Os mesmos três painéis, não três novos ao lado deles.
      expect(store.tabs, hasLength(4));

      final root = store.panes! as PaneSplit;
      expect(root.axis, PaneAxis.row);
      expect(root.weights.first, closeTo(0.6, 0.001));
      final right = root.children[1] as PaneSplit;
      expect(right.axis, PaneAxis.column);
      expect(Panes.order(right), ['dois', 'tres']);
      expect(store.focusedPaneId, 'um');
      expect(store.showing(saved), isTrue);
    });

    // Dois "grid da manhã" na lateral seriam duas linhas iguais e nenhuma
    // forma de saber qual é qual.
    test('salvo com o nome de um que já existe, atualiza aquele', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final first = store.saveGroup('grid')!;

      store.dismiss(store.tabs.last);
      final again = store.saveGroup('GRID')!;

      expect(store.groups, hasLength(1));
      expect(again.id, first.id);
      expect(again.count, 2);
      expect(store.groups.single.name, 'GRID');
    });

    test('sem nada na tela não há arranjo pra guardar', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      store.panes = null;
      expect(store.saveGroup('vazio'), isNull);
      expect(store.saveGroup(''), isNull);
      expect(store.groupPanes(), isNull);
      expect(store.groups, isEmpty);
    });

    test('esquecido, não leva os painéis com ele', () {
      final store = gridOfThree();
      addTearDown(store.dispose);
      final saved = store.saveGroup('grid de 3')!;

      store.removeGroup(saved);
      expect(store.groups, isEmpty);
      expect(store.tabs, hasLength(3));
      expect(Panes.count(store.panes), 3);
    });

    // Um registro estragado não pode custar as pastas e o layout junto.
    test('sem nome, sem id ou sem painel, não volta do json', () {
      expect(PaneGroup.fromJson({'id': 'gp1', 'name': 'grid', 'panes': []}), isNull);
      expect(PaneGroup.fromJson({'id': 'gp1', 'name': '  ', 'panes': [{}]}), isNull);
      expect(PaneGroup.fromJson({'name': 'grid', 'panes': [{}]}), isNull);
      expect(PaneGroup.fromJson('grid'), isNull);
    });
  });

  group('a lateral', () {
    testWidgets('o botão direito de um painel da grade agrupa, e desagrupa', (tester) async {
      final store = gridOfThree();
      await pumpSidebar(tester, store);

      await openPanelMenu(tester, 'um');
      expect(find.text('agrupar painéis'), findsOneWidget);
      await tester.tap(find.text('agrupar painéis'));
      await tester.pumpAndSettle();
      expect(store.groups, hasLength(1));
      expect(store.groups.single.name, '3 terminais');

      // Agrupado, o mesmo menu oferece o caminho de volta -- e só ele.
      await openPanelMenu(tester, 'um');
      expect(find.text('agrupar painéis'), findsNothing);
      await tester.tap(find.text('desagrupar "3 terminais"'));
      await tester.pumpAndSettle();
      expect(store.groups, isEmpty);
      expect(store.tabs, hasLength(3));
      store.dispose();
    });

    // A grade remontada em volta de um painel que já é de um grupo é um
    // arranjo novo, e sem isso não haveria como guardá-lo.
    testWidgets('oferece agrupar de novo quando a tela deixou de ser o grupo', (tester) async {
      final store = gridOfThree();
      store.groupPanes();
      Panes.swap(store.panes, 'tres', fourth(store).id);
      await pumpSidebar(tester, store);

      await openPanelMenu(tester, 'um');
      expect(find.text('agrupar painéis'), findsOneWidget);
      expect(find.text('desagrupar "3 terminais"'), findsOneWidget);
      store.dispose();
    });

    testWidgets('não oferece agrupar um painel sozinho', (tester) async {
      final store = gridOfThree();
      store.panes = PaneLeaf('um');
      await pumpSidebar(tester, store);

      await openPanelMenu(tester, 'um');
      expect(find.text('agrupar painéis'), findsNothing);
      store.dispose();
    });

    testWidgets('clicar na linha de um painel do grupo abre o grupo', (tester) async {
      final store = gridOfThree();
      store.groupPanes();
      // O x do cabeçalho em cada um: saem da tela, continuam na lateral.
      for (final t in [...store.tabs]) {
        store.dismiss(t);
      }
      await pumpSidebar(tester, store);

      await tester.tap(find.text('um'));
      await tester.pump();
      expect(Panes.order(store.panes), ['um', 'dois', 'tres']);
      store.dispose();
    });

    testWidgets('clicar numa linha de fora troca o grupo inteiro por ela', (tester) async {
      final store = gridOfThree();
      store.groupPanes();
      fourth(store);
      await pumpSidebar(tester, store);

      await tester.tap(find.text('quatro'));
      await tester.pump();
      expect(Panes.order(store.panes), ['quatro']);
      store.dispose();
    });

    testWidgets('mostra os grupos no alto, e um clique abre a grade', (tester) async {
      final store = gridOfThree();
      final saved = store.saveGroup('grid da manhã')!;
      for (final t in [...store.tabs]) {
        store.dismiss(t);
      }

      await pumpSidebar(tester, store);
      expect(find.text('grupos'), findsOneWidget);
      expect(find.text(saved.name), findsOneWidget);
      // A linha diz o que o grupo abre: um nome sozinho não distingue a grade
      // de três terminais do par claude-e-terminal.
      expect(find.text('3 terminais'), findsOneWidget);

      await tester.tap(find.text(saved.name));
      await tester.pump();
      expect(Panes.order(store.panes), ['um', 'dois', 'tres']);
      store.dispose();
    });
  });
}
