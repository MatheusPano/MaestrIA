/// O `.code-workspace` do VS Code, lido como aquilo que ele é aqui.
library;

import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'paths.dart';

/// Uma linha da lista `folders` do arquivo.
class WorkspaceFolder {
  const WorkspaceFolder({required this.path, this.name});

  /// Já resolvido: absoluto, sem `.`, sem `..` e sem `~`. Ver
  /// [CodeWorkspace.resolve] -- no arquivo ele quase nunca está assim.
  final String path;

  /// O apelido que o workspace dá pra essa pasta, quando dá um. É o que o VS
  /// Code mostra no lugar do nome da pasta no disco, e é o nome que a pessoa
  /// escolheu -- então é melhor que `caminho.split('/').last` quando existe.
  final String? name;
}

/// Um workspace do VS Code: um nome e um punhado de pastas.
///
/// O arquivo tem mais coisa dentro -- `settings`, `extensions`, `launch`,
/// `tasks` --, e nada disso atravessa: são ajustes de um editor, e aqui não há
/// editor pra ajustar. O que sobra é justamente o que faltava ao maestria, que
/// é a lista de pastas que alguém já digitou uma vez em algum lugar.
///
/// Não vira entidade nenhuma na lateral. Um workspace aqui é um *jeito de
/// adicionar pastas* -- as pastas é que ficam --, e o caminho do arquivo fica
/// anotado em cada uma delas (ver [Folder.workspace]) pra uma coisa só: o
/// "abrir no vscode" de uma pasta importada devolver o arranjo inteiro em vez
/// de um terço dele.
class CodeWorkspace {
  const CodeWorkspace({required this.path, required this.name, required this.folders});

  /// O arquivo de onde isto saiu.
  final String path;

  /// Como ele se chama: o nome do arquivo sem a extensão, que é o mesmo que o
  /// VS Code põe na barra de título.
  final String name;

  /// Na ordem do arquivo, que é a ordem em que a pessoa arrumou as pastas.
  final List<WorkspaceFolder> folders;

  /// A extensão que o VS Code dá ao arquivo, e o único jeito de reconhecê-lo:
  /// por dentro ele é um json como qualquer outro. É por ela que o campo
  /// "adicionar pasta" sabe que recebeu um workspace e não uma pasta.
  static const ext = '.code-workspace';

  static bool looksLikeOne(String path) => path.trim().toLowerCase().endsWith(ext);

