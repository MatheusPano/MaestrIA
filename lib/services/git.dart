import '../models.dart';
import 'shell.dart';

/// Git, only as much of it as a session cockpit needs.
class Git {
  /// The main checkout for any path inside a repo or one of its worktrees.
  ///
  /// `worktree list` always prints the main worktree first, which is more
  /// portable than `rev-parse --git-common-dir` and gets worktrees to group
  /// under the folder they belong to instead of showing up as loose repos.
  static Future<String?> mainRoot(String path) async {
    final r = await Sh.run('git worktree list --porcelain', cwd: path);
    if (!r.ok) return null;
    for (final line in r.stdout.split('\n')) {
      if (line.startsWith('worktree ')) return line.substring(9).trim();
    }
    return null;
  }

  /// The repo's worktrees, or null when git could not answer at all.
  ///
  /// The difference matters to the caller: an empty list means "ran fine, no
  /// repo here", null means "ask again later". Collapsing both into `[]` is
  /// what let a single lost `git` call drop a folder's worktree folder --
  /// and shove every row below it up the sidebar -- until the next refresh.
  static Future<List<WorktreeInfo>?> worktrees(String root) async {
    final r = await Sh.run('git worktree list --porcelain', cwd: root);
    if (!r.ok) return _notARepo(r) ? const <WorktreeInfo>[] : null;
    final out = <WorktreeInfo>[];
    String? path;
    String branch = '(detached)';
    var prunable = false;
    var first = true;
    void flush() {
      if (path == null) return;
      out.add(WorktreeInfo(path: path!, branch: branch, isMain: first, prunable: prunable));
      first = false;
      path = null;
      branch = '(detached)';
      prunable = false;
    }

    for (final line in r.stdout.split('\n')) {
      if (line.startsWith('worktree ')) {
        flush();
        path = line.substring(9).trim();
      } else if (line.startsWith('branch ')) {
        branch = line.substring(7).trim().replaceFirst('refs/heads/', '');
      } else if (line.startsWith('prunable')) {
        prunable = true;
      }
    }
    flush();
    return out;
  }

  static Future<String> branchOf(String path) async {
    final r = await Sh.run('git rev-parse --abbrev-ref HEAD', cwd: path);
    return r.ok ? r.stdout : '';
  }

  /// Dirty file count, for the "uncommitted work" dot on a tab. Null when the
  /// call failed for any reason other than there being no repo -- see
  /// [worktrees]: a dot that blinks off on a lost call is worse than a stale one.
  static Future<int?> dirtyCount(String path) async {
    final r = await Sh.run('git status --porcelain', cwd: path);
    if (!r.ok) return _notARepo(r) ? 0 : null;
    if (r.stdout.isEmpty) return 0;
    return r.stdout.split('\n').where((l) => l.trim().isNotEmpty).length;
  }

  /// git's own words for "there is no repo here", told apart from every other
  /// reason a call can fail: an index lock, a folder that went away, a shell
  /// that came back empty.
  static bool _notARepo(ShResult r) {
    final e = r.stderr;
    return e.contains('not a git repository') ||
        e.contains('not a work tree') ||
        e.contains('no such file or directory');
  }

  static Future<String?> defaultRemoteRef(String root) async {
    final r = await Sh.run('git symbolic-ref --quiet refs/remotes/origin/HEAD || echo', cwd: root);
    if (r.ok && r.stdout.isNotEmpty) {
      return r.stdout.replaceFirst('refs/remotes/', '');
    }
    for (final candidate in ['origin/master', 'origin/main']) {
      final v = await Sh.run('git rev-parse --verify ${Sh.q(candidate)}', cwd: root);
      if (v.ok) return candidate;
    }
    return null;
  }

