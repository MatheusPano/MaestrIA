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

/// Uma conversa daquele dia que não está nesta janela.
///
/// De um dia que já passou não sobra painel nenhum — painéis morrem com a
/// janela —, e o que sobra é o transcript que o próprio Claude Code arquiva.
/// Quem os lê é `services/history.dart`; aqui eles chegam achatados, do mesmo
/// jeito que uma sessão.
class ArchivedChat {
  const ArchivedChat({
    required this.title,
    required this.folder,
    required this.at,
    this.size = '',
  });

  final String title;

  /// O nome curto da pasta em que ela rodou.
  final String folder;

  /// A última vez que alguém falou nela — não a hora em que começou: o que se
  /// tem sem abrir o arquivo é o mtime dele.
  final DateTime at;

  /// O tamanho do transcript numa palavra ("312 kB"), que é o único "quão
  /// longa foi essa conversa" que sai de um stat.
  final String size;
}

/// A commit from the reported day, as `git log` hands it over.
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

/// A day, gathered and then handed to Claude to be told back as prose.
///
/// The split is the whole design: everything factual — which commits, which
/// worktrees are dirty, which panels ran and what they wrote — is collected
/// here, deterministically, by the process that already knows it. Claude only
/// turns that material into the paragraph a person reads at 18h. Asking it to
/// go and *find* the day instead would be four minutes of tool calls and a
/// report that misses the sessions, because those live in this window and
/// nowhere else.
///
/// O dia é escolhido, e nem todo dia se conta do mesmo jeito. De hoje há tudo:
/// os painéis desta janela, com o que cada sessão pediu e mexeu, e o que está
/// sem commitar agora. De ontem — que é o dia que se fala na daily da manhã —
/// e de 25 de agosto há os commits daquele dia e as conversas arquivadas, e
/// mais nada: painéis não atravessam o dia e o `git status` só sabe do agora.
/// Ver [material], que diz isso no próprio material em vez de calar.
class DailyReport {
  /// Longer than a report ever takes, short enough that a hung CLI does not
  /// leave the dialog spinning until the app is quit.
  static const timeout = Duration(minutes: 4);

  /// Caps, so one absurd day cannot grow the prompt without bound.
  static const _maxCommits = 40;
  static const _maxDirtyFiles = 12;
  static const _maxTouched = 25;
  static const _maxChats = 25;

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
    required DateTime day,
    List<ArchivedChat> chats = const [],
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final today = sameDay(day, at);
    final out = StringBuffer()
      ..writeln(
        today
            ? '# material do dia — ${_longDate(day)}, ${_hhmm(at)}'
            : '# material de ${_longDate(day)}',
      )
      ..writeln();

    // Um dia que já passou vem com menos, e o relatório precisa saber disso
    // antes de escrever: senão ele lê a ausência da bancada como bancada
    // limpa, e afirma sobre aquela noite uma coisa que ninguém coletou.
    if (!today) {
      out
        ..writeln(
          'levantado em ${_longDate(at)}, às ${_hhmm(at)}. De um dia que já '
          'passou o que existe é isto: os commits daquele dia e as conversas '
          'arquivadas. O que estava sem commitar naquele dia não se sabe mais.',
        )
        ..writeln();
    }

    // Folders in parallel: each one is a handful of round trips through a
    // login shell, and they have nothing to say to each other.
    final gathered = await Future.wait([
      for (final f in folders)
        _folderSection(f, worktrees[f.root] ?? const [], day, today: today),
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
        // O projeto da bandeja não tem pasta pra citar -- e citar o último
        // pedaço da raiz dele diria "matheuspano", que não é lugar nenhum.
        final where = folders.any((f) => f.root == p.folderRoot)
            ? 'pasta ${p.folderRoot.split('/').last}'
            : 'avulsos';
        // A contagem de painéis é uma frase sobre agora. Num relatório de
        // outro dia ela seria sempre zero, e zero leria como "ninguém tocou
        // nesse projeto naquele dia" -- que não é o que o número sabe.
        out.writeln(today ? '- ${p.name} ($where) — $panels painel(éis)' : '- ${p.name} ($where)');
        final brief = p.brief.trim();
        if (brief.isNotEmpty) out.writeln('  briefing: ${_oneLine(brief, 300)}');
      }
      out.writeln();
    }

    out.writeln('## sessões');
    out.writeln();
    if (sessions.isEmpty) {
      out.writeln(
        today
            ? 'nenhuma sessão aberta hoje.'
            : 'nenhum painel desta janela é daquele dia — painéis não '
                  'atravessam o dia. O que rodou está nas conversas.',
      );
    } else {
      for (final s in sessions) {
        out.writeln(_session(s));
      }
    }
    out.writeln();

