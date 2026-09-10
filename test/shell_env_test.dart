import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/shell.dart';
import 'package:maestria/services/store.dart';

void main() {
  // O PATH pelado que o launchd dá a uma `.app` aberta pelo Finder, depois do
  // `path_helper`: é nele que faltava a pasta do `claude`.
  const bare = '/usr/bin:/bin:/usr/sbin:/sbin';

  group('Sh.pathWithFallbacks', () {
    test('a pasta que existe e não estava no PATH entra no fim', () {
      final path = Sh.pathWithFallbacks(
        bare,
        candidates: const ['/opt/claude/bin'],
        exists: (_) => true,
      );

      // No fim, e não na frente: o que o perfil escolheu continua ganhando.
      expect(path, '$bare:/opt/claude/bin');
    });

    test('a que não existe fica fora', () {
      final path = Sh.pathWithFallbacks(
        bare,
        candidates: const ['/opt/claude/bin', '/opt/nao-instalado/bin'],
        exists: (dir) => dir == '/opt/claude/bin',
      );

      expect(path, '$bare:/opt/claude/bin');
    });

    // Um PATH com a mesma pasta duas vezes não quebra nada, mas é o tipo de
    // coisa que aparece num `echo $PATH` e faz quem lê procurar bug onde não há.
    test('a que já estava não entra de novo', () {
      final path = Sh.pathWithFallbacks(
        '$bare:/opt/claude/bin',
        candidates: const ['/opt/claude/bin', '/opt/claude/bin'],
        exists: (_) => true,
      );

      expect(path, '$bare:/opt/claude/bin');
    });

    test('PATH vazio -- o pior caso -- ainda dá um PATH utilizável', () {
      final path = Sh.pathWithFallbacks(
        '',
        candidates: const ['/opt/claude/bin'],
        exists: (_) => true,
      );

      expect(path, '/opt/claude/bin');
    });
  });

  // O elo entre a função e quem a usa: sem isto o remendo existiria e ninguém
  // o receberia.
  test('Sh.env leva as pastas de binário que existem nesta máquina', () {
    final path = (Sh.env['PATH'] ?? '').split(':');
    final existentes = Sh.binDirs.where((d) => Directory(d).existsSync());

    expect(existentes, isNotEmpty, reason: 'nenhuma pasta candidata nesta máquina');
    for (final dir in existentes) {
      expect(path, contains(dir));
    }
  });

  group('AppStore.earlyExitMessage', () {
    // O caso do bug: `zsh:1: command not found: claude`, exit 127, e um aviso
    // que só dizia o número.
    test('127 é o claude fora do PATH, e diz onde pôr a pasta', () {
      final message = AppStore.earlyExitMessage('maestria_v2', 127);

      expect(message, startsWith('maestria_v2: '));
      expect(message, contains('PATH'));
      expect(message, contains(Sh.profileFile));
    });

    test('qualquer outra saída continua mandando ler o painel', () {
      expect(AppStore.earlyExitMessage('maestria_v2', 1), contains('código 1'));
      expect(AppStore.earlyExitMessage('maestria_v2', 1), contains('abra o painel'));
      expect(AppStore.earlyExitMessage('maestria_v2', null), contains('código ?'));
    });
  });
}
