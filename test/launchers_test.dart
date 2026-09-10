import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/sidebar.dart';

/// O config que o store acabou de gravar. O save é debounced, então o arquivo
/// sai do caminho primeiro e a leitura espera ele reaparecer -- o mesmo
/// caminho de `config_test.dart`.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// Um painel de programa montado à mão, sem [AppStore.openLauncher]: o que
/// está em teste aqui é o que o painel *diz* de si, e um painel de verdade
/// subiria um processo pra dizer a mesma coisa.
MxTab paneOf(Launcher launcher, Folder folder) => MxTab(
  id: 'tab1',
  folder: folder,
  kind: TabKind.shell,
  cwd: folder.root,
  branch: '',
  launcher: launcher,
);

void main() {
  final folder = Folder(root: '/repo', name: 'meu-repo');

  group('o programa', () {
    test('vai e volta do json inteiro', () {
      final btop = Launcher(
        id: 'lch1',
        name: 'btop',
        command: 'btop -t',
        icon: LauncherIcon.monitor,
      );
      final voltou = Launcher.fromJson(jsonDecode(jsonEncode(btop.toJson())))!;

      expect(voltou.id, 'lch1');
      expect(voltou.name, 'btop');
      expect(voltou.command, 'btop -t');
      expect(voltou.icon, LauncherIcon.monitor);
      // A cor sai do id, então ela é a mesma depois da volta -- e depois de
      // fechar a janela.
      expect(voltou.color, btop.color);
    });

    // Um programa estragado não pode custar as pastas e o layout: quem lê
    // isto é o carregador do config inteiro.
    test('o registro que não abriria nada não volta', () {
      expect(Launcher.fromJson({'id': 'lch1', 'name': 'btop'}), isNull);
      expect(Launcher.fromJson({'id': 'lch1', 'command': 'btop'}), isNull);
      expect(Launcher.fromJson({'name': 'btop', 'command': 'btop'}), isNull);
      expect(Launcher.fromJson('btop'), isNull);
    });

    // O ícone é salvo pelo nome justamente pra isto: um desenho que saísse da
    // lista devolve o terminal, não um quadrado vazio.
    test('o desenho que não existe mais vira o terminal', () {
      final voltou = Launcher.fromJson({
        'id': 'lch1',
        'name': 'btop',
        'command': 'btop',
        'icon': 'holograma',
      })!;
      expect(voltou.icon, LauncherIcon.terminal);
    });
  });

  group('o painel de um programa', () {
    test('se chama pelo programa, e diz o comando embaixo', () {
      final dev = Launcher(id: 'lch1', name: 'dev', command: 'npm run dev');
      final tab = paneOf(dev, folder);

      // Sem isto ele se chamaria "meu-repo", como todos os outros painéis
      // daquela pasta -- e diria "shell" embaixo.
      expect(tab.title, 'dev');
      expect(tab.subtitle, 'npm run dev');
    });

    test('o apelido que você digitou continua ganhando do programa', () {
      final dev = Launcher(id: 'lch1', name: 'dev', command: 'npm run dev');
      final tab = paneOf(dev, folder)..customLabel = 'o servidor do lms';

      expect(tab.title, 'o servidor do lms');
    });

    // Só o id: o nome e o comando são do programa. Uma cópia deles na receita
    // voltaria amanhã com o comando de ontem.
    test('a receita guarda o id do programa, e mais nada dele', () {
      final btop = Launcher(id: 'lch1', name: 'btop', command: 'btop -t');
      final recipe = paneOf(btop, folder).recipe;

      expect(recipe['kind'], 'shell');
      expect(recipe['launcher'], 'lch1');
      expect(recipe.toString(), isNot(contains('btop -t')));
    });
  });

  group('a lista de programas', () {
    test('um programa novo entra no config', () async {
      final store = AppStore();
      addTearDown(store.dispose);
      final file = File(store.configPath);
      if (file.existsSync()) file.deleteSync();

      store.addLauncher(name: 'btop', command: 'btop -t', icon: LauncherIcon.monitor);

      final saved = await savedConfig(store);
      final launchers = (saved['launchers'] as List).cast<Map<String, dynamic>>();
      expect(launchers.single['command'], 'btop -t');
      expect(launchers.single['icon'], 'monitor');
      // E volta inteiro pela mesma porta que o carregador usa.
      expect(Launcher.fromJson(launchers.single)!.name, 'btop');
    });

    test('editar vale nos painéis que já estão abertos', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final dev = store.addLauncher(name: 'dev', command: 'npm run dev');
      final tab = paneOf(dev, folder);
      store.tabs.add(tab);

      store.editLauncher(dev, name: 'servidor', command: 'npm start');

      // O painel segura o programa por referência, como segura a pasta: o
      // cabeçalho dele muda junto, sem ninguém sair avisando painel por painel.
      expect(tab.title, 'servidor');
      expect(tab.subtitle, 'npm start');
    });

    // Apagar o programa é esquecer o atalho, não matar o que está rodando.
    test('apagar o programa deixa o painel aberto, como terminal', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final btop = store.addLauncher(name: 'btop', command: 'btop');
      final tab = paneOf(btop, folder);
      store.tabs.add(tab);

      store.removeLauncher(btop);

      expect(store.tabs, contains(tab));
      expect(tab.launcher, isNull);
      expect(tab.title, 'meu-repo');
      expect(tab.subtitle, 'shell');
      // E o painel salvo não volta apontando pro que não existe mais.
      expect(tab.recipe.containsKey('launcher'), isFalse);
      expect(store.launcherById('lch-que-nao-existe'), isNull);
    });
  });

  // Um pty vivo aqui daria dois filhos escrevendo no mesmo buffer, e o
  // `exitCode` do primeiro marcaria como morto um painel recém-nascido.
  test('rodar de novo não faz nada enquanto o processo está de pé', () {
    final store = AppStore();
    addTearDown(store.dispose);
    final btop = store.addLauncher(name: 'btop', command: 'btop');
    final tab = paneOf(btop, folder);
    store.tabs.add(tab);

    store.relaunch(tab);

    expect(tab.exited, isFalse);
    expect(tab.term.pid, isNull);
  });

  group('a lateral', () {
    /// Larga o bastante pro + e os ícones caberem na linha -- ver groups_test.
    Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 660, height: 700, child: Sidebar(store: store))),
      ),
    );

    /// Montado à mão, sem [AppStore.addLauncher]: o gesto de verdade agenda o
    /// save do config, e um timer de pé é o que o `testWidgets` reclama no fim
    /// do teste. O que está em teste aqui é o desenho, não a gravação.
    AppStore storeWith(Launcher launcher) {
      final store = AppStore();
      store.folders.add(folder);
      store.launchers.add(launcher);
      store.tabs.add(paneOf(launcher, folder));
      return store;
    }

    testWidgets('a linha do painel é o programa: o desenho dele e o nome dele', (tester) async {
      final store = storeWith(
        Launcher(id: 'lch1', name: 'btop', command: 'btop -t', icon: LauncherIcon.monitor),
      );
      addTearDown(store.dispose);

      await pumpSidebar(tester, store);

      expect(find.text('btop'), findsOneWidget);
      expect(find.text('btop -t'), findsOneWidget);
      // E não o chevron do prompt: ali não há prompt esperando comando.
      expect(find.byIcon(LauncherIcon.monitor.glyph), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    // A porta principal da feature: os programas do usuário atrás de uma linha
    // só do +, que abre ao lado quando o ponteiro para nela.
    testWidgets('o + guarda os programas num submenu, aberto no hover', (tester) async {
      final store = storeWith(Launcher(id: 'lch1', name: 'btop', command: 'btop -t'));
      addTearDown(store.dispose);
      await pumpSidebar(tester, store);

      // O + só aparece com o ponteiro na linha da pasta.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('meu-repo')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('abrir algo nessa pasta'));
      await tester.pumpAndSettle();

      // Claude e terminal primeiro, retomar depois deles, e o menu não cresce
      // uma linha por programa: o único 'btop' na tela é a linha do painel.
      expect(find.text('sessão do claude'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget);
      expect(find.text('retomar conversa…'), findsOneWidget);
      expect(find.text('meus programas'), findsOneWidget);
      expect(find.text('btop'), findsOneWidget);
      expect(find.text('outro programa…'), findsNothing);

      await mouse.moveTo(tester.getCenter(find.text('meus programas')));
      await tester.pumpAndSettle();

      // Agora dois: a linha do painel e a do submenu.
      expect(find.text('btop'), findsNWidgets(2));
      expect(find.text('outro programa…'), findsOneWidget);

      // E apontar outra linha do menu o fecha: um submenu que fica aberto
      // enquanto você lê o resto do menu é um submenu no caminho.
      await mouse.moveTo(tester.getCenter(find.text('terminal')));
      await tester.pumpAndSettle();
      expect(find.text('btop'), findsOneWidget);
      expect(find.text('outro programa…'), findsNothing);
    });

    // Sem programa nenhum não há seta pra lugar nenhum: a oferta de ensinar o
    // primeiro fica no menu mesmo.
    testWidgets('sem programas, o + oferece criar o primeiro sem submenu', (tester) async {
      final store = AppStore();
      store.folders.add(folder);
      addTearDown(store.dispose);
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('abrir algo nessa pasta'));
      await tester.pumpAndSettle();

      expect(find.text('criar um programa…'), findsOneWidget);
      expect(find.text('meus programas'), findsNothing);
    });
  });
}
