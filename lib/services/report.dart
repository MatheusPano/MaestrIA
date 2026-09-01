import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'shell.dart';

/// One panel's day, flattened out of the store.
///
/// A plain record on purpose: the report is written from what the cockpit
/// already knows, and this file has no business knowing what an `MxTab` is.
class SessionNote {
  const SessionNote({
    required this.title,
    required this.folder,
    required this.kind,
    required this.status,
    required this.startedAt,
    this.project,
    this.branch = '',
    this.prompts = 0,
    this.tools = 0,
    this.touched = const [],
    this.lastPrompt,
    this.lastMessage,
    this.exited = false,
  });

  final String title;
  final String folder;
  final String? project;

  /// `claude`, `shell`, or `fora do cockpit` for a session someone started in
  /// another terminal — the report is about the day, not about this window.
  final String kind;
  final String status;
  final DateTime startedAt;
  final String branch;
  final int prompts;
  final int tools;
  final List<String> touched;
  final String? lastPrompt;
  final String? lastMessage;
  final bool exited;
}

/// A commit made today, as `git log` hands it over.
class _Commit {
  _Commit(this.hash, this.time, this.ref, this.subject);
  final String hash;
  final String time;
  final String ref;
  final String subject;
}

/// Work that exists but is not committed anywhere yet.
class _Bench {
  _Bench(this.label, this.path, this.files);
  final String label;
  final String path;
  final List<String> files;
}

/// The day, gathered and then handed to Claude to be told back as prose.
///
/// The split is the whole design: everything factual — which commits, which
/// worktrees are dirty, which panels ran and what they wrote — is collected
/// here, deterministically, by the process that already knows it. Claude only
/// turns that material into the paragraph a person reads at 18h. Asking it to
/// go and *find* the day instead would be four minutes of tool calls and a
/// report that misses the sessions, because those live in this window and
/// nowhere else.
class DailyReport {
  /// Longer than a report ever takes, short enough that a hung CLI does not
  /// leave the dialog spinning until the app is quit.
  static const timeout = Duration(minutes: 4);

  /// Caps, so one absurd day cannot grow the prompt without bound.
  static const _maxCommits = 40;
  static const _maxDirtyFiles = 12;
  static const _maxTouched = 25;

  static String get _home => Platform.environment['HOME'] ?? '/';

  // --- the material -------------------------------------------------------

