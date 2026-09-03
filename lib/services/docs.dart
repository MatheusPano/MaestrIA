import 'dart:io';

/// De onde veio o markdown que um painel de leitura está mostrando.
///
/// Existe porque as quatro origens se comportam de forma diferente na hora de
/// reler: um arquivo é relido do disco e pode ter mudado no meio da leitura,
/// enquanto um plano é o que foi dito naquele instante e não muda mais.
enum DocSource {
  /// O plano que a sessão escreveu ao sair do modo plano — o `ExitPlanMode`,
  /// pego pelo hook. O motivo original do leitor existir.
  plan,

  /// Um `.md` no disco. O único que relê, porque é o único que pode mudar sem
  /// o app saber.
  file,

  /// O último recado de uma sessão: o `last_assistant_message` do `Stop`.
  /// Markdown desde sempre — só era desenhado como texto cru.
  message,

  /// O relatório do dia, escrito pelo `DailyReport`.
  report;

  /// Como a origem se apresenta no cabeçalho do painel.
  String get label => switch (this) {
    DocSource.plan => 'plano',
    DocSource.file => 'arquivo',
    DocSource.message => 'recado',
    DocSource.report => 'relatório',
  };

  /// Se o conteúdo vive no disco e portanto tem que ser relido. Os outros três
  /// são um instante que já passou: guardá-los é a única forma de tê-los.
  bool get onDisk => this == DocSource.file;
}

/// Um documento aberto num painel de leitura.
///
/// Mutável de propósito: um painel de leitura é um lugar, do mesmo jeito que um
/// painel de terminal é um lugar. Clicar em outro `.md` na tira de resultados
/// troca o que está sendo lido ali em vez de abrir um sexto painel — então o
/// que muda é o conteúdo deste objeto, não o objeto.
class MxDoc {
  MxDoc({
    required this.source,
    required this.title,
    required this.text,
    this.path,
    this.origin,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// Um `.md` do disco, ainda não lido. O conteúdo entra no primeiro
  /// [reload] — que é o que o painel faz ao ser montado.
  factory MxDoc.file(String path, {String? origin}) =>
      MxDoc(source: DocSource.file, title: path.split('/').last, text: '', path: path, origin: origin);

  DocSource source;

  /// O nome no cabeçalho do painel: o basename do arquivo, ou o que a origem
  /// dá de melhor ("plano de TASK#47730").
  String title;

  /// O markdown em si.
  String text;

  /// Só para [DocSource.file].
  String? path;

  /// O título do painel de onde isto saiu, quando saiu de um. Um plano fora da
  /// sessão que o escreveu é um plano de ninguém.
  String? origin;

  /// Quando este conteúdo passou a ser o conteúdo: a hora do hook, ou a última
  /// leitura do arquivo. O cabeçalho diz, porque um plano de três turnos atrás
  /// e o plano da vez são a mesma tela.
  DateTime at;

  /// Troca o que este painel mostra, mantendo o painel. Ver a nota da classe.
  void become(MxDoc other) {
    source = other.source;
    title = other.title;
    text = other.text;
    path = other.path;
    origin = other.origin;
    at = other.at;
  }

  bool get missing => source.onDisk && (path == null || !File(path!).existsSync());

  /// Relê do disco, e diz se o que está na tela mudou.
  ///
  /// Devolver `false` quando nada mudou é o que deixa o painel poder chamar
  /// isto de segundo em segundo: repintar markdown a cada tique seria perder a
  /// posição da rolagem de quem está lendo.
  Future<bool> reload() async {
    final at = path;
    if (!source.onDisk || at == null) return false;
    try {
      final file = File(at);
      if (!file.existsSync()) return false;
      final read = await file.readAsString();
      if (read == text) return false;
      text = read;
      this.at = file.lastModifiedSync();
      return true;
    } catch (_) {
      // Um arquivo que sumiu ou virou binário no meio da leitura não é motivo
      // pra derrubar o painel: [missing] e o texto que já está na tela dão
      // conta de dizer o que houve.
      return false;
    }
  }

  /// O que atravessa o config.
  ///
  /// O texto de um plano vai junto porque não há de onde relê-lo: o hook que o
  /// trouxe não acontece duas vezes. Um arquivo salva só o caminho — o disco é
  /// a fonte, e um texto guardado ao lado dele só teria como estar velho.
  Map<String, dynamic> toJson() => {
    'source': source.name,
    'title': title,
    if (path != null) 'path': path,
    if (origin != null) 'origin': origin,
    'at': at.toIso8601String(),
    if (!source.onDisk) 'text': _clip(text),
  };

  static MxDoc? fromJson(Map<String, dynamic> j) {
    final source = DocSource.values.asNameMap()[j['source'] as String? ?? ''];
    if (source == null) return null;
    final path = j['path'] as String?;
    // Um arquivo cujo caminho não voltou é um painel que abriria vazio e sem
    // nada pra recarregar.
    if (source.onDisk && (path == null || path.isEmpty)) return null;
    return MxDoc(
      source: source,
      title: (j['title'] as String?) ?? path?.split('/').last ?? source.label,
      text: (j['text'] as String?) ?? '',
      path: path,
      origin: j['origin'] as String?,
      at: DateTime.tryParse(j['at'] as String? ?? ''),
    );
  }

  /// Teto de propósito generoso e ainda assim um teto: o config é um arquivo
  /// que o app lê inteiro na abertura, e um recado de meio megabyte guardado
  /// nele custaria isso toda vez, pra sempre.
  static const _maxSaved = 128 * 1024;

  static String _clip(String text) =>
      text.length <= _maxSaved ? text : '${text.substring(0, _maxSaved)}\n\n…';
}

/// Se este caminho é markdown.
///
/// A pergunta aparece em três lugares que precisam da mesma resposta: a tira
/// de arquivos alterados decide entre o leitor e o Quick Look, a fita de
/// documentos decide se o arquivo merece uma ficha, e o redutor de hooks
/// decide se um `.md` escrito por linha de comando entra na lista.
bool isMarkdownPath(String path) {
  final name = path.split('/').last.toLowerCase();
  return name.endsWith('.md') || name.endsWith('.markdown') || name.endsWith('.mdx');
}
