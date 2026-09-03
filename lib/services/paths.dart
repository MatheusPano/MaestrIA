/// O caminho digitado, entendido como quem digitou entendia.
library;

import 'dart:io';

/// O `~` de um caminho digitado, expandido pro HOME de quem roda o app.
///
/// Quem digita uma pasta digita como digitaria no terminal, e ali o `~` é o
/// shell que expande -- o Dart não expande nada: `Directory('~/repos/foo')` vai
/// procurar uma pasta chamada "~" dentro do diretório atual, não achar, e a
/// resposta que sobra pro usuário é um "pasta não encontrada" sobre uma pasta
/// que existe. Então quem expande é isto, antes de qualquer `existsSync`.
///
/// Só `~` e `~/…`. `~outro/x` é o home de *outro usuário*, que só o shell (com
/// o /etc/passwd na mão) sabe onde fica: expandir pelo HOME daria uma pasta que
/// não é a de ninguém, então fica literal e o "não encontrada" ali é honesto.
String expandHome(String path) {
  if (path != '~' && !path.startsWith('~/')) return path;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return path;
  final rest = path.substring(1);
  if (rest.isEmpty) return home;
  // Um HOME com barra no fim -- raro, mas é só o `/` de um container -- daria
  // `//repos` se as duas barras se somassem.
  return home.endsWith('/') ? '${home.substring(0, home.length - 1)}$rest' : '$home$rest';
}

/// A pasta onde a janela guarda o que ela lembra, entre uma execução e outra.
///
/// Quase todo teste de widget monta um [AppStore] de verdade, e um gesto
/// simulado que dispare um save escreve de verdade também: sem este desvio, um
/// `flutter test` reescreve o config da máquina de quem rodou -- pastas
/// abertas, projetos, layout -- com o `/repo` de mentira dos testes. Sob teste,
/// então, o estado vai pra uma pasta descartável.
///
/// O `pid` no nome não é enfeite: o `flutter test` roda cada arquivo de teste
/// num processo próprio, em paralelo, e uma pasta só pra todos fazia um arquivo
/// ler o config que outro estava escrevendo -- `jsonDecode` num json cortado no
/// meio, falhando em ~1 de 3 execuções da suíte.
String get mxStateHome => Platform.environment.containsKey('FLUTTER_TEST')
    ? '${Directory.systemTemp.path}/maestria-test-$pid'
    : Platform.environment['HOME'] ?? '/';

/// A pasta do app dentro de [mxStateHome]: o config, e a porta dos hooks.
String get mxStateDir => '$mxStateHome/.maestria';
