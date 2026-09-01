import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/git.dart';
import '../services/notify.dart';
import '../services/store.dart';
import '../theme.dart';
import 'confetti.dart';

InputDecoration _field(String label, [String? hint]) => InputDecoration(
  labelText: label,
  hintText: hint,
  isDense: true,
  labelStyle: TextStyle(color: Mx.fgDim, fontSize: 12),
  hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12),
  border: const OutlineInputBorder(),
);

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
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final hasSelection = tab.term.controller.selection != null;
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: [
      PopupMenuItem(
        value: 'copy',
        height: 34,
        enabled: hasSelection,
        child: const Text('copiar  ⌘C', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
        value: 'paste',
        height: 34,
        child: Text('colar  ⌘V', style: TextStyle(fontSize: 12)),
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
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: [
      const PopupMenuItem(
        value: 'rename',
        height: 34,
        child: Text('renomear…', style: TextStyle(fontSize: 12)),
      ),
      if (tab.kind == TabKind.claude)
        PopupMenuItem(
          value: 'chain',
          height: 34,
          child: Text(
            tab.followUps.isEmpty
                ? 'quando terminar…'
                : 'quando terminar… (${tab.followUps.length})',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      if (!tab.folder.isLoose)
        const PopupMenuItem(
          value: 'move',
          height: 34,
          child: Text('mover pro projeto…', style: TextStyle(fontSize: 12)),
        ),
      PopupMenuItem(
        value: 'done',
        height: 34,
        child: Text(
          tab.done ? 'reabrir: não está concluída' : 'marcar como concluída',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      PopupMenuItem(
        value: 'close',
        height: 34,
        child: Text('fechar painel', style: TextStyle(fontSize: 12, color: Mx.red)),
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'chain':
      await showFollowUps(context, store, tab);
    case 'move':
      await showMoveToProject(context, store, tab);
    case 'rename':
      // An empty answer is not a no-op: it drops the custom label and hands the
      // title back to the branch/folder rule.
      final v = await promptText(
        context,
        title: 'renomear painel',
        initial: tab.title,
        label: 'título',
      );
      if (v != null) store.renameTab(tab, v);
    case 'done':
      markDone(context, store, tab, done: !tab.done, from: globalPosition);
    case 'close':
      store.closeTab(tab);
  }
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

/// Add a folder. The folder picker is `osascript`, which keeps the dependency
/// list at zero for something the OS already does well.
Future<void> showAddFolder(BuildContext context, AppStore store) async {
  final controller = TextEditingController();
  final path = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: const Text('adicionar pasta', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: _field('caminho do repo', '/Volumes/Dev-Mac/repos/...'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.folder_open, size: 15),
                label: const Text('escolher pasta…'),
                onPressed: () async {
                  final path = await Notifier.chooseFolder();
                  if (path != null && path.isNotEmpty) controller.text = path;
                },
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
  );
  if (path != null && path.trim().isNotEmpty) {
    await store.addFolder(path.trim());
  }
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

  final path = controller.text.trim();
  if (kind == null || path.isEmpty) return;
  if (!Directory(path).existsSync()) {
    store.showBanner('pasta não encontrada: $path');
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
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final ghost = worktree.prunable;
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: [
      // A folder that is not on disk cannot be opened in anything, so those
      // entries are absent rather than present and dead.
      if (!ghost) ...[
        const PopupMenuItem(
          value: 'code',
          height: 34,
          child: Text('abrir no vscode', style: TextStyle(fontSize: 12)),
        ),
        const PopupMenuItem(
          value: 'claude',
          height: 34,
          child: Text('nova sessão do claude aqui', style: TextStyle(fontSize: 12)),
        ),
        const PopupMenuItem(
          value: 'shell',
          height: 34,
          child: Text('novo terminal aqui', style: TextStyle(fontSize: 12)),
        ),
      ],
      const PopupMenuItem(
        value: 'copy',
        height: 34,
        child: Text('copiar caminho', style: TextStyle(fontSize: 12)),
      ),
      if (!worktree.isMain)
        PopupMenuItem(
          value: 'remove',
          height: 34,
          child: Text(
            ghost ? 'limpar registro…' : 'excluir worktree…',
            style: TextStyle(fontSize: 12, color: Mx.red),
          ),
        ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'code':
      await store.openInEditor(worktree.path);
    case 'claude':
      store.openClaude(
        folder,
        cwd: worktree.path,
        label: worktree.isMain ? null : worktree.shortLabel,
      );
    case 'shell':
      store.openShell(folder, cwd: worktree.path);
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
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: const [
      PopupMenuItem(
        value: 'claude',
        height: 34,
        child: Text('nova sessão aqui', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'task',
        height: 34,
        child: Text('nova task nesse projeto…', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'shell',
        height: 34,
        child: Text('novo terminal aqui', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'brief',
        height: 34,
        child: Text('briefing…', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'rename',
        height: 34,
        child: Text('renomear', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'done',
        height: 34,
        child: Text('concluir projeto', style: TextStyle(fontSize: 12)),
      ),
      PopupMenuItem(
        value: 'dissolve',
        height: 34,
        child: Text('dissolver projeto', style: TextStyle(fontSize: 12)),
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'claude':
      store.openClaude(folder, cwd: folder.root, project: project);
    case 'task':
      await showNewTask(context, store, folder, project: project);
    case 'shell':
      store.openShell(folder, project: project);
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
      store.showBanner('projeto dissolvido — os painéis continuam abertos na pasta');
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
    store.showBanner('essa pasta ainda não tem projeto — crie um pelo "+ projeto"');
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
                'nenhum — solto na pasta',
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

// --- follow-ups -------------------------------------------------------------

/// Arm a panel with what to do when it next goes quiet.
/// What one fork was sent to do and how far it got.
///
/// The row can only afford a line; this is the rest of it -- the brief in
/// full, the tools it has called in order, and what it reported back. For a
/// fork still running it is the closest thing to looking over its shoulder,
/// since its own scrollback never reaches this window.
Future<void> showSubagent(BuildContext context, MxTab tab, SubagentState agent) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: Row(
          children: [
            Icon(
              agent.running ? Icons.call_split : Icons.check_rounded,
              size: 16,
              color: agent.running ? agent.shownStatus.color : Mx.fgDim,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(agent.title, style: const TextStyle(fontSize: 15))),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (agent.agentType.isNotEmpty) agent.agentType,
                    if (agent.background) 'background',
                    agent.running ? 'rodando há ${SubagentState.elapsedLabel(agent.elapsed)}' 
                        : 'terminou em ${SubagentState.elapsedLabel(agent.elapsed)}',
                    if (agent.tokens != null) '${agent.tokens} tokens',
                    '${agent.tools} ferramenta(s)',
                    'em ${tab.title}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
                ),
                if (agent.prompt.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SubagentSection(title: 'o que foi pedido', body: agent.prompt, mono: true),
                ],
                if (agent.trail.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SubagentSection(
                    title: agent.running ? 'onde está' : 'por onde passou',
                    body: agent.trail.reversed.join('\n'),
                    mono: true,
                  ),
                ],
                if (agent.lastMessageFull != null) ...[
                  const SizedBox(height: 14),
                  _SubagentSection(title: 'o que reportou', body: agent.lastMessageFull!),
                ],
                const SizedBox(height: 14),
                Text(
                  'agent_id ${agent.agentId}',
                  style: TextStyle(fontFamily: Mx.mono, fontSize: 10, color: Mx.fgFaint),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('fechar')),
        ],
      ),
    );

class _SubagentSection extends StatelessWidget {
  const _SubagentSection({required this.title, required this.body, this.mono = false});

  final String title;
  final String body;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 11, color: Mx.fgDim, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Mx.bg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Mx.border),
          ),
          child: SelectableText(
            body,
            style: TextStyle(
              fontFamily: mono ? Mx.mono : null,
              fontSize: mono ? 11 : 12.5,
              color: Mx.fg,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showFollowUps(BuildContext context, AppStore store, MxTab tab) =>
    showDialog<void>(
      context: context,
      builder: (_) => _FollowUpEditor(store: store, tab: tab),
    );

/// One step being edited. The controller is why the list is drafted in state
/// and only turned into [FollowUp]s on save.
class _Draft {
  _Draft(this.kind, {String text = '', this.targetTabId})
    : text = TextEditingController(text: text);

  FollowUpKind kind;
  final TextEditingController text;
  String? targetTabId;
}

class _FollowUpEditor extends StatefulWidget {
  const _FollowUpEditor({required this.store, required this.tab});
  final AppStore store;
  final MxTab tab;

  @override
  State<_FollowUpEditor> createState() => _FollowUpEditorState();
}

class _FollowUpEditorState extends State<_FollowUpEditor> {
  late final List<_Draft> _steps = [
    for (final f in widget.tab.followUps)
      _Draft(f.kind, text: f.text, targetTabId: f.targetTabId),
  ];

  /// Every other live Claude panel in the same folder: a handoff is a message
  /// typed into someone else's prompt, so it needs a prompt to type into.
  List<MxTab> get _candidates => widget.store.tabs
      .where(
        (t) =>
            t.id != widget.tab.id &&
            t.kind == TabKind.claude &&
            !t.exited &&
            t.folderRoot == widget.tab.folderRoot,
      )
      .toList();

  @override
  void dispose() {
    for (final s in _steps) {
      s.text.dispose();
    }
    super.dispose();
  }

  void _add(FollowUpKind kind, {String text = ''}) =>
      setState(() => _steps.add(_Draft(kind, text: text)));

  void _save() {
    widget.store.queue(widget.tab, [
      for (final s in _steps)
        // A handoff carries the panel's closing message on its own, so it is
        // the one kind that is still a step with nothing typed into it -- but
        // only once it has somewhere to go.
        if (s.kind == FollowUpKind.handoff
            ? s.targetTabId != null
            : s.text.text.trim().isNotEmpty)
          FollowUp(kind: s.kind, text: s.text.text.trim(), targetTabId: s.targetTabId),
    ]);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final targets = _candidates;
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(
        'quando "${widget.tab.title}" terminar',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_steps.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'nada encadeado ainda.',
                    style: TextStyle(color: Mx.fgFaint, fontSize: 12),
                  ),
                ),
              for (var i = 0; i < _steps.length; i++) _stepCard(i, targets),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _addChip('continuar', FollowUpKind.keepGoing),
                  _addChip('outra sessão', FollowUpKind.newSession),
                  _addChip('comando', FollowUpKind.command),
                  if (targets.isNotEmpty) _addChip('passar a bola', FollowUpKind.handoff),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'um passo por vez: o primeiro dispara na próxima vez que a sessão ficar '
                'ociosa, o seguinte na vez depois dessa — inclusive depois de algo que '
                'você mesmo mandar. A fila não sobrevive a fechar o app.',
                style: TextStyle(color: Mx.fgFaint, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancelar')),
        FilledButton(onPressed: _save, child: const Text('armar')),
      ],
    );
  }

  Widget _addChip(String label, FollowUpKind kind) => ActionChip(
    avatar: Icon(kind.icon, size: 14, color: Mx.fgDim),
    label: Text(label, style: const TextStyle(fontSize: 11.5)),
    backgroundColor: Mx.bgActive,
    side: BorderSide(color: Mx.border),
    onPressed: () => _add(kind, text: kind == FollowUpKind.newSession ? _reviewPrompt : ''),
  );

  /// The one prompt worth pre-writing: a fresh session that reads the diff the
  /// panel before it left behind. Fresh is the point — it judges the work, not
  /// the reasoning that produced it.
  static const _reviewPrompt =
      'Revise o que acabou de ser feito nesta worktree: leia `git status` e '
      '`git diff`, procure bugs, regressões e coisas fora do padrão do repo. '
      'Não altere nada — só relate o que achou.';

  Widget _stepCard(int i, List<MxTab> targets) {
    final step = _steps[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: Mx.bgActive,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${i + 1}',
                style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgFaint),
              ),
              const SizedBox(width: 10),
              DropdownButton<FollowUpKind>(
                value: step.kind,
                isDense: true,
                underline: const SizedBox.shrink(),
                dropdownColor: Mx.bgActive,
                style: TextStyle(fontSize: 12, color: Mx.fg),
                items: [
                  for (final k in FollowUpKind.values)
                    if (k != FollowUpKind.handoff || targets.isNotEmpty)
                      DropdownMenuItem(
                        value: k,
                        child: Row(
                          children: [
                            Icon(k.icon, size: 14, color: Mx.fgDim),
                            const SizedBox(width: 7),
                            Text(k.label),
                          ],
                        ),
                      ),
                ],
                onChanged: (k) => setState(() => step.kind = k ?? step.kind),
              ),
              const Spacer(),
              InkWell(
                onTap: () => setState(() => _steps.removeAt(i).text.dispose()),
                borderRadius: BorderRadius.circular(5),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: Mx.fgFaint),
                ),
              ),
            ],
          ),
          if (step.kind == FollowUpKind.handoff) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.arrow_right_alt, size: 16, color: Mx.fgFaint),
                const SizedBox(width: 7),
                DropdownButton<String>(
                  value: targets.any((t) => t.id == step.targetTabId)
                      ? step.targetTabId
                      : null,
                  hint: Text(
                    'pra qual painel',
                    style: TextStyle(fontSize: 12, color: Mx.fgFaint),
                  ),
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  dropdownColor: Mx.bgActive,
                  style: TextStyle(fontSize: 12, color: Mx.fg),
                  items: [
                    for (final t in targets)
                      DropdownMenuItem(value: t.id, child: Text(t.title)),
                  ],
                  onChanged: (id) => setState(() => step.targetTabId = id),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          TextField(
            controller: step.text,
            minLines: step.kind == FollowUpKind.command ? 1 : 2,
            maxLines: 6,
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: step.kind == FollowUpKind.command ? Mx.mono : null,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: switch (step.kind) {
                FollowUpKind.keepGoing => 'o que mandar pra ela em seguida',
                FollowUpKind.newSession => 'o prompt com que a sessão nova abre',
                FollowUpKind.command => 'flutter analyze && flutter test',
                FollowUpKind.handoff => 'o recado que vai junto com a última mensagem dela',
              },
              hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// O menu do filtro da lateral: uma folha que fica aberta enquanto você marca.
///
/// Um `showMenu` comum fecha a cada item escolhido, e marcar quatro coisas
/// seria abrir o menu quatro vezes. Então este tem *um* item, desligado — ele
/// existe só pela folha, a sombra e o clique-fora, que é tudo o que um menu
/// precisa dar — e o conteúdo trata os próprios toques e se redesenha no
/// lugar. A lateral atrás dele reage a cada marca, porque o store notifica.
Future<void> showFilterMenu(BuildContext context, AppStore store, Offset anchor) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  await showMenu<void>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(anchor & Size.zero, Offset.zero & overlay.size),
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
            if (loose.isNotEmpty)
              _FilterRow(
                label: store.loose.name,
                icon: Icons.inbox_outlined,
                on: store.filterRoots.contains(store.loose.root),
                onTap: () {
                  store.toggleFilterFolder(store.loose);
                  redraw();
                },
              ),
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
