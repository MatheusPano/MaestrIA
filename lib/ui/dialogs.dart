import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
// --- ditado (vocalização) — fora desta versão --------------------------------
// Ver o cabeçalho de `services/dictation.dart`.
// import '../services/dictation.dart';
import '../services/git.dart';
import '../services/history.dart';
import '../services/notify.dart';
import '../services/paths.dart';
import '../services/report.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../services/workspace.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'confetti.dart';
import 'flow.dart';
import 'menus.dart';

InputDecoration _field(String label, [String? hint]) => InputDecoration(
  labelText: label,
  hintText: hint,
  isDense: true,
  labelStyle: TextStyle(color: Mx.fgDim, fontSize: 12),
  hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12),
  border: const OutlineInputBorder(),
);

/// O bloco "abrir algo aqui", escrito uma vez.
///
/// Três menus fazem a mesma oferta sobre lugares diferentes -- o + de uma
/// pasta, o botão direito de um projeto, o de uma worktree --, e antes cada um
/// dizia a sua parte dela: os programas do usuário só existiam no +, e a
/// ordem das duas primeiras linhas era diferente em cada um.
///
/// A ordem é a das chances de você ter vindo por ela: a sessão, o terminal, a
/// sessão com o fluxo dela já escrito, retomar uma conversa -- que é abrir uma sessão que já tem passado, um degrau
/// abaixo da nova -- e ler um markdown de lá, que é o único painel daqui que
/// não roda nada. Os programas do usuário desceram pra um submenu: eram uma
/// linha por programa no meio das ofertas do código, e cinco deles empurravam
/// `projeto…` pro pé de um menu que ficava com o dobro do tamanho. Ver
/// [Launcher] e [MxSubmenuItem].
///
/// [resume] cai fora onde retomar não tem o que retomar: uma worktree é uma
/// pasta que o histórico de conversas da pasta-mãe não conhece.
List<PopupMenuEntry<String>> openHereItems(AppStore store, {bool resume = true}) => [
  mxItem('claude', glyph: const ClaudeMark(size: 13), label: 'sessão do claude'),
  mxItem('shell', glyph: Icon(Icons.terminal, size: 14, color: Mx.fgDim), label: 'terminal'),
  // Uma sessão com o depois dela já escrito. Fica atrás das duas de cima
  // porque é o que menos se pede aqui -- e à frente do resto porque é a
  // mesma coisa que elas: abrir algo que vai rodar agora.
  mxItem(
    'fluxo',
    glyph: Icon(Icons.account_tree_outlined, size: 14, color: Mx.purple),
    label: 'montar um fluxo…',
  ),
  if (resume)
    mxItem(
      'retomar',
      glyph: Icon(Icons.history, size: 14, color: Mx.fgDim),
      label: 'retomar conversa…',
    ),
  // Um `.md` do disco é a quarta coisa que se abre num lugar, e o lugar é
  // *onde ele está*. A linha era do menu do painel, que sabe de sessões e não
  // de arquivos: pra ler um documento você mirava numa sessão qualquer e
  // pedia um arquivo que quase nunca era da pasta dela. Ver
  // [AppStore.openMarkdown].
  mxItem(
    'markdown',
    glyph: Icon(Icons.description_outlined, size: 14, color: Mx.fgDim),
    label: 'abrir um markdown…',
  ),
  // Sem programa nenhum não há submenu a abrir: seria uma seta pra uma lista
  // de um item, e o item é a oferta de ensinar o primeiro.
  if (store.launchers.isEmpty)
    mxItem(
      'novo',
      glyph: Icon(Icons.add_circle_outline, size: 14, color: Mx.fgFaint),
      label: 'criar um programa…',
    )
  else
    MxSubmenuItem(
      label: 'meus programas',
      glyph: Icon(Icons.apps_outlined, size: 14, color: Mx.fgDim),
      // Lidos na hora de abrir o submenu: quem acabou de criar um programa
      // pelo diálogo da última linha o encontra aqui sem reabrir o menu.
      items: () => [
        // Na ordem em que foram criados -- é a ordem da lista das
        // configurações, e a lateral não tem por que discordar dela.
        for (final launcher in store.launchers)
          MxSubItem(
            value: 'launcher:${launcher.id}',
            label: launcher.name,
            glyph: Icon(launcher.icon.glyph, size: 14, color: launcher.color),
          ),
        MxSubItem(
          value: 'novo',
          label: 'outro programa…',
          glyph: Icon(Icons.add_circle_outline, size: 14, color: Mx.fgFaint),
          divided: true,
        ),
      ],
    ),
];

/// Faz o que a linha escolhida em [openHereItems] pede, e diz se a escolha era
/// dele -- os menus que o embutem têm as suas próprias linhas para tratar.
///
/// [cwd] é onde o painel abre, que só é a raiz da pasta quando não é uma
/// worktree; [label] é como ele se chama quando o nome da pasta não serve.
Future<bool> openHereChoice(
  BuildContext context,
  AppStore store,
  String choice, {
  required Folder folder,
  Project? project,
  String? cwd,
  String? label,
}) async {
  switch (choice) {
    case 'claude':
      store.openClaude(folder, cwd: cwd ?? folder.root, label: label, project: project);
    case 'fluxo':
      await showNewFlow(context, store, folder: folder, cwd: cwd, project: project);
    case 'shell':
      store.openShell(folder, cwd: cwd, project: project);
    case 'retomar':
      await showChatHistory(context, store, folder: folder, project: project);
    case 'markdown':
      // O painel nativo abre no lugar em que se clicou -- a raiz da pasta, ou
      // o checkout da worktree --, e o leitor nasce morando lá.
      await store.openMarkdown(folder: folder, cwd: cwd, project: project);
    case 'novo':
      // Criar e abrir de uma vez: você veio ao menu pra abrir um painel, e um
      // programa que nasce sem estrear obrigaria a voltar aqui pra usá-lo.
      final launcher = await showNewLauncher(context, store);
      if (launcher != null) {
        store.openLauncher(launcher, folder, cwd: cwd ?? folder.root, project: project);
      }
    default:
      if (!choice.startsWith('launcher:')) return false;
      final launcher = store.launcherById(choice.split(':').last);
      if (launcher != null) {
        store.openLauncher(launcher, folder, cwd: cwd ?? folder.root, project: project);
      }
  }
  return true;
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(title, style: const TextStyle(fontSize: 15)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(fontSize: 13),
        decoration: _field(label),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('ok')),
      ],
    ),
  );
}

/// The right-click menu of the terminal itself.
///
/// A second way in for copy and paste, one that owes nothing to AppKit's key
/// equivalents -- if ⌘V is ever swallowed again, this still works.
Future<void> showTerminalMenu(BuildContext context, MxTab tab, Offset globalPosition) async {
  final hasSelection = tab.term.controller.selection != null;
  final choice = await mxMenu<String>(
    context,
    at: globalPosition,
    items: [
      mxItem(
        'copy',
        glyph: Icon(Icons.content_copy, size: 13, color: Mx.fgDim),
        label: 'copiar',
        chord: '⌘C',
        enabled: hasSelection,
      ),
      mxItem(
        'paste',
        glyph: Icon(Icons.content_paste, size: 13, color: Mx.fgDim),
        label: 'colar',
        chord: '⌘V',
      ),
    ],
  );

  switch (choice) {
    case 'copy':
      await tab.term.copySelection();
    case 'paste':
      await tab.term.pasteClipboard(imagesViaCtrlV: tab.kind == TabKind.claude);
  }
}

