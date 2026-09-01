import 'dart:io';

import 'shell.dart';

/// Handing a folder to the editor — the other half of a worktree's life.
///
/// A worktree is a folder before it is anything else, so opening one is the
/// plain thing to want from it. `code` is a shim in the user's profile, which
/// is why this goes through [Sh] and its login shell.
///
/// The fallback is where the two systems part. On macOS `open -a` still gets
/// there when the shim is missing, because the .app is what the shim wraps.
/// Linux has no .app to reach behind the shim for, so it tries the other name
/// the same editor ships under and then gives the folder to the desktop —
/// which is not an editor, but is at least the folder.
class Editor {
  static const app = 'Visual Studio Code';

  static Future<bool> open(String path) async {
    final r = await Sh.run('code ${Sh.q(path)}');
    if (r.ok) return true;
    if (Platform.isLinux) {
      final insiders = await Sh.run('code-insiders ${Sh.q(path)}');
      if (insiders.ok) return true;
      final desktop = await Sh.run('xdg-open ${Sh.q(path)}');
      return desktop.ok;
    }
    final fallback = await Sh.run('open -a ${Sh.q(app)} ${Sh.q(path)}');
    return fallback.ok;
  }
}
