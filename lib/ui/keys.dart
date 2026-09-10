import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import 'dialogs.dart';
import 'settings.dart';
import 'sidebar.dart';

/// O que cada ação faz, em um lugar só.
///
/// Dois lugares escutam teclado nesta janela e precisam concordar: o mapa lá
/// em cima da árvore (`main.dart`) e o próprio terminal, que resolve algumas
/// teclas antes de qualquer atalho ser consultado — a keytab do xterm resolve
/// ⌃⇥ como Tab e engoliria o atalho inteiro. Enquanto a lista de bindings era
/// fixa, manter as duas em dia era copiar e colar; com o mapa editável, seria
/// copiar e colar toda vez que alguém trocasse uma tecla.
class MxKeys {
  const MxKeys._();

  /// O mapa como o [CallbackShortcuts] quer, montado do que o usuário deixou.
  static Map<ShortcutActivator, VoidCallback> bindings(AppStore store, BuildContext context) => {
    for (final action in MxAction.values)
      for (final chord in store.keymap[action])
        chord.activator: () => run(action, store, context),
    // Os únicos que não passam pelas configurações: são nove teclas que dizem
    // "a enésima sessão", e escolher uma a uma seria configurar uma régua.
    for (var i = 0; i < digits.length; i++)
      SingleActivator(digits[i], meta: true): () => store.selectIndex(i),
  };

  static void run(MxAction action, AppStore store, BuildContext context) {
    // A pasta a que um painel novo pertence: a que você está olhando, ou a
    // bandeja solta — por isso nenhum destes atalhos exige uma pasta existir.
    final Folder folder = store.focusedFolder;
    switch (action) {
      // Ambos herdam o projeto do painel em foco: abrir uma terceira sessão
      // dentro de "permissão do google" é uma terceira sessão naquele job, não
      // uma sessão avulsa do lado dele.
      case MxAction.newClaude:
        store.openClaude(folder, cwd: folder.root, project: store.focusedProject);
      case MxAction.newShell:
        store.openShell(folder, project: store.focusedProject);
      case MxAction.newTask:
        // Uma worktree precisa de um repo pra ser worktree de.
        if (folder.isLoose) {
          store.showBanner(
            'nova task precisa de uma pasta — o painel em foco não está em nenhuma',
          );
          return;
        }
        showNewTask(context, store, folder, project: store.focusedProject);
      case MxAction.renamePane:
        // O painel em foco é o objeto da frase: sem nenhum não há o que
        // renomear, e o banner diz isso em vez de abrir um diálogo vazio.
        final focused = store.focusedTab;
        if (focused == null) {
          store.showBanner('nenhum painel em foco pra renomear');
          return;
        }
        showRenamePanel(context, store, focused);
      case MxAction.closePane:
        store.closeFocused();
      case MxAction.closeSettled:
        store.closeSettled(folder);
      case MxAction.nextPane:
        store.cyclePane(1);
      case MxAction.prevPane:
        store.cyclePane(-1);
      case MxAction.nextSession:
        store.cycle(1);
      case MxAction.prevSession:
        store.cycle(-1);
      case MxAction.search:
        // A lateral é uma, e o campo dela sabe se dizer onde está: ver
        // [SidebarSearch]. Nada aqui precisa saber se ele está montado.
        SidebarSearch.reveal();
      case MxAction.openMarkdown:
        store.openMarkdown();
      // --- ditado (vocalização) — fora desta versão --------------------------
      // Ver o cabeçalho de `services/dictation.dart`.
      // case MxAction.dictate:
        // // Sem `await`: o gesto é o toque, e quem espera a transcrição é o
        // // cabeçalho do painel, que já está desenhando "ouvindo…".
        // store.toggleDictation();
      case MxAction.readPlan:
        // Sem sessão em foco não há plano de quem: o leitor não é um lugar
        // onde se escolhe um plano, é onde um plano é lido.
        final tab = store.focusedTab;
        if (tab == null || tab.kind != TabKind.claude) {
          store.showBanner('o painel em foco não é uma sessão do claude');
          return;
        }
        store.showPlan(tab);
      case MxAction.zoomIn:
        store.zoomFocused(1);
      case MxAction.zoomOut:
        store.zoomFocused(-1);
      case MxAction.zoomReset:
        store.resetZoomFocused();
      case MxAction.dailyReport:
        showDailyReport(context, store);
      case MxAction.refreshGit:
        store.refreshGit();
      case MxAction.settings:
        showSettings(context, store);
    }
  }

  static const List<LogicalKeyboardKey> digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
}