  /// Null pro arquivo que não está lá, que não é json ou que é um json que não
  /// é um objeto. Nulo e não exceção porque quem chama é o campo de adicionar
  /// pasta: um arquivo estragado vira uma tarja, não um crash.
  static Future<CodeWorkspace?> read(String rawPath) async {
    final path = expandHome(rawPath.trim());
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return parse(await file.readAsString(), path: path);
    } on FileSystemException {
      return null;
    }
  }

  static CodeWorkspace? parse(String source, {required String path}) {
    final Object? json;
    try {
      json = jsonDecode(stripJsonc(source));
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    final from = _dirOf(path);
    final folders = <WorkspaceFolder>[];
    for (final entry in (json['folders'] as List? ?? const [])) {
      if (entry is! Map) continue;
      final raw = ((entry['path'] as String?) ?? '').trim();
      if (raw.isEmpty) continue;
      final name = ((entry['name'] as String?) ?? '').trim();
      folders.add(
        WorkspaceFolder(path: resolve(raw, from: from), name: name.isEmpty ? null : name),
      );
    }
    return CodeWorkspace(path: path, name: _nameOf(path), folders: folders);
  }

  /// O caminho de uma pasta do workspace, como caminho de verdade.
  ///
  /// Relativo é o caso comum -- é assim que o VS Code escreve quando o arquivo
  /// mora perto dos repos --, e relativo **ao arquivo**, não a onde o app está
  /// rodando: um `../api` resolvido contra o cwd de uma .app aponta pra dentro
  /// do bundle.
  ///
  /// O `~` é uma licença nossa. O VS Code não o expande em `folders`, mas este
  /// arquivo é editado à mão com frequência, e um `~/repos/api` escrito ali é
  /// uma pasta que existe -- recusá-la seria acertar a especificação e errar a
  /// pessoa.
  static String resolve(String raw, {required String from}) {
    final expanded = expandHome(raw.trim());
    return _normalize(expanded.startsWith('/') ? expanded : '$from/$expanded');
  }

  /// O json com as duas liberdades que o VS Code toma nele e o [jsonDecode]
  /// não aceita: comentário e vírgula sobrando.
  ///
  /// Um workspace escrito à mão tem as duas coisas -- o VS Code as escreve
  /// sozinho ao gerar o arquivo --, e sem isto o import mais comum de todos
  /// (o arquivo que a pessoa vem editando há meses) responde "não consegui
  /// ler".
  ///
  /// Duas passadas, ambas cientes de string: uma vírgula dentro de `"a,}"` não
  /// é vírgula sobrando, e `"http://x"` não é um comentário.
  static String stripJsonc(String source) => _dropTrailingCommas(_dropComments(source));

  static String _dropComments(String source) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        i++;
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == '/' && i + 1 < source.length) {
        if (source[i + 1] == '/') {
          // Até a quebra de linha, que fica: ela separa os tokens de quem
          // escreveu o comentário no fim de uma linha de verdade.
          while (i < source.length && source[i] != '\n') {
            i++;
          }
          continue;
        }
        if (source[i + 1] == '*') {
          i += 2;
          while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/')) {
            i++;
          }
          i = i + 2 <= source.length ? i + 2 : source.length;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static String _dropTrailingCommas(String source) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      if (inString) {
        out.write(c);
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        continue;
      }
      if (c == ',') {
        var j = i + 1;
        while (j < source.length && _isSpace(source[j])) {
          j++;
        }
        if (j < source.length && (source[j] == '}' || source[j] == ']')) continue;
      }
      out.write(c);
    }
    return out.toString();
  }

  static bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

  static String _dirOf(String path) {
    final cut = path.lastIndexOf('/');
    if (cut < 0) return '.';
    return cut == 0 ? '/' : path.substring(0, cut);
  }

  /// O nome de um workspace a partir do caminho dele, sem precisar abrir o
  /// arquivo: é o que o VS Code põe na barra de título, e o que a seção da
  /// lateral mostra. Público porque uma pasta carimbada por uma build antiga
  /// nasce sem registro, e a store batiza a seção por aqui.
  static String nameOf(String path) => _nameOf(path);

  static String _nameOf(String path) {
    final base = path.split('/').last;
    final name = base.toLowerCase().endsWith(ext)
        ? base.substring(0, base.length - ext.length)
        : base;
    return name.isEmpty ? base : name;
  }

  /// `.` e `..` resolvidos aqui, e não pelo sistema de arquivos: o caminho vai
  /// virar a identidade de uma [Folder] no config, e `/a/b/../b` e `/a/b`
  /// seriam duas pastas pra mesma pasta.
  static String _normalize(String path) {
    final absolute = path.startsWith('/');
    final out = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (out.isNotEmpty && out.last != '..') {
          out.removeLast();
        } else if (!absolute) {
          // Num caminho relativo o `..` que sobe demais é informação; num
          // absoluto ele não é: acima de `/` não há nada.
          out.add('..');
        }
        continue;
      }
      out.add(segment);
    }
    final joined = out.join('/');
    if (absolute) return '/$joined';
    return joined.isEmpty ? '.' : joined;
  }
}

/// O que aconteceu ao importar um workspace, contado.
///
/// Existe por causa de uma pergunta que o import faz o tempo todo e não tinha
/// como responder: um workspace de monorepo lista `packages/api` e
/// `packages/web`, as duas resolvem pro mesmo checkout principal (ver
/// `Git.mainRoot`) e viram **uma** pasta só na lateral. Sem [already] isso é
/// um botão que engole uma das pastas em silêncio.
class WorkspaceImport {
  WorkspaceImport({
    required this.workspace,
    required this.added,
    required this.already,
    required this.missing,
  });

  final CodeWorkspace workspace;

  /// Pastas novas na lateral.
  final List<Folder> added;

  /// As que já estavam lá -- ou porque a pessoa já tinha adicionado, ou porque
  /// outra pasta do mesmo workspace resolveu pro mesmo repo.
  final List<Folder> already;

  /// Caminhos que o workspace lista e o disco não tem.
  final List<String> missing;

  /// Vale a pena deixar a tarja parada: alguma coisa do arquivo não entrou.
  bool get sticky => missing.isNotEmpty;

  String get summary {
    final one = added.length == 1;
    final parts = [
      if (added.isNotEmpty)
        '${added.length} ${one ? 'pasta adicionada' : 'pastas adicionadas'}',
      if (already.isNotEmpty)
        '${already.length} já ${already.length == 1 ? 'estava' : 'estavam'} aqui',
      if (missing.isNotEmpty)
        '${missing.length} não ${missing.length == 1 ? 'existe' : 'existem'} no disco',
    ];
    if (parts.isEmpty) return 'workspace "${workspace.name}": nada pra adicionar';
    return 'workspace "${workspace.name}": ${parts.join(', ')}';
  }
}