/// The right-click menu of a panel, from its sidebar row or its pane header.
///
/// Anchored at the pointer, so it reads as belonging to the panel you clicked
/// and not to whatever widget happens to host it.
Future<void> showPanelMenu(
  BuildContext context,
  AppStore store,
  MxTab tab,
  Offset globalPosition,
) async {
  final grouped = store.groupOf(tab);
  // --- ditado (vocalização) — fora desta versão ------------------------------
  // Ver o cabeçalho de `services/dictation.dart`.
  // final recording = store.dictation.phaseOf(tab.id) == DictationPhase.recording;
  final choice = await mxMenu<String>(
    context,
    at: globalPosition,
    items: [
      // Primeiro porque, num painel de programa que saiu, é a única coisa que
      // se quer fazer com ele. Ver [AppStore.relaunch].
      if (tab.launcher != null && tab.exited) ...[
        mxItem(
          'relaunch',
          glyph: Icon(Icons.refresh, size: 14, color: tab.launcher!.color),
          label: 'rodar ${tab.launcher!.name} de novo',
        ),
        mxDivider(),
      ],
      // O bloco do que este painel *tem*: o nome dele, e o que a sessão
      // escreveu pra ser lido. Doze linhas seguidas eram uma parede; os riscos
      // são o que deixa o olho pular pro terço certo dela.
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'renomear…',
      ),
      // --- ditado (vocalização) — fora desta versão --------------------------
      // // A outra porta do ditado. O atalho é o gesto de todo dia; esta linha é
      // // como se descobre que ele existe -- e o único caminho pra quem trocou a
      // // tecla por uma que não lembra. Ver [AppStore.toggleDictation].
      // if (!tab.isReader && !tab.exited)
        // mxItem(
          // 'dictate',
          // glyph: Icon(
            // recording ? Icons.mic : Icons.mic_none,
            // size: 14,
            // color: recording ? Mx.red : Mx.fgDim,
          // ),
          // label: recording ? 'parar de ditar e colar' : 'ditar…',
        // ),
      // O que uma sessão do claude produziu pra ler. Os dois são markdown e
      // sempre foram; o que não havia era onde desenhá-los.
      if (tab.kind == TabKind.claude) ...[
        mxItem(
          'plan',
          glyph: Icon(Icons.checklist_rtl, size: 14, color: Mx.fgDim),
          label: tab.hooks.plans.length > 1
              ? 'ver o plano (${tab.hooks.plans.length})'
              : 'ver o plano',
          enabled: tab.hooks.plans.isNotEmpty,
        ),
        mxItem(
          'message',
          glyph: Icon(Icons.chat_bubble_outline, size: 14, color: Mx.fgDim),
          label: 'ver o último recado',
          enabled: (tab.hooks.lastMessageFull ?? '').trim().isNotEmpty,
        ),
        mxItem(
          'chain',
          glyph: Icon(Icons.account_tree_outlined, size: 14, color: Mx.fgDim),
          label: tab.followUps.isEmpty
              ? 'quando terminar…'
              : 'quando terminar… (${tab.followUps.length})',
        ),
      ],
      mxDivider(),
      // O bloco de onde o painel *mora* e de como ele está: grupo, projeto,
      // concluída. Nenhuma das três mexe no conteúdo dele.
      //
      // Agrupar é do painel que está na tela e da tela em que ele está: os
      // painéis da grade já aparecem acesos na lateral, e agrupar é apontar
      // pra um deles e dizer que aqueles andam juntos. Fora de uma grade a
      // linha não aparece -- um painel sozinho não é um conjunto.
      //
      // Painel que já é de um grupo ainda pode agrupar, desde que a tela não
      // seja aquele grupo: uma grade remontada em volta dele é um arranjo
      // novo, e sem isto não haveria como guardá-lo. A tela que *é* o grupo
      // não oferece -- ali agrupar seria salvar de novo o que já está salvo,
      // e quem atualiza um grupo é o menu dele.
      if (store.paneCount > 1 &&
          store.isOpen(tab) &&
          (grouped == null || !store.showing(grouped)))
        mxItem(
          'group',
          glyph: Icon(Icons.grid_view_rounded, size: 14, color: Mx.fgDim),
          label: 'agrupar painéis',
        ),
      if (grouped case final group?)
        mxItem(
          'ungroup',
          // Na cor do grupo, que é a cor com que a lateral lava as linhas
          // dele: é o que diz de qual grupo a linha está falando.
          glyph: Icon(Icons.grid_off, size: 14, color: group.color),
          label: 'desagrupar "${group.name}"',
        ),
      // Um leitor não vai pra projeto nem se marca como concluído: as duas
      // coisas se dizem de um trabalho, e ele é uma folha de papel. Estar fora
      // de pasta não impede mais: a bandeja também tem projeto. Ver
      // [showMoveToProject], que é quem diz quando ainda não tem nenhum.
      if (!tab.isReader)
        mxItem(
          'move',
          glyph: Icon(Icons.workspaces_outline, size: 14, color: Mx.purple),
          label: 'mover pro projeto…',
        ),
      if (!tab.isReader)
        mxItem(
          'done',
          glyph: Icon(
            tab.done ? Icons.task_alt : Icons.check_circle_outline,
            size: 14,
            color: tab.done ? Mx.green : Mx.fgDim,
          ),
          label: tab.done ? 'reabrir: não está concluída' : 'marcar como concluída',
        ),
      mxDivider(),
      mxItem(
        'close',
        glyph: Icon(Icons.close, size: 14, color: Mx.red),
        label: tab.isReader ? 'fechar o leitor' : 'fechar painel',
        color: Mx.red,
        // A tecla vem do mapa: ela é editável, e um menu que ensinasse ⌘⌫ a
        // quem trocou por outra estaria mentindo.
        chord: store.keymap[MxAction.closePane].firstOrNull?.label,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'relaunch':
      store.relaunch(tab);
    case 'group':
      final group = store.groupPanes();
      if (group != null) {
        // O grupo nasceu batizado pelo que ele abre, e trocar isso é o
        // "renomear" do menu dele -- o banner é onde isso se diz.
        store.showBanner('${group.count} painéis agrupados como "${group.name}"');
      }
    case 'ungroup':
      if (grouped != null) store.ungroup(grouped);
    // --- ditado (vocalização) — fora desta versão ----------------------------
    // case 'dictate':
      // await store.toggleDictation();
    case 'plan':
      store.showPlan(tab);
    case 'message':
      store.showMessage(tab);
    case 'chain':
      await showFlow(context, store, tab);
    case 'move':
      await showMoveToProject(context, store, tab);
    case 'rename':
      await showRenamePanel(context, store, tab);
    case 'done':
      markDone(context, store, tab, done: !tab.done, from: globalPosition);
    case 'close':
      store.closeTab(tab);
  }
}

/// O título de um painel, trocado à mão.
///
/// Uma função e não o corpo do item de menu porque são duas portas pra mesma
/// coisa: o menu do painel e o atalho ([MxAction.renamePane]), que renomeia o
/// que está em foco sem exigir mirar nele com o mouse.
Future<void> showRenamePanel(BuildContext context, AppStore store, MxTab tab) async {
  // An empty answer is not a no-op: it drops the custom label and hands the
  // title back to the branch/folder rule.
  final v = await promptText(
    context,
    title: 'renomear painel',
    initial: tab.title,
    label: 'título',
  );
  if (v != null) store.renameTab(tab, v);
}

/// "Essa funcionou": the mark, wherever it is asked for.
///
/// Shared by the pane header and the panel menu because the gesture has to
/// mean the same thing in both — including the confetti, which is the only
/// part of it that is not visible a second later. [from] is where the puff
/// comes out of, so it comes out of the thing you clicked.
///
/// Taking the mark back is silent on purpose: it is a correction, not an
/// occasion, and a second party for it would make the first one a joke.
void markDone(
  BuildContext context,
  AppStore store,
  MxTab tab, {
  required bool done,
  Offset? from,
}) {
  final dropped = store.setDone(tab, done);
  if (!done) return;
  if (from != null) Confetti.puff(context, at: from);
  // The row says the rest of it. This is only for the piece that vanished
  // without being seen -- see AppStore.setDone.
  if (dropped > 0) {
    store.showBanner(
      '${tab.title}: concluída — $dropped passo(s) da fila foram descartados',
    );
  }
}

/// Add a folder. The folder picker is the native sheet, which keeps the
/// dependency list at zero for something the OS already does well.
///
/// O campo aceita duas coisas, e é o mesmo campo pras duas: uma pasta, ou um
/// `.code-workspace` do VS Code -- que é uma lista de pastas que alguém já
/// digitou uma vez, e digitá-la de novo aqui, uma a uma, é o trabalho que este
/// caminho existe pra não pedir. Ver [CodeWorkspace] e
/// `AppStore.importWorkspace`.
Future<void> showAddFolder(BuildContext context, AppStore store) async {
  final controller = TextEditingController();
  // O que o seletor nativo respondeu quando não deu pra abrir, dito dentro do
  // diálogo e não numa tarja da janela: a tarja fica atrás dele.
  String? trouble;
  final path = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: const Text('adicionar pasta', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: _field('caminho do repo', '~/repos/...'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 10),
              // Wrap e não Row: são dois botões de texto lado a lado num
              // diálogo de largura fixa, e o que cabe neles depende da fonte
              // de quem está lendo -- num corpo maior o segundo desce em vez
              // de vazar.
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open, size: 15),
                    label: const Text('escolher pasta…'),
                    onPressed: () async {
                      final path = await Notifier.chooseFolder();
                      if (path != null && path.isNotEmpty) controller.text = path;
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.workspaces_outline, size: 15),
                    label: const Text('escolher workspace…'),
                    onPressed: () async {
                      final picked = await Notifier.chooseWorkspace();
                      // Sem painel do outro lado o clique não produzia nada --
                      // ver [Notifier.chooseWorkspace]. O campo aceita o
                      // caminho colado, então o botão morto ainda tem saída.
                      if (!picked.available) {
                        refresh(() {
                          trouble = 'não consegui abrir o seletor — cole aí em cima o '
                              'caminho do .code-workspace';
                        });
                        return;
                      }
                      final path = picked.path;
                      if (path != null && path.isNotEmpty) controller.text = path;
                    },
                  ),
                ],
              ),
              Text(
                trouble ?? 'um .code-workspace adiciona todas as pastas dele de uma vez.',
                style: TextStyle(
                  color: trouble == null ? Mx.fgFaint : Mx.yellow,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('adicionar'),
          ),
        ],
      ),
    ),
  );
  final typed = path?.trim() ?? '';
  if (typed.isEmpty) return;
  // Pela extensão, que é o único jeito de reconhecer um: por dentro o arquivo
  // é um json como outro qualquer.
  if (CodeWorkspace.looksLikeOne(typed)) {
    await store.importWorkspace(typed);
    return;
  }
  await store.addFolder(typed);
}