  /// Everything the report is made of, as markdown, before Claude sees it.
  ///
  /// Also what the dialog shows when you ask what it was written from: a
  /// summary you cannot audit is a summary you cannot trust.
  static Future<String> material({
    required List<Folder> folders,
    required Map<String, List<WorktreeInfo>> worktrees,
    required List<Project> projects,
    required List<SessionNote> sessions,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final out = StringBuffer()
      ..writeln('# material do dia — ${_longDate(at)}, ${_hhmm(at)}')
      ..writeln();

    // Folders in parallel: each one is a handful of round trips through a
    // login shell, and they have nothing to say to each other.
    final gathered = await Future.wait([
      for (final f in folders) _folderSection(f, worktrees[f.root] ?? const []),
    ]);

    out.writeln('## pastas');
    out.writeln();
    if (gathered.isEmpty) {
      out.writeln('nenhuma pasta cadastrada no cockpit.');
      out.writeln();
    } else {
      for (final section in gathered) {
        out.write(section);
      }
    }

    if (projects.isNotEmpty) {
      out.writeln('## projetos');
      out.writeln();
      for (final p in projects) {
        final panels = sessions.where((s) => s.project == p.name).length;
        out.writeln('- ${p.name} (pasta ${p.folderRoot.split('/').last}) — $panels painel(éis)');
        final brief = p.brief.trim();
        if (brief.isNotEmpty) out.writeln('  briefing: ${_oneLine(brief, 300)}');
      }
      out.writeln();
    }

    out.writeln('## sessões');
    out.writeln();
    if (sessions.isEmpty) {
      out.writeln('nenhuma sessão aberta hoje.');
    } else {
      for (final s in sessions) {
        out.writeln(_session(s));
      }
    }
    out.writeln();
    return out.toString();
  }

  static Future<String> _folderSection(Folder f, List<WorktreeInfo> trees) async {
    final out = StringBuffer('### ${f.name} (${f.root})');
    if (f.branch.isNotEmpty) out.write(' — checkout principal em ${f.branch}');
    out.writeln();

    if (!f.isRepo) {
      out
        ..writeln('não é um repositório git — não há commits pra contar aqui.')
        ..writeln();
      return out.toString();
    }

    final email = (await Sh.run('git config user.email', cwd: f.root)).stdout.trim();
    final commits = await _commitsToday(f.root, email);
    out.writeln(
      email.isEmpty
          ? 'commits de hoje (autor não filtrado — o repo não tem user.email configurado):'
          : 'commits de hoje, de $email:',
    );
    if (commits.isEmpty) {
      out.writeln('- nenhum.');
    } else {
      for (final c in commits) {
        out.writeln('- ${c.time} · ${c.hash} · ${c.ref} · ${c.subject}');
      }
    }

    // The bench: every checkout of this repo that is carrying uncommitted
    // work. Also the honest half of a day — four commits and nine dirty
    // files is a different day from four commits and a clean tree.
    final benches = await Future.wait([
      for (final w in trees.where((w) => !w.prunable))
        _benchOf(w.path, w.isMain ? f.name : w.shortLabel, w.branch),
    ]);
    final dirty = benches.whereType<_Bench>().toList();
    if (dirty.isEmpty) {
      out.writeln('sem trabalho pendente: todas as checkouts estão limpas.');
    } else {
      out.writeln('trabalho ainda não commitado:');
      for (final b in dirty) {
        out.writeln('- ${b.label} (${b.path}): ${b.files.length} arquivo(s)');
        for (final file in b.files.take(_maxDirtyFiles)) {
          out.writeln('  · $file');
        }
        if (b.files.length > _maxDirtyFiles) {
          out.writeln('  · … e mais ${b.files.length - _maxDirtyFiles}');
        }
      }
    }
    out.writeln();
    return out.toString();
  }

  /// Today's commits across every ref of the repo, so a worktree's branch
  /// counts without having to be visited.
  static Future<List<_Commit>> _commitsToday(String root, String email) async {
    final author = email.isEmpty ? '' : ' --author=${Sh.q(email)}';
    final r = await Sh.run(
      'git log --all --source --no-merges --since=midnight$author '
      "--date=format:'%H:%M' --pretty=format:'%h§%ad§%S§%s'",
      cwd: root,
    );
    if (!r.ok) return const [];
    final out = <_Commit>[];
    for (final line in r.stdout.split('\n')) {
      final parts = line.split('§');
      if (parts.length < 4) continue;
      out.add(
        _Commit(
          parts[0],
          parts[1],
          parts[2].replaceFirst('refs/heads/', '').replaceFirst('refs/remotes/', ''),
          parts.sublist(3).join('§'),
        ),
      );
      if (out.length >= _maxCommits) break;
    }
    return out;
  }

  static Future<_Bench?> _benchOf(String path, String label, String branch) async {
    final r = await Sh.run('git status --porcelain', cwd: path);
    if (!r.ok || r.stdout.isEmpty) return null;
    final files = r.stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (files.isEmpty) return null;
    return _Bench(branch.isEmpty ? label : '$label · $branch', path, files);
  }

  static String _session(SessionNote s) {
    final out = StringBuffer('- [${s.kind}] ${s.title}');
    if (s.project != null) out.write(' · projeto ${s.project}');
    out.write(' · pasta ${s.folder}');
    if (s.branch.isNotEmpty && s.branch != '(detached)') out.write(' · branch ${s.branch}');
    out.write(' · aberta ${_hhmm(s.startedAt)} · ${s.exited ? 'encerrada' : s.status}');
    if (s.prompts > 0 || s.tools > 0) {
      out.write(' · ${s.prompts} pedido(s), ${s.tools} ferramenta(s)');
    }
    if (s.lastPrompt != null && s.lastPrompt!.trim().isNotEmpty) {
      out.write('\n  último pedido: ${_oneLine(s.lastPrompt!, 240)}');
    }
    if (s.lastMessage != null && s.lastMessage!.trim().isNotEmpty) {
      out.write('\n  última resposta: ${_oneLine(s.lastMessage!, 400)}');
    }
    if (s.touched.isNotEmpty) {
      final shown = s.touched.take(_maxTouched).join(', ');
      final rest = s.touched.length > _maxTouched ? ' … +${s.touched.length - _maxTouched}' : '';
      out.write('\n  mexeu em: $shown$rest');
    }
    return out.toString();
  }

  // --- the report ---------------------------------------------------------

  /// What Claude is asked to do with the material. Kept next to it, because
  /// the two are one prompt and drift apart the moment they are not.
  static String promptFor(String material) =>
    '''
Você é o assistente do maestria, o cockpit onde este usuário toca as sessões de
Claude Code do dia dele. Abaixo vai o material bruto de hoje, coletado pelo
próprio app: commits, trabalho não commitado e as sessões que rodaram.

Escreva o relatório do dia, em português do Brasil e em markdown, pra ele mesmo
ler no fim do expediente.

- comece com uma frase só, dizendo como foi o dia;
- depois uma seção `##` por frente de trabalho (o projeto quando houver, senão a
  pasta), em prosa curta: o que avançou e o que isso significa. Não repita a
  lista de commits linha a linha — resuma o que eles fizeram juntos;
- termine com uma seção `## em aberto`: o que ficou sem commit, as sessões
  paradas esperando resposta, e o próximo passo que o material sugere;
- só o que está no material. Não invente tarefa, decisão nem resultado, e se o
  dia foi vazio diga isso em uma linha e pare;
- sem preâmbulo, sem "aqui está o relatório", sem fechamento genérico, sem
  perguntar se ele quer mais alguma coisa. No máximo 400 palavras.

---

$material
''';

  /// Run the report. One headless `claude -p`, nothing else on the machine.
  static Future<ReportOutcome> ask(String material) async {
    final at = DateTime.now();
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('maestria-relatorio');
      // Through a file, never through the command line: the material carries
      // commit subjects and prompts the user wrote, and neither is anything
      // to hand a shell to re-read as syntax.
      final file = File('${temp.path}/prompt.md');
      await file.writeAsString(promptFor(material));

      final process = await Process.start(
        Sh.shell,
        ['-lc', 'claude -p --output-format text < ${Sh.q(file.path)}'],
        workingDirectory: _home,
      );
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      // Drained as they come: a pipe nobody reads fills up and stalls the
      // child long before it has anything to say.
      final drained = Future.wait([
        process.stdout.transform(utf8.decoder).forEach(stdout.write),
        process.stderr.transform(utf8.decoder).forEach(stderr.write),
      ]);

      var timedOut = false;
      final code = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await drained.catchError((_) => <void>[]);

      if (timedOut) {
        return ReportOutcome.failed(
          'o claude passou de ${timeout.inMinutes} minutos e foi encerrado.',
          material,
          at,
        );
      }
      final text = stdout.toString().trim();
      if (code != 0 || text.isEmpty) {
        final why = stderr.toString().trim();
        return ReportOutcome.failed(
          why.isEmpty ? 'o claude saiu com $code e não escreveu nada.' : why,
          material,
          at,
        );
      }
      return ReportOutcome(ok: true, text: text, material: material, at: at);
    } on ProcessException catch (e) {
      return ReportOutcome.failed(e.message, material, at);
    } finally {
      try {
        await temp?.delete(recursive: true);
      } catch (_) {
        // A temp file we could not clear is the OS's problem, not the user's.
      }
    }
  }

