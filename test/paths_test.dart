import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/paths.dart';
import 'package:maestria/services/store.dart';

void main() {
  final home = Platform.environment['HOME'] ?? '';

  group('expandHome', () {
    test('~/ vira o HOME de quem roda o app', () {
      expect(expandHome('~/repos/foo'), '$home/repos/foo');
      expect(expandHome('~/'), '$home/');
    });

    test('~ sozinho é o home puro', () {
      expect(expandHome('~'), home);
    });

    // `~outro` é o home de outro usuário, que está no /etc/passwd e não no
    // HOME: colar o nosso home na frente dele daria uma pasta de ninguém.
    test('~outro não é home nenhum e fica literal', () {
      expect(expandHome('~outro/repos'), '~outro/repos');
      expect(expandHome('~outro'), '~outro');
    });

    test('caminho absoluto, relativo e vazio passam intactos', () {
      expect(expandHome('/Volumes/Externo/repos/foo'), '/Volumes/Externo/repos/foo');
      expect(expandHome('repos/foo'), 'repos/foo');
      expect(expandHome('./foo'), './foo');
      expect(expandHome(''), '');
      // Um `~` no meio é nome de arquivo (o backup do vim), não alias.
      expect(expandHome('/tmp/notas.md~'), '/tmp/notas.md~');
    });
  });

  // Antes disto, o `~/` digitado no campo "caminho do repo" chegava literal no
  // `Directory(...).existsSync()`, e adicionar uma pasta que existe respondia
  // "pasta não encontrada".
  test('adicionar pasta aceita o ~/ digitado', () async {
    final dir = Directory(home).createTempSync('.maestria-teste-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = AppStore();
    addTearDown(store.dispose);

    final folder = await store.addFolder('~/${dir.path.split('/').last}');

    expect(folder, isNotNull);
    // O root pode ser a pasta ou -- se o HOME de quem rodou for um repo -- a
    // raiz que o git achou acima dela. O que não pode é sobrar `~`.
    expect(folder!.root, isNot(contains('~')));
    expect(folder.root, startsWith(home));
    expect(Directory(folder.root).existsSync(), isTrue);
  });
}