/// Open a loose panel in a folder maestria knows nothing about.
///
/// One step, not two: the folder and what to run in it are the same decision,
/// so the two buttons *are* the two answers. Nothing here is remembered — a
/// folder you want back tomorrow is a folder, and the + up top is for that.
Future<void> showLooseIn(BuildContext context, AppStore store) async {
  final controller = TextEditingController(text: store.loose.root);
  final kind = await showDialog<TabKind>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: const Text('abrir sem pasta', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: _field('pasta', 'onde o painel vai rodar'),
              onSubmitted: (_) => Navigator.pop(ctx, TabKind.claude),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              icon: const Icon(Icons.folder_open, size: 15),
              label: const Text('escolher pasta…'),
              onPressed: () async {
                final picked = await Notifier.chooseFolder();
                if (picked != null && picked.isNotEmpty) controller.text = picked;
              },
            ),
            Text(
              'o painel fica em "avulsos" — nenhuma pasta é adicionada.',
              style: TextStyle(color: Mx.fgFaint, fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('cancelar')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, TabKind.shell),
          child: const Text('terminal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, TabKind.claude),
          child: const Text('sessão do claude'),
        ),
      ],
    ),
  );

  // Digitado à mão, então `~/` também é caminho -- ver [expandHome].
  final path = expandHome(controller.text.trim());
  if (kind == null || path.isEmpty) return;
  if (!Directory(path).existsSync()) {
    store.showBanner('pasta não encontrada: $path', sticky: true);
    return;
  }
  if (kind == TabKind.claude) {
    store.openClaude(store.loose, cwd: path);
  } else {
    store.openShell(store.loose, cwd: path);
  }
}

/// The "nova task" flow: worktree with the team's naming, then a session in it.
Future<void> showNewTask(
  BuildContext context,
  AppStore store,
  Folder folder, {
  Project? project,
}) async {
  final id = TextEditingController();
  final branch = TextEditingController(text: 'feature/TASK#{id}');
  final dir = TextEditingController(text: 'TASK-{id}');
  final base = TextEditingController();
  final setup = TextEditingController();

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(
        'nova task em ${project?.name ?? folder.name}',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: _field('id da task', '47730'),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: branch,
                    style: const TextStyle(fontSize: 13),
                    decoration: _field('branch'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: dir,
                    style: const TextStyle(fontSize: 13),
                    decoration: _field('pasta da worktree'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: base,
              style: const TextStyle(fontSize: 13),
              decoration: _field('base', 'vazio = origin/HEAD'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: setup,
              style: const TextStyle(fontSize: 13),
              decoration: _field('comando pós-criação', 'ex: flutter pub get'),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '{id} é substituído. O "#" sai do nome da pasta e fica na branch.',
                style: TextStyle(color: Mx.fgFaint, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('criar e abrir')),
      ],
    ),
  );

  if (go != true || id.text.trim().isEmpty) return;
  await store.newTask(
    folder,
    taskId: id.text.trim(),
    branchPattern: branch.text.trim(),
    dirPattern: dir.text.trim(),
    baseRef: base.text.trim().isEmpty ? null : base.text.trim(),
    setupCommand: setup.text,
    project: project,
  );
}

/// Everything you can do to a worktree that is not "open it".
///
/// One definition, two ways in: the row's ⋯ and its right-click both land
/// here, anchored wherever the pointer was.
Future<void> showWorktreeMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  WorktreeInfo worktree,
  Offset globalPosition,
) async {
  final ghost = worktree.prunable;
  final choice = await mxMenu<String>(
    context,
    at: globalPosition,
    items: [
      // A folder that is not on disk cannot be opened in anything, so those
      // entries are absent rather than present and dead.
      if (!ghost) ...[
        // Sem retomar conversa: o histórico é o da pasta que se abriu na
        // lateral, e esta é outra pasta no disco -- as conversas dela não
        // estão naquela lista. Ver [openHereItems].
        ...openHereItems(store, resume: false),
        mxDivider(),
        mxItem(
          'code',
          glyph: Icon(Icons.code, size: 14, color: Mx.fgDim),
          label: 'abrir no vscode',
        ),
      ],
      mxItem(
        'copy',
        glyph: Icon(Icons.link, size: 14, color: Mx.fgDim),
        label: 'copiar caminho',
      ),
      if (!worktree.isMain)
        mxItem(
          'remove',
          glyph: Icon(
            ghost ? Icons.link_off : Icons.delete_outline,
            size: 14,
            color: Mx.red,
          ),
          label: ghost ? 'limpar registro…' : 'excluir worktree…',
          color: Mx.red,
        ),
    ],
  );
  if (choice == null || !context.mounted) return;

  // Tudo que abre um painel abre na pasta desta worktree, com o nome do
  // branch dela: é o que a distingue da pasta-mãe na lateral.
  if (await openHereChoice(
    context,
    store,
    choice,
    folder: folder,
    cwd: worktree.path,
    label: worktree.isMain ? null : worktree.shortLabel,
  )) {
    return;
  }
  if (!context.mounted) return;

  switch (choice) {
    case 'code':
      await store.openInEditor(worktree.path);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: worktree.path));
      store.showBanner('caminho copiado');
    case 'remove':
      await confirmRemoveWorktree(context, store, folder, worktree);
  }
}

