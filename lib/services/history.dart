/// As conversas que o Claude Code já teve, lidas de onde ele mesmo as guarda.
///
/// A fonte é o transcript: `~/.claude/projects/<pasta-escapada>/<id>.jsonl`,
/// uma linha de json por evento. E é a única fonte possível -- o
/// `claude agents --json`, que o cockpit já lê (ver `agents.dart`), lista os
/// processos *vivos*: a conversa de anteontem, que é justamente a que se quer
/// no histórico, não aparece lá.
///
/// Ler o transcript inteiro está fora de questão: são centenas de arquivos e
/// os grandes passam de dez megabytes. Então o que se lê é o começo de cada um
/// -- ver [ChatHistory.headBytes] --, e só dos que vão aparecer na lista.
library;

import 'dart:convert';
import 'dart:io';

/// Uma conversa do histórico: o bastante pra reconhecê-la numa linha e pra
/// retomá-la num painel.
class ChatEntry {
  ChatEntry({
    required this.sessionId,
    required this.cwd,
    required this.title,
    required this.at,
    required this.bytes,
    this.missing = false,
  });

  /// O id que o `--resume` leva.
  ///
  /// Vem do nome do arquivo e não de um campo lido de dentro dele: o nome está
  /// ali antes de qualquer leitura, e uma conversa cujo começo não abrir --
  /// json estragado, utf-8 partido no meio -- continua sendo uma conversa que
  /// dá pra retomar.
  final String sessionId;

  /// A pasta em que a conversa rodou, e em que o painel que a retomar tem que
  /// subir: uma conversa retomada noutro lugar fala de arquivos que não estão
  /// lá. Vazia quando o começo do transcript não disse qual era.
  final String cwd;

  /// Como a conversa se chama numa linha. Ver [ChatHistory.read].
  final String title;

  /// A última vez que alguém falou nela: o mtime do transcript, que é uma
  /// chamada ao sistema em vez da última linha de um arquivo de megabytes.
  final DateTime at;

  /// O tamanho do transcript. É o que se tem de "quão longa foi essa" sem
  /// abrir o arquivo -- contar turnos custaria ler a conversa toda.
  final int bytes;

  /// A pasta de [cwd] não está mais no disco. Retomar ali é retomar em cima
  /// de nada, então quem mostra a linha diz isso antes de alguém clicar.
  final bool missing;

  /// O nome curto da pasta, que é como a lateral chama um repo.
  String get where => cwd.isEmpty ? '?' : cwd.split('/').last;

  /// O apelido do painel que retomar esta conversa.
  ///
  /// Cortado curto porque vira o `--name` da sessão e o título da linha na
  /// lateral, que tem 200 e poucos pixels -- e porque um título de sessenta
  /// caracteres não fica mais reconhecível nos últimos trinta.
  String get label => title.length <= 32 ? title : '${title.substring(0, 32)}…';

  /// Quando foi, do jeito que se diz numa linha. Depois de uma semana a data
  /// diz mais que a contagem: "há 23 dias" é uma conta que ninguém faz.
  String get ago {
    final since = DateTime.now().difference(at);
    if (since.inMinutes < 1) return 'agora';
    if (since.inMinutes < 60) return 'há ${since.inMinutes} min';
    if (since.inHours < 24) return 'há ${since.inHours} h';
    if (since.inDays == 1) return 'ontem';
    if (since.inDays < 7) return 'há ${since.inDays} dias';
    return '${at.day}/${at.month}';
  }

  /// O tamanho do transcript em uma palavra.
  String get size {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} kB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Em que pé está uma conversa do histórico, daqui de dentro.
///
/// Existe porque a linha do histórico e o clique nela precisam da *mesma*
/// resposta: a linha diz o que vai acontecer, e o clique faz aquilo. Quem
/// responde é `AppStore.standingOf`, que é quem conhece os painéis abertos e
/// as sessões vivas.
enum ChatStanding {
  /// Dá pra retomar. Nada a dizer na linha.
  fresh,

  /// Já está num painel daqui: o clique vai até ele em vez de abrir um segundo
  /// painel na mesma conversa.
  onScreen,

  /// Viva fora do maestria.
  ///
  /// O CLI recusa o `--resume` de uma sessão que ainda está rodando -- ela
  /// `is running as a background session`, e a saída que ele oferece é um
  /// `claude attach` com um job id que o cockpit não tem de onde tirar. Então
  /// a linha avisa em vez de abrir um painel que morre na largada.
  live,

