import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';

/// O `layout.panes` que o store acabou de gravar. O save é debounced, então
/// o arquivo sai do caminho primeiro e a leitura espera ele reaparecer.
Future<List<Map<String, dynamic>>> savedPanes(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
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
}