  /// Create the worktree the way the team names things, not the way a tool does.
  ///
  /// Claude Code's own `--worktree x` would brand the branch `worktree-x`, and
  /// it rejects `#` in the name outright -- which is exactly the reason these
  /// worktrees get made by hand today. Here the directory is sanitized and the
  /// branch keeps the convention.
  static Future<GitOutcome> addWorktree({
    required String root,
    required String dirName,
    required String branch,
    required String baseRef,
  }) async {
    final path = '$root/.claude/worktrees/$dirName';
    final exists = await Sh.run('test -d ${Sh.q(path)}');
    if (exists.ok) return GitOutcome(false, path, 'worktree já existe em $path');

    await Sh.run('git fetch origin --quiet', cwd: root);
    final r = await Sh.run(
      'git worktree add ${Sh.q(path)} -b ${Sh.q(branch)} ${Sh.q(baseRef)}',
      cwd: root,
    );
    if (!r.ok) return GitOutcome(false, path, r.stderr.isEmpty ? r.stdout : r.stderr);
    return GitOutcome(true, path, 'worktree criada em $path (branch $branch)');
  }

  /// What a worktree stands to lose, asked before anything is deleted.
  static Future<WorktreeSafety> safetyOf(WorktreeInfo w, {required String root}) async {
    // A prunable worktree has no checkout left to read: there is nothing in it
    // to lose, which is exactly what makes it safe to clear.
    if (w.prunable) return const WorktreeSafety(dirty: 0, unmerged: 0);
    final dirty = await dirtyCount(w.path) ?? 0;
    final base = await defaultRemoteRef(root);
    var unmerged = 0;
    if (base != null) {
      final r = await Sh.run('git rev-list --count ${Sh.q(base)}..HEAD', cwd: w.path);
      unmerged = int.tryParse(r.stdout) ?? 0;
    }
    return WorktreeSafety(dirty: dirty, unmerged: unmerged, base: base);
  }

  /// Remove a worktree, and only if asked, the branch that came with it.
  ///
  /// `remove` refuses a worktree whose folder is missing -- for those the
  /// command git wants is `prune`, which clears every stale registration at
  /// once. Both paths end with the same list being one entry shorter, so they
  /// are the same button in the UI.
  static Future<GitOutcome> removeWorktree({
    required String root,
    required WorktreeInfo worktree,
    bool force = false,
    bool deleteBranch = false,
  }) async {
    if (worktree.isMain) {
      return GitOutcome(false, worktree.path, 'essa é a checkout principal — ela não se remove');
    }

    final r = worktree.prunable
        ? await Sh.run('git worktree prune', cwd: root)
        : await Sh.run(
            'git worktree remove ${force ? '--force ' : ''}${Sh.q(worktree.path)}',
            cwd: root,
          );
    if (!r.ok) {
      return GitOutcome(false, worktree.path, r.stderr.isEmpty ? r.stdout : r.stderr);
    }

    final said = [
      worktree.prunable
          ? 'registros fantasmas limpos'
          : 'worktree removida: ${worktree.path.split('/').last}',
    ];
    if (deleteBranch && worktree.branch != '(detached)') {
      final b = await Sh.run(
        'git branch ${force ? '-D' : '-d'} ${Sh.q(worktree.branch)}',
        cwd: root,
      );
      said.add(
        b.ok
            ? 'branch ${worktree.branch} apagada'
            : 'branch mantida (${b.stderr.isEmpty ? b.stdout : b.stderr})',
      );
    }
    return GitOutcome(true, worktree.path, said.join(' · '));
  }

  /// Clear every stale registration the repo is carrying.
  static Future<GitOutcome> prune(String root) async {
    final r = await Sh.run('git worktree prune -v', cwd: root);
    if (!r.ok) return GitOutcome(false, root, r.stderr.isEmpty ? r.stdout : r.stderr);
    final cleared = r.stdout.split('\n').where((l) => l.trim().isNotEmpty).length;
    return GitOutcome(
      true,
      root,
      cleared == 0 ? 'nenhuma worktree fantasma pra limpar' : '$cleared registro(s) limpo(s)',
    );
  }
}

/// The two numbers that decide whether a worktree can go: what was never
/// committed, and what was committed but lives nowhere else.
class WorktreeSafety {
  const WorktreeSafety({required this.dirty, required this.unmerged, this.base});
  final int dirty;
  final int unmerged;

  /// The ref the commits were counted against, `null` when there was none to
  /// compare with -- which is itself worth saying out loud.
  final String? base;

  bool get risky => dirty > 0 || unmerged > 0;
}

class GitOutcome {
  GitOutcome(this.ok, this.path, this.message);
  final bool ok;
  final String path;
  final String message;
}