/// Ask before deleting a worktree, with the two facts that decide the answer.
///
/// `git worktree remove` refusing a dirty checkout is the whole safety net, and
/// a button that always forces would spend it. So the numbers come first, the
/// force is what the wording admits to, and the branch is never thrown in for
/// free — mergeada or not, that is a second, checked decision.
Future<void> confirmRemoveWorktree(
  BuildContext context,
  AppStore store,
  Folder folder,
  WorktreeInfo worktree,
) async {
  final safety = await Git.safetyOf(worktree, root: folder.root);
  if (!context.mounted) return;
  var deleteBranch = false;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: Text(
          worktree.prunable ? 'limpar ${worktree.shortLabel}?' : 'excluir ${worktree.shortLabel}?',
          style: const TextStyle(fontSize: 15),
        ),
        content: SizedBox(
          width: 470,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                worktree.path,
                style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgFaint),
              ),
              const SizedBox(height: 14),
              if (worktree.prunable)
                _Fact(
                  icon: Icons.link_off,
                  color: Mx.fgDim,
                  text: 'a pasta já não existe — isso só limpa o registro que sobrou no git',
                )
              else ...[
                _Fact(
                  icon: safety.dirty == 0 ? Icons.check_rounded : Icons.warning_amber_rounded,
                  color: safety.dirty == 0 ? Mx.green : Mx.yellow,
                  text: safety.dirty == 0
                      ? 'nada não commitado'
                      : '${safety.dirty} arquivo(s) não commitado(s) — isso se perde',
                ),
                _Fact(
                  icon: safety.base == null
                      ? Icons.help_outline
                      : safety.unmerged == 0
                      ? Icons.check_rounded
                      : Icons.warning_amber_rounded,
                  color: safety.base == null
                      ? Mx.fgDim
                      : safety.unmerged == 0
                      ? Mx.green
                      : Mx.red,
                  text: safety.base == null
                      ? 'sem base pra comparar os commits'
                      : safety.unmerged == 0
                      ? 'todo commit daqui já está em ${safety.base}'
                      : '${safety.unmerged} commit(s) que não estão em ${safety.base}',
                ),
              ],
              if (!worktree.isMain && worktree.branch != '(detached)') ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => setState(() => deleteBranch = !deleteBranch),
                  borderRadius: BorderRadius.circular(6),
                  child: Row(
                    children: [
                      Checkbox(
                        value: deleteBranch,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => setState(() => deleteBranch = v ?? false),
                      ),
                      Expanded(
                        child: Text(
                          'apagar também a branch ${worktree.branch}',
                          style: TextStyle(fontSize: 12, color: Mx.fgDim),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Mx.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(safety.risky ? 'excluir de qualquer forma' : 'excluir'),
          ),
        ],
      ),
    ),
  );
  if (go != true) return;
  await store.removeWorktree(folder, worktree, force: safety.risky, deleteBranch: deleteBranch);
}

/// One line of "here is what is true about this worktree".
class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    ),
  );
}

/// Pergunta antes de fechar um workspace, com os dois fatos que decidem a
/// resposta: quantas pastas saem, e quantas sessões vão junto.
///
/// Pergunta porque o gesto é grande e não parece: uma linha da lateral leva
/// sete pastas, os projetos delas e as sessões que estiverem rodando. E os
/// números vêm antes do botão pelo mesmo motivo do diálogo da worktree -- o
/// que decide é o que se perde, não o nome do que se fecha.
Future<void> confirmCloseWorkspace(
  BuildContext context,
  AppStore store,
  Workspace workspace,
) async {
  final folders = store.foldersOf(workspace);
  final sessions = folders.fold<int>(0, (a, f) => a + store.tabsOf(f).length);

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('fechar ${workspace.name}?', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 470,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workspace.path,
              style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgFaint),
            ),
            const SizedBox(height: 14),
            _Fact(
              icon: Icons.folder_off_outlined,
              color: Mx.fgDim,
              text: folders.length == 1
                  ? '1 pasta sai da lateral'
                  : '${folders.length} pastas saem da lateral',
            ),
            // O que mais assusta num diálogo destes é o que ele *não* faz.
            _Fact(
              icon: Icons.check_rounded,
              color: Mx.green,
              text: 'nada é apagado do disco — nem os repos, nem o .code-workspace',
            ),
            if (sessions > 0)
              _Fact(
                icon: Icons.warning_amber_rounded,
                color: Mx.yellow,
                text: sessions == 1
                    ? '1 sessão aberta é encerrada'
                    : '$sessions sessões abertas são encerradas',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Mx.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('fechar workspace'),
        ),
      ],
    ),
  );
  if (go != true) return;
  await store.closeWorkspace(workspace);
}

// --- grupos -----------------------------------------------------------------

/// Pergunta antes de esquecer todos os arranjos salvos de uma vez -- o
/// "limpar" da régua dos grupos.
///
/// O "esquecer o grupo" de uma linha não pergunta nada, e por um bom motivo:
/// nada fecha, e aquele arranjo se salva de novo em dois cliques. Seis de uma
/// vez é outra aposta -- vão os nomes que você deu a eles, e não há como
/// adivinhar de volta quais eram --, então o botão diz o que vai levar antes
/// de levar. Um grupo só cai no caso de antes: perguntar ali seria perguntar
/// o que a linha dele já não pergunta.
Future<void> confirmClearGroups(BuildContext context, AppStore store) async {
  final total = store.groups.length;
  if (total == 0) return;
  if (total == 1) {
    final name = store.groups.single.name;
    store.clearGroups();
    store.showBanner('grupo "$name" esquecido — os painéis continuam abertos');
    return;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('esquecer os $total grupos?', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact(
              icon: Icons.check_rounded,
              color: Mx.green,
              text: 'nenhum painel fecha — a tela de agora fica exatamente como está',
            ),
            _Fact(
              icon: Icons.grid_view_rounded,
              color: Mx.fgDim,
              text: 'o que se perde são os $total arranjos guardados, com os nomes deles',
            ),
            _Fact(
              icon: Icons.replay,
              color: Mx.fgFaint,
              text: 'pra ter um de volta: arrume a grade e agrupe os painéis outra vez',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Mx.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('esquecer'),
        ),
      ],
    ),
  );
  if (go != true) return;

  final gone = store.clearGroups();
  store.showBanner('$gone grupos esquecidos — nenhum painel foi fechado');
}

