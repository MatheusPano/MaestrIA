import 'dart:io';

/// Everything shells out through a login shell.
///
/// A GUI app inherits a bare PATH: `claude`, `git` and the fvm shims live in
/// the user's profile, so `Process.run('claude')` fails in a released build
/// even though it works from a terminal. `-lc` is the fix, and `exec` keeps
/// the pid ours (see [PtyLauncher]).
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

  static Future<ShResult> run(String command, {String? cwd}) async {
    try {
      final r = await Process.run(shell, ['-lc', command], workingDirectory: cwd);
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
