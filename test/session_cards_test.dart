import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/terminal_pane.dart';

MxTab panel(AppStore store, String id, TabKind kind, {String? label}) {
  final tab = MxTab(
    id: id,
    folder: store.folders.first,
    kind: kind,
    cwd: '/repo',
    branch: 'feature/TASK#1',
    customLabel: label,
  );
  store.tabs.add(tab);
  return tab;
}

Future<void> pumpEmpty(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 900,
          child: ListenableBuilder(
            listenable: store,
            builder: (_, _) => EmptyPane(store: store),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppStore store;
  setUp(() {
    store = AppStore();
    store.folders.add(Folder(root: '/repo', name: 'meu-repo')..isRepo = true);
  });
  // Ao fim do corpo, e não no tearDown: é o dispose que cancela o salvamento
  // que o clique agenda, e o teste reclama de timer pendente antes disso.

  testWidgets('sem sessões, a tela vazia é a dos apps', (tester) async {
    await pumpEmpty(tester, store);
    expect(find.text('O que vamos abrir?'), findsOneWidget);
    expect(find.text('Instalar plugin'), findsOneWidget);
    expect(find.text('Plugins'), findsNothing);
    expect(find.text('Esperando você'), findsNothing);
    store.dispose();
  });

  testWidgets('as sessões da lateral viram cartões, separadas pelo que pedem', (tester) async {
    final asking = panel(store, 'a', TabKind.claude, label: 'pede permissão');
    asking.hooks
      ..status = ClaudeStatus.waitingPermission
      ..activeTool = 'Bash';
    // Parada sem você ver, escrito à mão: pelo hook, o `Stop` ainda tocaria o
    // aviso do sistema.
    panel(store, 'b', TabKind.claude, label: 'terminou')
      ..hooks.status = ClaudeStatus.idle
      ..restedAt = DateTime.now()
      ..unseen = true;
    panel(store, 'c', TabKind.shell, label: 'um shell');

    await pumpEmpty(tester, store);

    expect(find.text('pede permissão'), findsOneWidget);
    expect(find.text('terminou'), findsOneWidget);
    expect(find.text('um shell'), findsOneWidget);
    expect(find.text('Terminaram enquanto você não via'), findsOneWidget);
    expect(find.text('Em repouso'), findsOneWidget);
    expect(find.text('Esperando você'), findsOneWidget);
    expect(find.text('Quer aprovação pra Bash'), findsOneWidget);
    // A ordem é a da urgência, e não a da lista.
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('pede permissão'), lessThan(top('terminou')));
    expect(top('terminou'), lessThan(top('um shell')));
    store.dispose();
  });

  testWidgets('clicar num cartão traz a sessão pra tela', (tester) async {
    final tab = panel(store, 'a', TabKind.shell, label: 'um shell');
    await pumpEmpty(tester, store);

    await tester.tap(find.text('um shell'));
    await tester.pump();

    expect(store.isOpen(tab), isTrue);
    store.dispose();
  });

  testWidgets('os plugins da faixa ficam no topo, e o clique abre a aba deles', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('mx-empty-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dir = Directory('${tmp.path}/git')..createSync();
    File('${dir.path}/$mxManifestName').writeAsStringSync(
      jsonEncode({
        'id': 'git',
        'name': 'Git',
        'version': '1',
        'description': 'O status do repo',
        'icon': 'terminal',
        'contributes': {
          'commands': [
            {'id': 'status', 'title': 'git: status', 'run': 'true'},
          ],
        },
      }),
    );
    store.plugins.all.addAll((Plugins(root: tmp.path)..scan()).all);
    expect(store.railPlugins.map((p) => p.id), ['git']);

    await pumpEmpty(tester, store);
    // Sem sessão nenhuma, os plugins são a tela: ladrilhos grandes, sem a
    // faixa de "Plugins" que fica por cima dos cartões.
    expect(find.text('O que vamos abrir?'), findsOneWidget);
    expect(find.text('O status do repo'), findsOneWidget);
    expect(find.text('Instalar plugin'), findsOneWidget);

    await tester.tap(find.text('Git'));
    await tester.pump();
    expect(store.shownPlugin?.id, 'git');

    // O ladrilho é sempre "abrir": clicar de novo não esconde a lateral, como
    // o ícone aceso da faixa faria.
    await tester.tap(find.text('Git'));
    await tester.pump();
    expect(store.sidebarHidden, isFalse);

    // Com uma sessão, eles sobem pra faixa e os cartões tomam o meio.
    panel(store, 'a', TabKind.shell, label: 'um shell');
    store.notifyListeners();
    await tester.pump();
    expect(find.text('O que vamos abrir?'), findsNothing);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('O status do repo'), findsOneWidget);
    expect(find.text('um shell'), findsOneWidget);
    store.dispose();
  });
}
