import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/terminal_pane.dart';

/// Um painel no único lugar da tela, sem pty: o que este arquivo mede é o que
/// o [Terminal] resolveu mandar pro processo, e isso acontece antes de haver
/// processo -- ver [watch].
MxTab panel(AppStore store) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

/// Tudo o que este painel teria escrito no pty, na ordem.
///
/// `onOutput` é exatamente o ponto onde [TermSession] entrega os bytes ao
/// processo (ver `pty.dart`), então uma tecla que chegue aqui duas vezes é uma
/// tecla que o claude leria duas vezes.
List<String> watch(MxTab tab) {
  final written = <String>[];
  tab.term.terminal.onOutput = written.add;
  return written;
}

Future<void> pumpPane(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
  MaterialApp(
    home: AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        body: SizedBox(
          width: 720,
          height: 320,
          child: TerminalPane(store: store, tab: tab),
        ),
      ),
    ),
  ),
);

/// O painel montado, em foco e com o teclado na mão.
Future<List<String>> typing(WidgetTester tester) async {
  final store = AppStore();
  final tab = panel(store);
  final written = watch(tab);
  await pumpPane(tester, store, tab);
  await tester.pump();
  return written;
}

/// Uma atualização do [TextInput], que é por onde o texto composto entra.
///
/// [composing] não-nulo é a marca de que o sistema ainda está compondo: o
/// acento apareceu na tela mas não virou caractere nenhum ainda.
Future<void> ime(WidgetTester tester, String text, {TextRange? composing}) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing ?? TextRange.empty,
    ),
  );
  await tester.pump();
}

void main() {
  // Um caractere acentuado entra no painel por duas portas ao mesmo tempo: o
  // evento de tecla cru, que o [Focus] do pty vê primeiro, e o texto que o
  // sistema compôs, que chega depois pelo [TextInput]. As duas mandam pro
  // mesmo pty, e é o `composing` que decide qual delas cala a boca -- o xterm
  // engole o evento de tecla enquanto há composição em curso.
  //
  // Nada disto é nosso, mas o `onKeyEvent` do painel (ver [TerminalPane]) mora
  // no meio desse caminho: resolver os atalhos num [Focus] acima do
  // [TerminalView], em vez de por ali, tiraria o teclado de trás daquela
  // guarda e faria todo acento chegar dobrado ao claude.
  group('digitar um acento', () {
    testWidgets('manda o caractere composto uma vez, e só ele', (tester) async {
      final written = await typing(tester);

      // O acento morto: aparece na tela, não vira nada ainda.
      await simulateKeyDownEvent(LogicalKeyboardKey.quote);
      await ime(tester, '´', composing: const TextRange(start: 0, end: 1));
      await simulateKeyUpEvent(LogicalKeyboardKey.quote);
      expect(written, isEmpty, reason: 'compor não é digitar');

      // A vogal fecha a composição -- e é ela que o sistema entrega.
      await simulateKeyDownEvent(LogicalKeyboardKey.keyE, character: 'é');
      await ime(tester, 'é');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyE);
      expect(written, ['é']);
    });

    testWidgets('e o `ç` do ABNT2, que é tecla e não composição', (tester) async {
      final written = await typing(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.semicolon, character: 'ç');
      await ime(tester, 'ç');
      await simulateKeyUpEvent(LogicalKeyboardKey.semicolon);

      expect(written, ['ç']);
    });

    // O bug que o Linux tem e o Mac não: com o ibus no meio -- o método de
    // entrada padrão do Ubuntu, e do Zorin -- o mesmo commit chega três vezes
    // seguidas, todas com o caractere já composto, porque o pedido de reset
    // que o xterm faz entre uma e outra é assíncrono e ainda não chegou. Ver
    // [VtTerminal.textInput].
    testWidgets('entregue três vezes pelo ibus, ainda é um caractere só', (tester) async {
      final written = await typing(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.quote);
      await ime(tester, '´', composing: const TextRange(start: 0, end: 1));
      await simulateKeyUpEvent(LogicalKeyboardKey.quote);
      // A tecla que fecha a composição vai e volta antes de o ibus entregar
      // coisa alguma -- e o xterm a esconde do painel enquanto compõe.
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA, character: 'á');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA);

      await ime(tester, 'á');
      await ime(tester, 'á');
      await ime(tester, 'á');

      expect(written, ['á'], reason: 'nada de "ááá"');
    });

    testWidgets('mas duas vezes de propósito continuam sendo duas', (tester) async {
      final written = await typing(tester);

      for (var i = 0; i < 2; i++) {
        await simulateKeyDownEvent(LogicalKeyboardKey.quote);
        await ime(tester, '´', composing: const TextRange(start: 0, end: 1));
        await simulateKeyUpEvent(LogicalKeyboardKey.quote);
        await simulateKeyDownEvent(LogicalKeyboardKey.keyA, character: 'á');
        await ime(tester, 'á');
        await simulateKeyUpEvent(LogicalKeyboardKey.keyA);
      }

      expect(written, ['á', 'á']);
    });

    testWidgets('e a tecla segurada repete, que é o que segurar uma tecla faz', (tester) async {
      final written = await typing(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.semicolon, character: 'ç');
      await ime(tester, 'ç');
      for (var i = 0; i < 3; i++) {
        await simulateKeyRepeatEvent(LogicalKeyboardKey.semicolon, character: 'ç');
        await ime(tester, 'ç');
      }
      await simulateKeyUpEvent(LogicalKeyboardKey.semicolon);

      expect(written, ['ç', 'ç', 'ç', 'ç']);
    });

    testWidgets('uma palavra inteira sai como a palavra', (tester) async {
      final written = await typing(tester);

      await simulateKeyDownEvent(LogicalKeyboardKey.keyN, character: 'n');
      await ime(tester, 'n');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyN);
      // O til vem antes da vogal: é assim que se digita "não".
      await simulateKeyDownEvent(LogicalKeyboardKey.quote);
      await ime(tester, '~', composing: const TextRange(start: 0, end: 1));
      await simulateKeyUpEvent(LogicalKeyboardKey.quote);
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA, character: 'ã');
      await ime(tester, 'ã');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA);
      await simulateKeyDownEvent(LogicalKeyboardKey.keyO, character: 'o');
      await ime(tester, 'o');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyO);

      expect(written.join(), 'não', reason: 'nada de "nããão"');
    });
  });
}