  /// A pasta em que ela rodou não está mais no disco. Ver [ChatEntry.missing].
  gone;

  /// O que a linha diz depois da pasta e da hora, quando há o que dizer.
  String? get note => switch (this) {
    ChatStanding.fresh => null,
    ChatStanding.onScreen => 'já está num painel',
    ChatStanding.live => 'aberta fora daqui',
    ChatStanding.gone => 'a pasta não existe mais',
  };

  /// Se retomar vai dar em painel novo. As outras três não abrem nada: uma vai
  /// pro painel que já existe, e duas só têm um aviso pra dar.
  bool get opens => this == ChatStanding.fresh;
}

/// A leitura do histórico. Ver a nota da biblioteca.
class ChatHistory {
  /// Onde o Claude Code arquiva os transcripts.
  static String get home => '${Platform.environment['HOME'] ?? ''}/.claude/projects';

  /// Quanto do começo de cada transcript a lista lê.
  ///
  /// Medido no acervo desta máquina, e não escolhido no ar: o `ai-title` --
  /// o título que o próprio CLI dá à conversa, e o melhor nome que ela tem --
  /// é escrito depois da primeira fala do usuário, que vem com o
  /// `<system-reminder>` e os anexos dela. Com 16 kB ele aparecia em 2 de 215
  /// arquivos; com 32 kB, em 85. Dobrar de novo achava dois a mais.
  static const headBytes = 32 * 1024;

  /// Quantas conversas a lista mostra.
  ///
  /// É o teto do custo: só destas o começo é lido. Quarenta é mais do que se
  /// percorre com o olho e ainda assim menos de dois megabytes de leitura.
  static const limitDefault = 40;

  /// Quantos caracteres de título uma linha aguenta.
  static const _maxTitle = 72;

  /// O nome da pasta em que o Claude Code arquiva as conversas de [cwd]: o
  /// caminho com tudo que não é letra nem número virando `-`.
  ///
  /// Confere em 210 dos 213 transcripts desta máquina; os três de fora são de
  /// worktree, e neles é o *arquivo* que está na pasta do repo principal. Não
  /// dá pra desfazer -- `/a/b`, `/a_b` e `/a-b` escapam pro mesmo nome --, e é
  /// por isso que quem pergunta pelas conversas de uma pasta recebe de volta o
  /// caminho que perguntou, não um caminho reconstruído daqui.
  static String dirFor(String cwd) => cwd.replaceAll(RegExp('[^A-Za-z0-9]'), '-');

  /// As conversas, da mais recente pra mais antiga.
  ///
  /// Com [cwds], só as das pastas pedidas -- é o histórico "deste repo", que é
  /// como a lateral pensa. Sem, o de todas as pastas: é a resposta pra quem
  /// procura uma conversa e não sabe mais onde ela rodou.
  ///
  /// [root] existe pros testes: em uso é sempre [home].
  static Future<List<ChatEntry>> read({
    String? root,
    List<String>? cwds,
    int limit = limitDefault,
  }) async {
    final base = Directory(root ?? home);
    // A pasta e, quando ela veio de uma pergunta, o caminho que a originou:
    // esse é o cwd que vale, porque [dirFor] não tem volta.
    final places = <({Directory dir, String? cwd})>[];
    if (cwds == null) {
      if (!await base.exists()) return const [];
      await for (final entry in base.list()) {
        if (entry is Directory) places.add((dir: entry, cwd: null));
      }
    } else {
      for (final cwd in cwds) {
        if (cwd.isEmpty) continue;
        places.add((dir: Directory('${base.path}/${dirFor(cwd)}'), cwd: cwd));
      }
    }

    // Um stat por candidato, que é o que ordenar por "quando" custa. O começo
    // dos arquivos fica pra depois do corte -- ver [limit].
    final found = <({File file, String? cwd, FileStat stat})>[];
    final seen = <String>{};
    for (final place in places) {
      // Dois caminhos diferentes podem escapar pro mesmo nome de pasta, e a
      // conversa não pode aparecer duas vezes por causa disso.
      if (!seen.add(place.dir.path) || !await place.dir.exists()) continue;
      await for (final entry in place.dir.list()) {
        // Só o que está na pasta, direto: os transcripts dos subagentes ficam
        // em `<id>/subagents/`, e nenhum deles é uma conversa que se retoma.
        if (entry is! File || !entry.path.endsWith('.jsonl')) continue;
        found.add((file: entry, cwd: place.cwd, stat: await entry.stat()));
      }
    }
    found.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));

