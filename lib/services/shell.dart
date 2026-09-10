import 'dart:io';

import 'package:flutter/foundation.dart';

/// Everything shells out through a login shell.
///
/// A GUI app inherits a bare PATH: `claude`, `git` and the fvm shims live in
/// the user's profile, so `Process.run('claude')` fails in a released build
/// even though it works from a terminal. `-lc` is the fix, and `exec` keeps
/// the pid ours (see [PtyLauncher]) -- com [env] por baixo pra cobrir o que o
/// `-l` sozinho não alcança.
class Sh {
  /// The login shell to run everything through.
  ///
  /// macOS pins zsh because that is the shell a Mac's profile is written for
  /// and `$SHELL` is not set for an app launched from the Finder. On Linux
  /// there is no such default — bash, zsh and fish are all ordinary choices —
  /// so the user's own `$SHELL` is the honest answer, with a descent through
  /// the usual suspects for the case where a desktop session does not export
  /// it. `sh` is last because every command here is written for a login
  /// shell, and dash's `-l` is the least of them.
  static final String shell = _resolveShell();

  static String _resolveShell() {
    if (Platform.isMacOS) return '/bin/zsh';
    final fromEnv = Platform.environment['SHELL'];
    if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
      return fromEnv;
    }
    for (final candidate in const ['/bin/bash', '/usr/bin/bash', '/bin/zsh', '/usr/bin/zsh']) {
      if (File(candidate).existsSync()) return candidate;
    }
    return '/bin/sh';
  }

  /// Single-quote a value for safe interpolation into a shell command.
  static String q(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// O ambiente de todo filho: o nosso, com as pastas de binário que um app de
  /// GUI não herda somadas ao PATH.
  ///
  /// O `-l` de [shell] existe justamente pra pegar o PATH do perfil, mas ele
  /// não pega tudo: um zsh de login *não interativo* lê `.zshenv`,
  /// `/etc/zprofile` e `.zprofile` -- e não lê o `.zshrc`, que é onde quase
  /// todo manual de instalação manda pôr a linha do PATH (o do próprio claude
  /// entre eles: `. "$HOME/.local/bin/env"`). Por `flutter run` isso nunca
  /// aparece, porque aí o app herda o PATH do terminal que o abriu; aberto pelo
  /// Finder, o PATH é o pelado do launchd, o `claude` não está em pasta nenhuma
  /// dele, e a sessão morre com 127 antes de ler o primeiro argumento.
  ///
  /// A rede é só isto: as pastas entram *no fim* e só se existirem, então o que
  /// o perfil escolheu continua na frente. Não é uma opinião sobre qual
  /// `claude` é o certo -- é o caso em que não havia nenhum.
  static final Map<String, String> env = {
    ...Platform.environment,
    'PATH': pathWithFallbacks(Platform.environment['PATH'] ?? ''),
  };

  /// [inherited] com os [candidates] que faltam nele, na ordem, no fim.
  ///
  /// Os parâmetros são pra teste: sem eles o resultado dependeria do PATH e das
  /// pastas da máquina que roda a suíte.
  @visibleForTesting
  static String pathWithFallbacks(
    String inherited, {
    Iterable<String>? candidates,
    bool Function(String dir) exists = _isDir,
  }) {
    final dirs = inherited.split(':').where((d) => d.isNotEmpty).toList();
    for (final dir in candidates ?? binDirs) {
      if (dirs.contains(dir) || !exists(dir)) continue;
      dirs.add(dir);
    }
    return dirs.join(':');
  }

  /// Onde os binários que o app chama moram, quando não estão no PATH.
  ///
  /// Nenhuma das pastas do `/etc/paths` está aqui: o `path_helper` já as põe no
  /// PATH mesmo do processo mais pelado -- é por isso que o `git` de um mac com
  /// homebrew funciona no release e o `claude` do `~/.local/bin` não.
  @visibleForTesting
  static Iterable<String> get binDirs {
    final home = Platform.environment['HOME'] ?? '';
    return [
      if (home.isNotEmpty) ...[
        '$home/.local/bin', // o instalador nativo do claude
        '$home/.claude/local', // e o `claude migrate-installer` de antes dele
        '$home/.bun/bin', // claude por bun
        '$home/.volta/bin', // node por volta
        '$home/.npm-global/bin', // o prefix de quem não quer `sudo npm -g`
        '$home/.pub-cache/bin', // fvm e o resto do que o dart ativa global
        '$home/.cargo/bin',
      ],
      // Homebrew nos dois lugares: o `/etc/paths.d/homebrew` é dele, mas quem
      // instalou o brew antes dessa era não tem o arquivo.
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
      '/usr/local/sbin',
      if (Platform.isLinux) '/home/linuxbrew/.linuxbrew/bin',
    ];
  }

  static bool _isDir(String dir) => Directory(dir).existsSync();

  /// O arquivo que o shell de login lê -- onde uma linha de PATH tem de estar
  /// pra valer também dentro do app, e não só no terminal.
  static String get profileFile => Platform.isMacOS ? '~/.zprofile' : '~/.profile';

  static Future<ShResult> run(String command, {String? cwd}) async {
    try {
      final r = await Process.run(
        shell,
        ['-lc', command],
        workingDirectory: cwd,
        environment: env,
      );
      return ShResult(r.exitCode, (r.stdout as String).trim(), (r.stderr as String).trim());
    } on ProcessException catch (e) {
      return ShResult(-1, '', e.message);
    }
  }
}

class ShResult {
  ShResult(this.code, this.stdout, this.stderr);
  final int code;
  final String stdout;
  final String stderr;
  bool get ok => code == 0;
}
