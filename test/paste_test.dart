import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/pty.dart';

/// Stands in for the system clipboard. `null` is a clipboard that holds
/// something that is not text -- a screenshot, most of the time.
void clipboardHolds(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method != 'Clipboard.getData') return null;
    return text == null ? null : <String, dynamic>{'text': text};
  });
}

/// Everything the session would have written to its pty.
List<String> watch(TermSession session) {
  final written = <String>[];
  session.terminal.onOutput = written.add;
  return written;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('⌘V', () {
    test('text on the clipboard is pasted', () async {
      final session = TermSession();
      final written = watch(session);

      clipboardHolds('git status');
      await session.pasteClipboard(imagesViaCtrlV: true);

      expect(written, ['git status']);
    });

    test('an image is handed to claude as ^V, which reads it itself', () async {
      final session = TermSession();
      final written = watch(session);

      clipboardHolds(null);
      await session.pasteClipboard(imagesViaCtrlV: true);

      expect(written, ['\x16']);
    });

    test('but a shell gets nothing -- ^V there only eats the next key', () async {
      final session = TermSession();
      final written = watch(session);

      clipboardHolds(null);
      await session.pasteClipboard();

      expect(written, isEmpty);
    });
  });
}
