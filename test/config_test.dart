import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';

/// O config que o store acabou de gravar. O save é debounced, então o arquivo
/// sai do caminho primeiro e a leitura espera ele reaparecer.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// O `layout.panes` que ele gravou.
Future<List<Map<String, dynamic>>> savedPanes(AppStore store) async {
  final saved = await savedConfig(store);
  return ((saved['layout'] as Map)['panes'] as List).cast<Map<String, dynamic>>();
}

void main() {
  // Quase todo teste daqui monta um AppStore de verdade, e um gesto simulado
  // que mexa nas pastas ou nos painéis dispara um save de verdade. Enquanto o
  // estado morava no HOME, rodar a suíte reescrevia o config da máquina de
  // quem rodou -- as pastas abertas viravam o `/repo` de mentira dos testes.
  test('o config, sob teste, não é o config da máquina', () {
    final store = AppStore();
    addTearDown(store.dispose);

    expect(AppStore.stateHome, startsWith(Directory.systemTemp.path));
    expect(store.configPath, startsWith(Directory.systemTemp.path));
    expect(store.configPath, isNot(contains('${Platform.environment['HOME']}/.maestria')));
  });

  // Mandar a sessão pro background é o claude soltando o terminal e seguindo
  // rodando fora dele: o processo do painel sai, e o layout salvo só levava
  // painel com processo vivo -- então reabrir o app não tinha de onde retomar
  // a conversa, e a sessão que estava lá simplesmente não voltava.
  test('o painel do claude que perdeu o processo ainda volta com a conversa', () async {
    final store = AppStore();
    addTearDown(store.dispose);
    final folder = Folder(root: '/repo', name: 'meu-repo');
    store.folders.add(folder);

    final conversa = MxTab(
      id: 'tab1',
      folder: folder,
      kind: TabKind.claude,
      cwd: '/repo',
      branch: '',
    );
    conversa.sessionId = 'sess-do-fundo';
    // Um terminal morto continua de fora: não tem conversa pra retomar.
    final shell = MxTab(
      id: 'tab2',
      folder: folder,
      kind: TabKind.shell,
      cwd: '/repo',
      branch: '',
    );
    store.tabs.addAll([conversa, shell]);
    for (final t in store.tabs) {
      t.term.exited = true;
    }

    final file = File(store.configPath);
    if (file.existsSync()) file.deleteSync();
    store.renameTab(conversa, 'a conversa do fundo');

    final panes = await savedPanes(store);
    expect(panes.map((p) => p['sessionId']), ['sess-do-fundo']);
  });

  // Um `writeAsString` direto cria o arquivo, trunca e só depois escreve --
  // quem lesse nessa fresta achava zero byte. E quem lê o config é o
  // carregador, que engole a exceção do `jsonDecode`: a janela abria sem
  // pasta, sem projeto e sem layout por causa de uma leitura que caiu no
  // milissegundo errado. O `rename` dentro da mesma pasta é atômico.
  test('o config é escrito ao lado e movido pra cima, sem deixar rascunho', () async {
    final store = AppStore();
    addTearDown(store.dispose);
    store.folders.add(Folder(root: '/repo', name: 'meu-repo'));

    final file = File(store.configPath);
    if (file.existsSync()) file.deleteSync();
    store.toggleGroupsCollapsed();

    // Inteiro, e não um pedaço: é o que o rename garante a quem chegar depois.
    final saved = await savedConfig(store);
    expect((saved['folders'] as List).single['root'], '/repo');
    expect(saved['groupsCollapsed'], isTrue);

    // E o temporário não fica pra trás na pasta do estado. O pid no nome dele
    // é pela segunda janela: duas maestrias guardam no mesmo config, e com um
    // nome fixo elas escreveriam uma dentro do rascunho da outra.
    final left = file.parent
        .listSync()
        .map((e) => e.path.split('/').last)
        .where((name) => name.startsWith('config.json') && name != 'config.json');
    expect(left, isEmpty);
  });

  // O config que o 2.4.0 gravou chama de `projects` o que agora é
  // `featuresOrHotfixes`. Lido sem isto, a janela abriria com as pastas e sem
  // nenhuma das features.
  test('as features gravadas como `projects` voltam', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'folders': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
      'projects': [
        {'id': 'pj1', 'folderRoot': '/repo', 'name': 'permissão do google', 'brief': 'b'},
      ],
    });

    expect(store.featuresOrHotfixes.single.id, 'pj1');
    expect(store.featuresOrHotfixes.single.name, 'permissão do google');
  });

  test('e a chave nova vence a antiga quando as duas estão lá', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'folders': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
      'projects': [
        {'id': 'velho', 'folderRoot': '/repo', 'name': 'velho'},
      ],
      'featuresOrHotfixes': [
        {'id': 'novo', 'folderRoot': '/repo', 'name': 'novo'},
      ],
    });

    expect(store.featuresOrHotfixes.map((f) => f.id), ['novo']);
  });

  // Antes dos projetos existirem, `projects` era a lista de pastas.
  test('o config de antes dos projetos continua abrindo as pastas', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'projects': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
    });

    expect(store.folders.single.root, '/repo');
    expect(store.featuresOrHotfixes, isEmpty);
  });

  // Um grupo de painéis salvo antes do rename guarda a receita com
  // `projectId`; o painel tem que voltar pra mesma feature.
  test('a receita de painel lê o id da feature pelo nome novo e pelo antigo', () {
    expect(featureOrHotfixIdIn({'featureOrHotfixId': 'a'}), 'a');
    expect(featureOrHotfixIdIn({'projectId': 'b'}), 'b');
    expect(featureOrHotfixIdIn({'featureOrHotfixId': 'a', 'projectId': 'b'}), 'a');
    expect(featureOrHotfixIdIn({}), isNull);
  });

  test('o config grava as features com a chave nova', () async {
    final store = AppStore();
    addTearDown(store.dispose);
    final folder = Folder(root: '/repo', name: 'meu-repo');
    store.folders.add(folder);
    final file = File(store.configPath);
    if (file.existsSync()) file.deleteSync();

    store.addFeatureOrHotfix(folder, 'permissão do google');
    final saved = await savedConfig(store);

    expect(saved.containsKey('projects'), isFalse);
    expect((saved['featuresOrHotfixes'] as List).single['name'], 'permissão do google');
  });
}
