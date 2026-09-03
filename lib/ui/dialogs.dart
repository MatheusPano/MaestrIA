import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/git.dart';
import '../services/history.dart';
import '../services/notify.dart';
import '../services/paths.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
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
  final grouped = store.groupOf(tab);
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(globalPosition & Size.zero, Offset.zero & overlay.size),
    items: [
      // Primeiro porque, num painel de programa que saiu, é a única coisa que
      // se quer fazer com ele. Ver [AppStore.relaunch].
      if (tab.launcher != null && tab.exited)
        PopupMenuItem(
          value: 'relaunch',
          height: 34,
          child: Text(
            'rodar ${tab.launcher!.name} de novo',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      const PopupMenuItem(
        value: 'rename',
        height: 34,
        child: Text('renomear…', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
        value: 'markdown',
        height: 34,
        child: Text('abrir um markdown…', style: TextStyle(fontSize: 12)),
      ),
      // O que uma sessão do claude produziu pra ler. Os dois são markdown e
      // sempre foram; o que não havia era onde desenhá-los.
      if (tab.kind == TabKind.claude) ...[
        PopupMenuItem(
          value: 'plan',
          height: 34,
          enabled: tab.hooks.plans.isNotEmpty,
          child: Text(
            tab.hooks.plans.length > 1
                ? 'ver o plano (${tab.hooks.plans.length})'
                : 'ver o plano',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        PopupMenuItem(
          value: 'message',
          height: 34,
          enabled: (tab.hooks.lastMessageFull ?? '').trim().isNotEmpty,
          child: Text('ver o último recado', style: const TextStyle(fontSize: 12)),
        ),
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
      ],
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
        const PopupMenuItem(
          value: 'group',
          height: 34,
          child: Text('agrupar painéis', style: TextStyle(fontSize: 12)),
        ),
      if (grouped case final group?)
        PopupMenuItem(
          value: 'ungroup',
          height: 34,
          child: Text('desagrupar "${group.name}"', style: const TextStyle(fontSize: 12)),
        ),
      // Um leitor não vai pra projeto nem se marca como concluído: as duas
      // coisas se dizem de um trabalho, e ele é uma folha de papel. Estar fora
      // de pasta não impede mais: a bandeja também tem projeto. Ver
      // [showMoveToProject], que é quem diz quando ainda não tem nenhum.
      if (!tab.isReader)
        const PopupMenuItem(
          value: 'move',
          height: 34,
          child: Text('mover pro projeto…', style: TextStyle(fontSize: 12)),
        ),
      if (!tab.isReader)
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
        child: Text(
          tab.isReader ? 'fechar o leitor' : 'fechar painel',
          style: TextStyle(fontSize: 12, color: Mx.red),
        ),
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
    case 'markdown':
      // Começa na pasta deste painel: o arquivo que se quer ler é quase sempre
      // o que a sessão dele acabou de escrever.
      await store.openMarkdown(from: tab);
    case 'plan':
      store.showPlan(tab);
    case 'message':
      store.showMessage(tab);
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

  // Digitado à mão, então `~/` também é caminho -- ver [expandHome].
  final path = expandHome(controller.text.trim());
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
    items: [
      const PopupMenuItem(
        value: 'claude',
        height: 34,
        child: Text('nova sessão aqui', style: TextStyle(fontSize: 12)),
      ),
      // Uma worktree precisa de um repo pra ser worktree de -- ver
      // [MxKeys.run]. No projeto da bandeja a linha não aparece: ela abriria
      // um diálogo de branch e pasta que não tem onde acontecer.
      if (!folder.isLoose)
        const PopupMenuItem(
          value: 'task',
          height: 34,
          child: Text('nova task nesse projeto…', style: TextStyle(fontSize: 12)),
        ),
      const PopupMenuItem(
        value: 'shell',
        height: 34,
        child: Text('novo terminal aqui', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
        value: 'brief',
        height: 34,
        child: Text('briefing…', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
        value: 'rename',
        height: 34,
        child: Text('renomear', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
        value: 'done',
        height: 34,
        child: Text('concluir projeto', style: TextStyle(fontSize: 12)),
      ),
      const PopupMenuItem(
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

// --- follow-ups -------------------------------------------------------------

/// Arm a panel with what to do when it next goes quiet.
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
Future<void> showChatHistory(
  BuildContext context,
  AppStore store,
  Folder folder, {
  Project? project,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ChatHistory(store: store, folder: folder, project: project),
);

class _ChatHistory extends StatefulWidget {
  const _ChatHistory({required this.store, required this.folder, this.project});
  final AppStore store;
  final Folder folder;
  final Project? project;

  @override
  State<_ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<_ChatHistory> {
  /// Pedido uma vez, no `initState` que o `late final` faz: um `build` que
  /// relesse o disco releria a cada repintura do diálogo.
  late final Future<List<ChatEntry>> _chats = widget.store.chatsIn(widget.folder);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text(
        widget.folder.isLoose ? 'conversas de antes' : 'conversas em ${widget.folder.name}',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: 560,
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
                widget.folder.isLoose
                    ? 'o claude não guardou nenhuma conversa ainda.'
                    : 'nenhuma conversa em ${widget.folder.name} ainda — as que '
                          'houver aparecem aqui na próxima vez.',
                style: TextStyle(fontSize: 12, color: Mx.fgDim),
              );
            }
            return ConstrainedBox(
              // Rola dentro do diálogo: quarenta linhas não caberiam numa tela
              // de laptop, e um diálogo mais alto que a janela não fecha.
              constraints: const BoxConstraints(maxHeight: 420),
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
                          // Sem pasta no histórico inteiro: quem sabe de onde
                          // aquela conversa é é o caminho dela, e é o store
                          // que faz essa volta.
                          folder: widget.folder.isLoose ? null : widget.folder,
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