  // --- formatting ---------------------------------------------------------

  static const _weekdays = [
    'segunda-feira',
    'terça-feira',
    'quarta-feira',
    'quinta-feira',
    'sexta-feira',
    'sábado',
    'domingo',
  ];

  static const _months = [
    'janeiro',
    'fevereiro',
    'março',
    'abril',
    'maio',
    'junho',
    'julho',
    'agosto',
    'setembro',
    'outubro',
    'novembro',
    'dezembro',
  ];

  static String _longDate(DateTime d) =>
      '${_weekdays[d.weekday - 1]}, ${d.day} de ${_months[d.month - 1]} de ${d.year}';

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// A field that may be a paragraph, put back on one line and cut. The
  /// material is a list; a wall of text inside a bullet stops being one.
  static String _oneLine(String value, int max) {
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }
}

/// The report, or why there isn't one.
class ReportOutcome {
  const ReportOutcome({
    required this.ok,
    required this.text,
    required this.material,
    required this.at,
  });

  factory ReportOutcome.failed(String why, String material, DateTime at) =>
      ReportOutcome(ok: false, text: why, material: material, at: at);

  final bool ok;

  /// The report when [ok]; the reason it could not be written otherwise.
  final String text;

  /// What it was written from. Kept so the dialog can show its own homework.
  final String material;
  final DateTime at;
}
