import 'dart:io';

import 'package:flutter/services.dart';

import 'shell.dart';

/// Getting a state out of the window and onto the machine.
///
/// Two channels, because they answer different questions: the notification
/// tells you *which* session stopped, the dock badge tells you *how many* are
/// stopped -- readable from another app without switching to this one.
///
/// The badge is the one thing Linux has no honest answer for: a dock tile is
/// an AppKit idea, and the launcher APIs that come close are per-desktop and
/// need a `.desktop` file we do not install. So on Linux the count is simply
/// not said outside the window, and the notification carries the whole load.
class Notifier {
  static const _dock = MethodChannel('maestria/dock');

  String? _lastBadge;

  /// The native folder picker, as a sheet on our window.
  static Future<String?> chooseFolder() async {
    try {
      return await _dock.invokeMethod<String>('chooseFolder');
    } on MissingPluginException {
      return null;
    }
  }

  /// O painel nativo pra escolher um `.code-workspace`, como sheet da nossa
  /// janela.
  ///
  /// Separado de [chooseFolder] em vez de um picker só que aceita os dois: o
  /// "abrir sem pasta" também usa aquele, e ali um arquivo não é resposta pra
  /// pergunta "onde o painel vai rodar".
  ///
  /// Devolve as duas respostas separadas porque elas são mesmo duas. Desistir
  /// de escolher é uma resposta e merece silêncio; não haver painel nenhum do
  /// outro lado não é -- e engolir as duas iguais dá um botão que não faz
  /// nada, que é o sintoma mais difícil de ler que existe. Foi assim que este
  /// método apareceu: um hot reload põe o Dart novo por cima do binário
  /// nativo de antes, o método ainda não existe lá e o clique não produz nem
  /// um erro.
  static Future<({String? path, bool available})> chooseWorkspace() async {
    try {
      return (path: await _dock.invokeMethod<String>('chooseWorkspace'), available: true);
    } on MissingPluginException {
      return (path: null, available: false);
    }
  }

  /// O painel nativo pra escolher um markdown, como sheet da nossa janela.
  ///
  /// [startIn] é onde ele abre — a pasta do painel em foco, que é quase sempre
  /// onde o arquivo está. Null quando a pessoa cancela, e também num build sem
  /// a metade nativa.
  static Future<String?> chooseMarkdown({String? startIn}) async {
    try {
      return await _dock.invokeMethod<String>('chooseMarkdown', startIn);
    } on MissingPluginException {
      return null;
    }
  }

  /// Show a file the way the Finder's space bar would.
  ///
  /// The result strip is read by someone who wants to see the spreadsheet, not
  /// to edit it — [Editor.open] is the developer's verb and hands a `.docx` to
  /// VS Code. Falls back to revealing the file in the file manager, which is
  /// the same intent with one more click.
  ///
  /// Linux has no Quick Look: nothing renders a preview without also being the
  /// app that owns the type. `xdg-open` is the nearest thing that keeps the
  /// promise — the file opens in whatever already reads it.
  static Future<bool> quickLook(String path) async {
    if (Platform.isLinux) {
      if (!File(path).existsSync()) return false;
      final opened = await Sh.run('xdg-open ${Sh.q(path)}');
      if (opened.ok) return true;
      return reveal(path);
    }
    try {
      final shown = await _dock.invokeMethod<bool>('quickLook', path);
      if (shown == true) return true;
    } on MissingPluginException {
      // Running against a build without the native half.
    }
    return reveal(path);
  }

  /// Select the file in the file manager, rather than open whatever owns its
  /// type.
  ///
  /// The freedesktop `ShowItems` call is the one that actually *selects* the
  /// file, which is what `open -R` does; when no file manager implements it we
  /// settle for opening the containing folder.
  static Future<bool> reveal(String path) async {
    if (Platform.isLinux) {
      final shown = await Sh.run(
        'dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 '
        '/org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems '
        'array:string:${Sh.q('file://${Uri.encodeFull(path)}')} string:""',
      );
      if (shown.ok) return true;
      final parent = File(path).parent.path;
      final opened = await Sh.run('xdg-open ${Sh.q(parent)}');
      return opened.ok;
    }
    final r = await Sh.run('open -R ${Sh.q(path)}');
    return r.ok;
  }

  /// Um link de fora, entregue a quem cuida de links: o navegador padrão.
  ///
  /// Existe porque o leitor de markdown desenha links e um link que não abre é
  /// um link que não devia estar sublinhado.
  static Future<bool> openLink(String url) async {
    final r = await Sh.run('${Platform.isLinux ? 'xdg-open' : 'open'} ${Sh.q(url)}');
    return r.ok;
  }

  /// A desktop notification: `osascript` on macOS, `notify-send` on Linux.
  /// Neither needs signing or an entitlement.
  Future<void> alert(String title, String body) async {
    if (Platform.isLinux) {
      await Sh.run('notify-send -a maestria ${Sh.q(title)} ${Sh.q(body)}');
      return;
    }
    await Sh.run(
      'osascript -e ${Sh.q('display notification ${_esc(body)} with title ${_esc(title)}')}',
    );
  }

  Future<void> badge(String? label) async {
    if (label == _lastBadge) return;
    _lastBadge = label;
    if (Platform.isLinux) return; // No dock tile to stamp.
    try {
      await _dock.invokeMethod<void>('badge', label ?? '');
    } on MissingPluginException {
      // Running before the native side exists: not worth a crash.
    }
  }

  /// AppleScript string literal: quotes and backslashes only.
  static String _esc(String value) => '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