    if (chats.isNotEmpty) {
      out
        ..writeln('## conversas daquele dia')
        ..writeln()
        ..writeln(
          'do arquivo do próprio Claude Code, não desta janela. Dizem em que '
          'assunto o dia foi gasto; o que foi entregue está nos commits.',
        )
        ..writeln();
      for (final c in chats.take(_maxChats)) {
        out.writeln(_chat(c));
      }
      if (chats.length > _maxChats) {
        out.writeln('- … e mais ${chats.length - _maxChats}');
      }
      out.writeln();
    }
    return out.toString();
  }

  static Future<String> _folderSection(
    Folder f,
    List<WorktreeInfo> trees,
    DateTime day, {
    required bool today,
  }) async {
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
    final commits = await _commitsOn(f.root, email, day);
    final when = today ? 'de hoje' : 'de ${_dayMonth(day)}';
    out.writeln(
      email.isEmpty
          ? 'commits $when (autor não filtrado — o repo não tem user.email configurado):'
          : 'commits $when, de $email:',
    );
    if (commits.isEmpty) {
      out.writeln('- nenhum.');
    } else {
      for (final c in commits) {
        out.writeln('- ${c.time} · ${c.hash} · ${c.ref} · ${c.subject}');
      }
    }

    // A bancada é uma pergunta sobre agora: `git status` diz como a checkout
    // *está*, não como ela estava em 25 de agosto. Então num relatório de
    // outro dia ela não é coletada -- e o material diz isso, porque uma seção
    // ausente seria lida como uma bancada limpa.
    if (!today) {
      out
        ..writeln(
          'trabalho não commitado: não dá pra saber — o git só conhece o '
          'estado de agora.',
        )
        ..writeln();
      return out.toString();
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

  /// The day's commits across every ref of the repo, so a worktree's branch
  /// counts without having to be visited.
  ///
  /// A janela é fechada nos dois lados, e não um `--since=midnight`: um
  /// relatório de 25 de agosto pedido em setembro traria os dez dias que
  /// vieram depois. As duas pontas vão sem fuso, que é como o git as lê na
  /// hora local -- a mesma em que o dia foi escolhido no calendário.
  static Future<List<_Commit>> _commitsOn(String root, String email, DateTime day) async {
    final author = email.isEmpty ? '' : ' --author=${Sh.q(email)}';
    final r = await Sh.run(
      'git log --all --source --no-merges '
      '--since=${Sh.q('${_ymd(day)} 00:00:00')} '
      '--until=${Sh.q('${_ymd(day)} 23:59:59')}$author '
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

  static String _chat(ArchivedChat c) {
    final out = StringBuffer('- ${c.title} · pasta ${c.folder}');
    out.write(' · último movimento ${_hhmm(c.at)}');
    if (c.size.isNotEmpty) out.write(' · ${c.size}');
    return out.toString();
  }

  // --- the report ---------------------------------------------------------

  /// What Claude is asked to do with the material. Kept next to it, because
  /// the two are one prompt and drift apart the moment they are not.
  ///
  /// A forma pedida é a de uma daily falada: por frente de trabalho, um bullet
  /// por coisa feita, com uma linha embaixo dizendo como. Não é enfeite — é o
  /// uso. Este relatório é lido às 18h e repetido em voz alta às 9h do dia
  /// seguinte, e prosa corrida não se fala: quem tenta ler um parágrafo numa
  /// daily termina resumindo o parágrafo ali na hora.
  ///
  /// A explicação vai como sub-bullet indentado, e isso é uma restrição do
  /// leitor, não gosto: uma linha solta debaixo do bullet é a *mesma* linha em
  /// markdown -- uma quebra simples colapsa em espaço -- e sairia grudada no
  /// título dela em `ui/doc_pane.dart`.
  ///
  /// Que dia é muda três coisas no pedido, e nenhuma é decoração: a data (o
  /// modelo não tem de onde saber que 25/08 foi uma segunda), a ocasião em que
  /// isso vai ser lido, e o que o "em aberto" pode afirmar -- de um dia antigo
  /// não há bancada coletada pra chamar de pendência.
  static String promptFor(String material, {required DateTime day, DateTime? now}) {
    final at = now ?? DateTime.now();
    final today = sameDay(day, at);
    final yesterday = sameDay(day, _dayBefore(at));
    final which = today ? 'de hoje' : 'de ${_longDate(day)}';
    final sources = today
        ? 'commits, trabalho não commitado e as sessões que rodaram'
        : 'os commits daquele dia e as conversas arquivadas';
    final occasion = today
        ? 'Ele lê isso no fim do expediente e repete de manhã na daily'
        : yesterday
        ? 'Ele vai repetir isso na daily de hoje, em minutos'
        : 'Ele está olhando pra trás pra lembrar o que fez nesse dia';
    final loose = today
        ? 'o que ficou sem commit, as sessões paradas esperando resposta, e o '
              'próximo passo que o material sugere'
        : 'o que o material daquele dia deixa em aberto — conversa que parou '
              'no meio, entrega que os commits mostram pela metade. Nada de '
              'trabalho não commitado: isso não foi coletado';
    return '''
Você é o assistente do maestria, o cockpit onde este usuário toca as sessões de
Claude Code do dia dele. Abaixo vai o material bruto $which, coletado pelo
próprio app: $sources.

Escreva o relatório desse dia, em português do Brasil e em markdown.
$occasion — então escreva o que ele vai *falar*, na ordem em que ele falaria.

- comece com uma frase só, dizendo como foi o dia;
- depois uma seção `##` por frente de trabalho (o projeto quando houver, senão a
  pasta);
- dentro de cada seção, uma lista de bullets. Um bullet por coisa entregue, do
  jeito que se diz numa daily: uma linha, no passado, dizendo o que passou a
  funcionar (ou a parar de quebrar) — não o nome do arquivo que mudou;
- embaixo de cada bullet, indentado com dois espaços, um sub-bullet com a
  explicação curta: como foi feito, ou por que precisava ser feito. Uma linha,
  no máximo 25 palavras, e é aqui que entram nomes de arquivo, endpoint ou
  classe quando ajudarem;
- agrupe: commits que são a mesma entrega viram um bullet só, e no máximo seis
  bullets por frente. Nunca repita a lista de commits linha a linha;
- termine com uma seção `## em aberto`, na mesma forma: $loose;
- só o que está no material. Não invente tarefa, decisão nem resultado, e se o
  dia foi vazio diga isso em uma linha e pare;
- sem preâmbulo, sem "aqui está o relatório", sem fechamento genérico, sem
  perguntar se ele quer mais alguma coisa. No máximo 500 palavras.

A forma, exatamente:

## learning-app-lms
- Notificação de reação chegou no app.
  - Novo tipo `message_reaction` no serviço de notificações, com cinco testes
    cobrindo o texto de quem reagiu.
- Badge de não-lidas parou de teimar quando a conversa é lida em outra sessão.
  - O eco do próprio `markRead` apagava o badge; agora só zera quando a leitura
    cobre a última mensagem.

---

$material
''';
  }

  /// Run the report. One headless `claude -p`, nothing else on the machine.
  static Future<ReportOutcome> ask(String material, {required DateTime day, DateTime? now}) async {
    final at = now ?? DateTime.now();
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('maestria-relatorio');
      // Through a file, never through the command line: the material carries
      // commit subjects and prompts the user wrote, and neither is anything
      // to hand a shell to re-read as syntax.
      final file = File('${temp.path}/prompt.md');
      await file.writeAsString(promptFor(material, day: day, now: at));

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

  /// O mês por extenso: "setembro de 2025".
  ///
  /// Público porque o calendário que pergunta o dia (ver `ui/dialogs.dart`)
  /// escreve o mês com os mesmos nomes que o material — e doze strings
  /// copiadas pra outro arquivo divergem na primeira vez que alguém mexer.
  static String monthName(DateTime d) => '${_months[d.month - 1]} de ${d.year}';

  /// Se dois instantes caem no mesmo dia do calendário.
  ///
  /// Público porque a pergunta é a mesma em três lugares: aqui, no store que
  /// separa os painéis daquele dia, e no calendário que marca o hoje.
  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// O dia anterior a [d], pela aritmética do calendário e não por 24 horas:
  /// no domingo em que o horário de verão entra as duas contas divergem.
  static DateTime _dayBefore(DateTime d) => DateTime(d.year, d.month, d.day - 1);

  /// Como o dia se chama num título de painel e num aviso: "do dia" quando é
  /// hoje — que é como o relatório sempre se chamou —, "de ontem", ou a data.
  ///
  /// O ano só aparece quando não é este: "de 25/08" já é uma data, e o painel
  /// tem 200 e poucos pixels de cabeçalho.
  static String label(DateTime day, {DateTime? now}) {
    final at = now ?? DateTime.now();
    if (sameDay(day, at)) return 'do dia';
    if (sameDay(day, _dayBefore(at))) return 'de ontem';
    return day.year == at.year ? 'de ${_dayMonth(day)}' : 'de ${_dayMonth(day)}/${day.year}';
  }

  static String _dayMonth(DateTime d) => '${_two(d.day)}/${_two(d.month)}';

  /// A data como o git a aceita nas duas pontas de [_commitsOn].
  static String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _hhmm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

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