    final chats = <ChatEntry>[];
    for (final one in found.take(limit)) {
      chats.add(await _entryOf(one.file, one.stat, one.cwd));
    }
    return chats;
  }

  static Future<ChatEntry> _entryOf(File file, FileStat stat, String? asked) async {
    final name = file.path.split('/').last;
    final id = name.substring(0, name.length - '.jsonl'.length);

    var head = '';
    try {
      // Um pedaço, não o arquivo: `openRead` com fim é um read de 32 kB, e
      // `allowMalformed` é por causa do último caractere, que o corte pode ter
      // partido no meio.
      head = await const Utf8Decoder(
        allowMalformed: true,
      ).bind(file.openRead(0, headBytes)).join();
    } catch (_) {
      // Transcript ilegível ainda é uma conversa retomável: ela só fica sem
      // nome. Ver [ChatEntry.sessionId].
    }

    String? titled;
    String? named;
    String? spoke;
    String? inside;
    for (final line in head.split('\n')) {
      if (!line.startsWith('{')) continue;
      Object? event;
      try {
        event = jsonDecode(line);
      } catch (_) {
        // A última linha do pedaço vem cortada, e cortada não é json.
        continue;
      }
      if (event is! Map) continue;
      if (event['cwd'] case final String at when at.isNotEmpty) inside ??= at;
      switch (event['type']) {
        case 'ai-title':
          titled ??= event['aiTitle'] as String?;
        // O `custom-title` e o `agent-name` são o `--name` com que a sessão
        // subiu, e o cockpit passa o nome da pasta em todas as que abre (ver
        // `AppStore.openClaude`): num acervo de 215, 81 dos 82 `custom-title`
        // eram iguais ao `agent-name` do mesmo arquivo. Por isso é o pior dos
        // três nomes, e não o primeiro: "maestria_v2" em vinte linhas
        // seguidas não distingue conversa nenhuma.
        case 'custom-title':
          named ??= event['customTitle'] as String?;
        case 'agent-name':
          named ??= event['agentName'] as String?;
        case 'user':
          spoke ??= _saidIn(event);
      }
    }

    final cwd = asked ?? inside ?? '';
    return ChatEntry(
      sessionId: id,
      cwd: cwd,
      title: _clean(titled) ?? _clean(spoke) ?? _clean(named) ?? id.split('-').first,
      at: stat.modified,
      bytes: stat.size,
      missing: cwd.isEmpty || !await Directory(cwd).exists(),
    );
  }

  /// O que a pessoa escreveu numa linha de `user`, se foi ela que escreveu.
  ///
  /// O conteúdo é texto cru numa fala digitada e uma lista de blocos quando
  /// vem imagem ou anexo com ela -- e a linha de um subagente (`isSidechain`)
  /// não é fala de ninguém.
  static String? _saidIn(Map<Object?, Object?> event) {
    if (event['isSidechain'] == true) return null;
    final message = event['message'];
    if (message is! Map) return null;
    final content = message['content'];
    if (content is String) return content;
    if (content is! List) return null;
    for (final block in content) {
      if (block is Map && block['type'] == 'text') return block['text'] as String?;
    }
    return null;
  }

  /// A primeira linha que sirva de nome.
  static String? _clean(String? text) {
    if (text == null) return null;
    final parts = <String>[];
    for (final line in text.split('\n')) {
      final bare = line.trim();
      final one = bare.replaceAll(RegExp(r'^#+\s*'), '');
      // `<ide_opened_file>`, `<system-reminder>`, `<command-name>`: o CLI
      // acrescenta contexto à fala do usuário, e nada disso é o que ele disse.
      if (one.isEmpty || one.startsWith('<')) continue;
      parts.add(one);
      // Um cabeçalho é a moldura da fala e não a fala: "## Tarefa", que é como
      // metade dos prompts longos daqui começa, não nomeia conversa nenhuma.
      // Então quando a linha era um cabeçalho, o que vem embaixo dele vem
      // junto -- e o teto do título corta o que sobrar.
      if (!bare.startsWith('#')) break;
    }
    final title = parts.join(' ');
    if (title.isEmpty) return null;
    return title.length <= _maxTitle ? title : '${title.substring(0, _maxTitle)}…';
  }
}