// --- projects ---------------------------------------------------------------

/// Name a new project. The briefing is a second, optional step: you know what
/// you are calling the job before you know what to tell the agents about it.
Future<void> showNewProject(BuildContext context, AppStore store, Folder folder) async {
  final name = TextEditingController();
  final brief = TextEditingController();

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('novo projeto em ${folder.name}', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: _field('nome', 'permissão do google'),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: brief,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(fontSize: 13),
              decoration: _field(
                'briefing (opcional)',
                'o que todo agente desse projeto precisa saber antes de começar',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'o briefing entra como --append-system-prompt em toda sessão aberta '
              'aqui dentro — vale a conversa inteira, não só a primeira mensagem.',
              style: TextStyle(color: Mx.fgFaint, fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('criar')),
      ],
    ),
  );

  if (go != true) return;
  final label = name.text.trim();
  if (label.isEmpty) return;
  store.addProject(folder, label, brief: brief.text.trim());
}

/// Edit the standing context handed to every session of a project.
Future<void> showProjectBrief(BuildContext context, AppStore store, Project project) async {
  final brief = TextEditingController(text: project.brief);

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('briefing de ${project.name}', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: brief,
              autofocus: true,
              minLines: 6,
              maxLines: 14,
              style: const TextStyle(fontSize: 13),
              decoration: _field('contexto', 'o que já foi decidido, o que não encostar'),
            ),
            const SizedBox(height: 10),
            Text(
              'as sessões que já estão abertas não mudam — o briefing entra na linha '
              'de comando, então vale a partir da próxima que você abrir aqui.',
              style: TextStyle(color: Mx.fgFaint, fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('salvar')),
      ],
    ),
  );
  if (go == true) store.editProject(project, brief: brief.text.trim());
}

/// Everything you can do to a project that is not "fold it".
Future<void> showProjectMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  Project project,
  Offset globalPosition,
) async {
  final choice = await mxMenu<String>(
    context,
    at: globalPosition,
    items: [
      // Abrir algo no projeto é o que se vem fazer aqui, e é a mesma oferta do
      // + da linha dele -- inclusive os programas do usuário, que antes só
      // existiam lá. Ver [openHereItems].
      ...openHereItems(store),
      mxDivider(),
      // Uma worktree precisa de um repo pra ser worktree de -- ver
      // [MxKeys.run]. No projeto da bandeja a linha não aparece: ela abriria
      // um diálogo de branch e pasta que não tem onde acontecer.
      if (!folder.isLoose)
        mxItem(
          'task',
          glyph: Icon(Icons.call_split, size: 14, color: Mx.fgDim),
          label: 'nova task nesse projeto…',
        ),
      mxItem(
        'brief',
        glyph: Icon(Icons.assignment_outlined, size: 14, color: Mx.fgDim),
        label: 'briefing…',
      ),
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'renomear',
      ),
      mxDivider(),
      mxItem(
        'done',
        glyph: Icon(Icons.task_alt, size: 14, color: Mx.green),
        label: 'concluir projeto',
      ),
      mxItem(
        'dissolve',
        glyph: Icon(Icons.workspaces_outline, size: 14, color: Mx.red),
        label: 'dissolver projeto',
        color: Mx.red,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  if (await openHereChoice(context, store, choice, folder: folder, project: project)) return;
  if (!context.mounted) return;

  switch (choice) {
    case 'task':
      await showNewTask(context, store, folder, project: project);
    case 'brief':
      await showProjectBrief(context, store, project);
    case 'rename':
      final name = await promptText(
        context,
        title: 'renomear projeto',
        initial: project.name,
        label: 'nome',
      );
      if (name != null && name.trim().isNotEmpty) store.editProject(project, name: name);
    case 'done':
      await confirmCompleteProject(context, store, project);
    case 'dissolve':
      // The panels outlive it: see AppStore.removeProject.
      store.removeProject(project);
      store.showBanner(
        folder.isLoose
            ? 'projeto dissolvido — os painéis continuam abertos nos avulsos'
            : 'projeto dissolvido — os painéis continuam abertos na pasta',
      );
  }
}

/// "Acabou" — the other way a project ends, and the only one that is good news.
///
/// Dissolving and concluding are not the same gesture wearing two labels: one
/// drops a name off work that goes on, the other says the work is over and
/// closes the sessions with it. Which is why this asks first and that does not
/// — dissolving loses a label, this ends four running sessions.
///
/// The dialog is a list of what concluding costs, in the shape
/// [confirmRemoveWorktree] already uses for the same job: the panels that
/// close, whether any of them is still mid-turn, and the briefing that goes
/// away with the project. Then confetti, because a job finishing is the one
/// thing that happens in this window that is worth more than a banner.
Future<void> confirmCompleteProject(
  BuildContext context,
  AppStore store,
  Project project,
) async {
  final tabs = store.tabsIn(project);
  final busy = tabs
      .where((t) => t.status == ClaudeStatus.working || t.status == ClaudeStatus.tool)
      .length;
  final waiting = store.needingHumanIn(project);
  final hasBrief = project.brief.trim().isNotEmpty;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('concluir "${project.name}"?', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact(
              icon: tabs.isEmpty ? Icons.check_rounded : Icons.close_rounded,
              color: tabs.isEmpty ? Mx.green : Mx.fgDim,
              text: tabs.isEmpty
                  ? 'não tem painel aberto nesse projeto'
                  : 'fecha ${tabs.length} painel(is) — as sessões terminam aqui',
            ),
            if (busy > 0)
              _Fact(
                icon: Icons.warning_amber_rounded,
                color: Mx.yellow,
                text: '$busy painel(is) ainda no meio de um turno',
              ),
            if (waiting > 0)
              _Fact(
                icon: Icons.warning_amber_rounded,
                color: Mx.red,
                text: '$waiting painel(is) esperando você responder',
              ),
            if (hasBrief)
              _Fact(
                icon: Icons.sticky_note_2_outlined,
                color: Mx.fgDim,
                text: 'o briefing vai junto — copie o texto antes se for reaproveitar',
              ),
            _Fact(
              icon: Icons.folder_outlined,
              color: Mx.fgFaint,
              text: 'nada é mexido no repo: o projeto só existia aqui',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Mx.green),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(busy + waiting > 0 ? 'concluir de qualquer forma' : 'concluir'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final closed = store.completeProject(project);
  Confetti.fire(context);
  store.showBanner(
    closed == 0
        ? '"${project.name}" concluído 🎉'
        : '"${project.name}" concluído 🎉 — $closed painel(is) fechado(s)',
  );
}

/// Which project a panel belongs to, as a list to pick from.
Future<void> showMoveToProject(BuildContext context, AppStore store, MxTab tab) async {
  final folder = tab.folder;
  final projects = store.projectsOf(folder);
  if (projects.isEmpty) {
    store.showBanner(
      folder.isLoose
          ? 'os avulsos ainda não têm projeto — crie um pelo + da bandeja'
          : 'essa pasta ainda não tem projeto — crie um pelo "+ projeto"',
    );
    return;
  }

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('mover "${tab.title}" pra…', style: const TextStyle(fontSize: 15)),
      children: [
        for (final p in projects)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p.id),
            child: Row(
              children: [
                Icon(
                  Icons.workspaces_outline,
                  size: 15,
                  color: tab.projectId == p.id ? Mx.accent : Mx.purple,
                ),
                const SizedBox(width: 9),
                Text(p.name, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ''),
          child: Row(
            children: [
              Icon(Icons.remove_circle_outline, size: 15, color: Mx.fgFaint),
              const SizedBox(width: 9),
              Text(
                folder.isLoose ? 'nenhum — solto na bandeja' : 'nenhum — solto na pasta',
                style: TextStyle(fontSize: 13, color: Mx.fgDim),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice == null) return;
  store.assign(tab, choice.isEmpty ? null : store.projectById(choice));
}

/// O menu do filtro da lateral: uma folha que fica aberta enquanto você marca.
///
/// Um `showMenu` comum fecha a cada item escolhido, e marcar quatro coisas
/// seria abrir o menu quatro vezes. Então este tem *um* item, desligado — ele
/// existe só pela folha, a sombra e o clique-fora, que é tudo o que um menu
/// precisa dar — e o conteúdo trata os próprios toques e se redesenha no
/// lugar. A lateral atrás dele reage a cada marca, porque o store notifica.
Future<void> showFilterMenu(BuildContext context, AppStore store, Offset anchor) async {
  await mxMenu<void>(
    context,
    at: anchor,
    items: [
      PopupMenuItem<void>(
        enabled: false,
        height: 0,
        padding: EdgeInsets.zero,
        child: StatefulBuilder(
          builder: (context, setState) =>
              _FilterSheet(store: store, redraw: () => setState(() {})),
        ),
      ),
    ],
  );
}

/// O conteúdo do menu de filtro: onde, tipo, estado.
///
/// "Onde" vem primeiro e é a lista do próprio usuário — os repos que ele
/// cadastrou e os jobs que ele nomeou. Tipo e estado são as perguntas que a
/// lateral já sabia responder por linha e não sabia responder por lista.
class _FilterSheet extends StatelessWidget {
  const _FilterSheet({required this.store, required this.redraw});

  final AppStore store;
  final VoidCallback redraw;

  @override
  Widget build(BuildContext context) {
    final loose = store.tabsOf(store.loose);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 226, maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (store.folders.isNotEmpty || loose.isNotEmpty) ...[
            const _FilterLabel('onde'),
            for (final f in store.folders) ...[
              _FilterRow(
                label: f.name,
                icon: Icons.folder_outlined,
                on: store.filterRoots.contains(f.root),
                onTap: () {
                  store.toggleFilterFolder(f);
                  redraw();
                },
              ),
              // Os projetos entram um passo pra dentro da pasta deles: é assim
              // que a lateral os mostra, e o menu não é um segundo mapa.
              for (final p in store.projectsOf(f))
                _FilterRow(
                  label: p.name,
                  icon: Icons.workspaces_outline,
                  color: Mx.purple,
                  indent: 14,
                  on: store.filterProjects.contains(p.id),
                  onTap: () {
                    store.toggleFilterProject(p);
                    redraw();
                  },
                ),
            ],
            // A bandeja só aparece quando há algo nela — filtrar por um lugar
            // vazio é pedir uma lista vazia.
            if (loose.isNotEmpty) ...[
              _FilterRow(
                label: store.loose.name,
                icon: Icons.inbox_outlined,
                on: store.filterRoots.contains(store.loose.root),
                onTap: () {
                  store.toggleFilterFolder(store.loose);
                  redraw();
                },
              ),
              // Um passo pra dentro da régua, como os projetos de uma pasta:
              // a bandeja também nomeia trabalho agora.
              for (final p in store.projectsOf(store.loose))
                _FilterRow(
                  label: p.name,
                  icon: Icons.workspaces_outline,
                  color: Mx.purple,
                  indent: 14,
                  on: store.filterProjects.contains(p.id),
                  onTap: () {
                    store.toggleFilterProject(p);
                    redraw();
                  },
                ),
            ],
          ],
          for (final group in MxFilterGroup.values) ...[
            _FilterLabel(group.label),
            for (final f in MxFilter.values.where((f) => f.group == group))
              _FilterRow(
                label: f.label,
                on: store.filterFlags.contains(f),
                onTap: () {
                  store.toggleFilter(f);
                  redraw();
                },
              ),
          ],
          if (store.filtering) ...[
            Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 5), color: Mx.border),
            InkWell(
              onTap: () {
                store.clearSearch();
                Navigator.pop(context);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  children: [
                    Icon(Icons.filter_list_off_rounded, size: 14, color: Mx.fgDim),
                    const SizedBox(width: 8),
                    Text(
                      'mostrar tudo de novo',
                      style: TextStyle(fontSize: 12, color: Mx.fgDim),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// O nome de uma prateleira do menu. Ver [MxFilterGroup].
class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: Mx.fgFaint),
    ),
  );
}

/// Uma opção marcável. A caixa fica na esquerda e o glifo do que a opção *é*
/// vem depois dela, quando existe: marcado ou não é o que muda ao clicar, e é
/// o que a coluna da esquerda tem que responder.
class _FilterRow extends StatefulWidget {
  const _FilterRow({
    required this.label,
    required this.on,
    required this.onTap,
    this.icon,
    this.color,
    this.indent = 0,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? color;
  final double indent;

  @override
  State<_FilterRow> createState() => _FilterRowState();
}

class _FilterRowState extends State<_FilterRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? Mx.bgHover : Colors.transparent,
          padding: EdgeInsets.fromLTRB(10 + widget.indent, 6, 12, 6),
          child: Row(
            children: [
              Icon(
                on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 15,
                color: on ? Mx.accent : Mx.fgFaint,
              ),
              const SizedBox(width: 8),
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 13, color: widget.color ?? Mx.fgFaint),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: on ? Mx.fg : Mx.fgDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- histórico de conversas -------------------------------------------------

/// As conversas que já rodaram aqui, pra clicar numa e retomá-la.
///
/// Um diálogo e não uma bandeja na lateral, como a dos grupos: um grupo é uma
/// linha e são três ou quatro, enquanto o histórico desta máquina tem sessenta
/// conversas numa pasta só -- na lateral isso empurraria as sessões abertas,
/// que é o que ela existe pra mostrar, pra fora da tela. Aqui a lista custa
/// zero até ser pedida, e o pedido é o mesmo `+` com que se abre qualquer
/// coisa numa pasta.
/// As conversas de [folder], ou as de todas as pastas quando ele não vem.
///
/// Sem pasta é o histórico da janela -- ver [AppStore.allChats] --, que é a
/// pergunta do rodapé da lateral: achar uma conversa sem lembrar em que repo
/// ela rodou. Com pasta é o "deste repo", que é como o + de uma pasta pensa.
Future<void> showChatHistory(
  BuildContext context,
  AppStore store, {
  Folder? folder,
  Project? project,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ChatHistory(store: store, folder: folder, project: project),
);

class _ChatHistory extends StatefulWidget {
  const _ChatHistory({required this.store, this.folder, this.project});
  final AppStore store;

  /// Nulo é o histórico inteiro. Ver [showChatHistory].
  final Folder? folder;
  final Project? project;

  @override
  State<_ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<_ChatHistory> {
  /// Pedido uma vez, no `initState` que o `late final` faz: um `build` que
  /// relesse o disco releria a cada repintura do diálogo.
  late final Future<List<ChatEntry>> _chats = switch (widget.folder) {
    final folder? => widget.store.chatsIn(folder),
    null => widget.store.allChats(),
  };

  /// Como o diálogo se chama, que é a única coisa que diz de onde é a lista:
  /// as linhas são as mesmas nos três casos.
  String get _title => switch (widget.folder) {
    null => 'todas as conversas',
    final folder when folder.isLoose => 'conversas de antes',
    final folder => 'conversas em ${folder.name}',
  };

  /// A pasta em que o painel retomado vai morar, quando dá pra saber daqui.
  ///
  /// Nula nos dois históricos que não são de uma pasta -- o inteiro e o da
  /// bandeja dos avulsos, que é o mesmo --, porque ali cada linha é de um
  /// lugar diferente: quem sabe qual é o caminho da conversa, e a volta dele
  /// pra uma pasta da lateral é do store.
  Folder? get _at => (widget.folder?.isLoose ?? true) ? null : widget.folder;

  @override
  Widget build(BuildContext context) {
    // O diálogo cresce até onde a janela deixa: a lista é longa e cada linha
    // tem título, pasta e data, então quanto mais couber de uma vez menos rola.
    // As folgas são o que o [AlertDialog] gasta em volta -- margem dos lados,
    // título e o `fechar` embaixo -- pra que o teto nunca passe da tela.
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(760.0, screen.width - 112);
    final maxHeight = math.min(620.0, screen.height - 260);

    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(_title, style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: width,
        child: FutureBuilder<List<ChatEntry>>(
          future: _chats,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 90,
                child: Center(
                  child: SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                ),
              );
            }
            final chats = snap.data ?? const <ChatEntry>[];
            if (chats.isEmpty) {
              return Text(
                switch (widget.folder) {
                  final folder? when !folder.isLoose =>
                    'nenhuma conversa em ${folder.name} ainda — as que houver '
                        'aparecem aqui na próxima vez.',
                  _ => 'o claude não guardou nenhuma conversa ainda.',
                },
                style: TextStyle(fontSize: 12, color: Mx.fgDim),
              );
            }
            return ConstrainedBox(
              // Rola dentro do diálogo: quarenta linhas não caberiam numa tela
              // de laptop, e um diálogo mais alto que a janela não fecha.
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final chat in chats)
                    _ChatRow(
                      key: ValueKey(chat.sessionId),
                      store: widget.store,
                      chat: chat,
                      onTap: () {
                        // Fecha antes de abrir: o painel novo aparece atrás do
                        // diálogo, e o gesto acabou quando a conversa foi
                        // escolhida.
                        Navigator.pop(context);
                        widget.store.resumeChat(
                          chat,
                          folder: _at,
                          project: widget.project,
                        );
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('fechar')),
      ],
    );
  }
}

/// Uma conversa, numa linha: o nome que ela tem, onde e quando rodou, e o
/// aviso de por que ela não abriria agora, quando é o caso.
class _ChatRow extends StatefulWidget {
  const _ChatRow({super.key, required this.store, required this.chat, required this.onTap});
  final AppStore store;
  final ChatEntry chat;
  final VoidCallback onTap;

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final standing = widget.store.standingOf(chat);
    // A cor do aviso é a do estado: verde é a conversa que já está aqui na
    // tela, amarelo é a que não abre -- as mesmas duas de [ClaudeStatusUi].
    final tint = switch (standing) {
      ChatStanding.onScreen => Mx.green,
      ChatStanding.live || ChatStanding.gone => Mx.yellow,
      ChatStanding.fresh => Mx.fgFaint,
    };
    // A conversa cujo transcript não disse em que pasta rodou cai no mesmo
    // [ChatStanding.gone] -- ela também não tem onde ser retomada --, mas por
    // outro motivo, e o aviso é o do motivo.
    final note = standing == ChatStanding.gone && chat.cwd.isEmpty
        ? 'não sei onde ela rodou'
        : standing.note;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? Mx.bgHover : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: standing == ChatStanding.gone
                    ? Icon(Icons.link_off, size: 13, color: Mx.yellow)
                    : const ClaudeMark(size: 13),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        // Apagada a que não abre: a linha continua clicável --
                        // o clique é o que explica por quê --, mas ela não
                        // disputa o olho com as que abrem.
                        color: standing == ChatStanding.gone ? Mx.fgDim : Mx.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            // O tamanho do transcript é o que se tem de "quão
                            // longa foi" sem abrir o arquivo, e a pasta
                            // importa mesmo com o histórico filtrado: uma
                            // worktree é outra pasta.
                            [chat.ago, chat.where, chat.size].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: Mx.mono,
                              fontSize: 10.5,
                              height: 1.2,
                              color: Mx.fgFaint,
                            ),
                          ),
                        ),
                        if (note != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            note,
                            style: TextStyle(fontSize: 10.5, height: 1.2, color: tint),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// O que o formulário de um programa devolve: o mesmo trio, seja pra criar um
/// ou pra reescrever o que já existe.
typedef LauncherDraft = ({String name, String command, LauncherIcon icon});

/// Ensina um programa novo e devolve ele já salvo, ou null se você desistiu.
///
/// Quem chama decide o que fazer em seguida -- o menu do + abre um painel com
/// ele na hora, a tela de configurações só o acrescenta à lista.
Future<Launcher?> showNewLauncher(BuildContext context, AppStore store) async {
  final draft = await _launcherForm(context, title: 'novo programa');
  if (draft == null) return null;
  return store.addLauncher(name: draft.name, command: draft.command, icon: draft.icon);
}

/// O mesmo formulário sobre um programa que já existe. Vale na hora e em todo
/// painel dele: ver [AppStore.editLauncher].
Future<void> showEditLauncher(BuildContext context, AppStore store, Launcher launcher) async {
  final draft = await _launcherForm(context, title: 'editar programa', initial: launcher);
  if (draft == null) return;
  store.editLauncher(
    launcher,
    name: draft.name,
    command: draft.command,
    icon: draft.icon,
  );
}

Future<LauncherDraft?> _launcherForm(
  BuildContext context, {
  required String title,
  Launcher? initial,
}) => showDialog<LauncherDraft>(
  context: context,
  builder: (ctx) => _LauncherForm(title: title, initial: initial),
);

/// Nome, comando e desenho -- as três coisas que um [Launcher] é.
///
/// Com estado porque o ícone é escolhido clicando: um `showDialog` de conteúdo
/// fixo não repinta a escolha, e um seletor que não mostra o que está
/// selecionado não é um seletor.
class _LauncherForm extends StatefulWidget {
  const _LauncherForm({required this.title, this.initial});

  final String title;
  final Launcher? initial;

  @override
  State<_LauncherForm> createState() => _LauncherFormState();
}

class _LauncherFormState extends State<_LauncherForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _command = TextEditingController(
    text: widget.initial?.command ?? '',
  );
  late LauncherIcon _icon = widget.initial?.icon ?? LauncherIcon.terminal;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    super.dispose();
  }

  /// O comando é o obrigatório; o nome, não. Um programa sem nome se chama
  /// pela primeira palavra do que ele roda -- `npm run dev` vira "npm", e
  /// `btop` vira "btop", que é o que você teria digitado ali de qualquer
  /// forma. Ninguém devia ter que batizar o btop.
  void _submit() {
    final command = _command.text.trim();
    if (command.isEmpty) return;
    final typed = _name.text.trim();
    Navigator.pop(context, (
      name: typed.isEmpty ? command.split(RegExp(r'\s+')).first : typed,
      command: command,
      icon: _icon,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(widget.title, style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _command,
              autofocus: true,
              style: TextStyle(fontSize: 13, fontFamily: Mx.mono),
              decoration: _field('comando', 'btop, lazygit, npm run dev…'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            Text(
              'roda no painel como você digitaria no terminal — e o painel '
              'abre já dentro dele, sem prompt no caminho.',
              style: TextStyle(color: Mx.fgFaint, fontSize: 11, height: 1.35),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              style: const TextStyle(fontSize: 13),
              decoration: _field('nome', 'como ele aparece no menu e na lateral'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text('desenho', style: TextStyle(color: Mx.fgDim, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final icon in LauncherIcon.values)
                  _IconChip(
                    icon: icon,
                    selected: icon == _icon,
                    onTap: () => setState(() => _icon = icon),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancelar')),
        FilledButton(onPressed: _submit, child: const Text('salvar')),
      ],
    );
  }
}

/// Um dos desenhos possíveis, do tamanho em que ele vai ser visto na lateral.
class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.selected, required this.onTap});

  final LauncherIcon icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: icon.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: selected ? Mx.bgActive : Mx.bg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: selected ? Mx.accent : Mx.border),
            ),
            child: Icon(icon.glyph, size: 16, color: selected ? Mx.fg : Mx.fgDim),
          ),
        ),
      ),
    );
  }
}

// --- relatório do dia -------------------------------------------------------

/// De que dia é o relatório.
///
/// Ele sempre foi de hoje, e hoje era o dia errado quase sempre: o relatório é
/// falado na daily da manhã seguinte, quando o dia que interessa é ontem -- e
/// de vez em quando o que se quer é o dia 25 de agosto, que alguém precisa
/// lembrar. Então o clique pergunta antes, com os dois botões que respondem
/// quase toda vez e um mês pra andar quando não respondem.
///
/// O calendário é desenhado aqui em vez de ser o `showDatePicker` do Material
/// por dois motivos. Ele fala inglês -- "August 2025", "CANCEL" -- enquanto o
/// `flutter_localizations` não estiver no projeto, e o app é todo em
/// português. E ele é muito diálogo pra uma pergunta de um clique: vem com
/// cabeçalho colorido, campo pra digitar a data e seletor de ano, três coisas
/// que aqui não têm o que fazer.
///
/// [today] existe pros testes: em uso é sempre agora.
Future<void> showDailyReport(BuildContext context, AppStore store, {DateTime? today}) async {
  if (store.writingReport) {
    store.showBanner('já estou escrevendo um relatório — esse leva alguns minutos');
    return;
  }
  final day = await showDialog<DateTime>(
    context: context,
    builder: (_) => _DayPicker(today: today ?? DateTime.now()),
  );
  if (day == null) return;
  await store.openDailyReport(day: day);
}

class _DayPicker extends StatefulWidget {
  const _DayPicker({required this.today});

  /// Hoje, lido uma vez na abertura: um `DateTime.now()` consultado a cada
  /// repintura mudaria de resposta num diálogo aberto na virada da meia-noite.
  final DateTime today;

  @override
  State<_DayPicker> createState() => _DayPickerState();
}

class _DayPickerState extends State<_DayPicker> {
  DateTime get _today => widget.today;

  /// O mês na tela, sempre no dia 1.
  late DateTime _month = DateTime(_today.year, _today.month);

  /// As iniciais dos dias, começando no domingo -- que é como um calendário se
  /// lê em português.
  static const _initials = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];

  /// O lado de uma casa do calendário. Sete delas são a largura do diálogo.
  ///
  /// Bem maior que os 12 px de fonte do resto do chrome, e de propósito: o
  /// diálogo tem uma pergunta só e é o alvo de um clique de mira -- um mês
  /// desenhado no corpo dos rótulos da lateral virava um selinho no meio de
  /// uma janela de mil pixels, e acertar 25 num quadrado de 34 é pontaria.
  static const _cell = 46.0;

  void _step(int months) => setState(() => _month = DateTime(_month.year, _month.month + months));

  /// Se há mês pra frente. Amanhã não teve dia nenhum ainda.
  bool get _ahead => _month.isBefore(DateTime(_today.year, _today.month));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      // Um mês de seis semanas -- agosto de 2025, que começa numa sexta -- é
      // 46 px mais alto que um de cinco, e numa janela baixa isso não cabia:
      // o mês saía cortado por onde o `Column` estourava. Rolar é a saída
      // certa pra uma casa desse tamanho; encolher a casa pra caber no pior
      // caso seria pagar o mês inteiro pelo mês raro.
      scrollable: true,
      title: const Text('relatório de que dia?', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: _cell * 7,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _quick('hoje', _today)),
                const SizedBox(width: Mx.gap),
                // Pela aritmética do calendário, não por 24 horas: no domingo
                // em que o horário de verão entra as duas contas divergem.
                Expanded(
                  child: _quick('ontem', DateTime(_today.year, _today.month, _today.day - 1)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _arrow(Icons.chevron_left_rounded, () => _step(-1)),
                Expanded(
                  child: Center(
                    child: Text(
                      DailyReport.monthName(_month),
                      style: TextStyle(fontSize: 14, color: Mx.fg, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
                _arrow(Icons.chevron_right_rounded, _ahead ? () => _step(1) : null),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                for (final initial in _initials)
                  SizedBox(
                    width: _cell,
                    height: 24,
                    child: Center(
                      child: Text(initial, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                    ),
                  ),
              ],
            ),
            _grid(),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancelar')),
      ],
    );
  }

  /// Um dos dois dias que respondem a pergunta quase toda vez.
  Widget _quick(String label, DateTime day) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      foregroundColor: Mx.fg,
      side: BorderSide(color: Mx.border),
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 36),
      textStyle: const TextStyle(fontSize: 13),
    ),
    onPressed: () => Navigator.pop(context, day),
    child: Text(label),
  );

  Widget _arrow(IconData icon, VoidCallback? onPressed) => IconButton(
    icon: Icon(icon, color: onPressed == null ? Mx.fgFaint : Mx.fgDim),
    onPressed: onPressed,
    iconSize: 22,
    splashRadius: 17,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    padding: EdgeInsets.zero,
  );

  Widget _grid() {
    final first = DateTime(_month.year, _month.month);
    // O dia 0 do mês seguinte é o último deste: é a conta que acerta fevereiro
    // sem ninguém aqui escrever a regra do ano bissexto.
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    // `weekday` é segunda=1 e domingo=7, e a grade começa no domingo.
    final lead = first.weekday % 7;
    return Wrap(
      children: [
        for (var i = 0; i < lead; i++) const SizedBox(width: _cell, height: _cell),
        for (var d = 1; d <= days; d++) _day(DateTime(_month.year, _month.month, d)),
      ],
    );
  }

  Widget _day(DateTime day) {
    final ahead = day.isAfter(_today);
    final today = DailyReport.sameDay(day, _today);
    final text = Text(
      '${day.day}',
      style: TextStyle(
        fontSize: 14,
        color: ahead ? Mx.fgFaint : Mx.fg,
        fontWeight: today ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    return SizedBox(
      width: _cell,
      height: _cell,
      // Um dia que ainda não chegou fica escrito e morto: apagá-lo da grade
      // desalinharia o mês, e deixá-lo clicável abriria um relatório vazio.
      child: ahead
          ? Center(child: text)
          : InkWell(
              onTap: () => Navigator.pop(context, day),
              borderRadius: BorderRadius.circular(10),
              child: DecoratedBox(
                decoration: today
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Mx.accent),
                      )
                    : const BoxDecoration(),
                child: Center(child: text),
              ),
            ),
    );
  }
}
