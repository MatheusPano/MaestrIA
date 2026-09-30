/// Plugins: pastas instaladas à parte que acrescentam coisas à Maestria.
///
/// O desenho é o do VS Code com uma diferença que o Flutter impõe: um app
/// compilado AOT não carrega código Dart em tempo de execução, então nada de
/// plugin roda *dentro* do app. Um plugin é uma pasta com um manifesto
/// (`maestria-plugin.json`) e, quando precisa de lógica, um processo próprio
/// -- em qualquer linguagem -- que conversa com a janela por JSON-RPC 2.0, uma
/// mensagem por linha no stdin/stdout. É o mesmo arranjo do extension host do
/// VS Code, do LSP e do MCP por stdio.
///
/// O que não precisa de processo vem declarado no manifesto e o app faz
/// sozinho: temas, e comandos que rodam um shell ou mandam um texto pra
/// sessão. O guia de quem escreve plugin é `docs/plugins.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey, PhysicalKeyboardKey;

import '../theme.dart';
import 'paths.dart';
import 'shell.dart';
import 'shortcuts.dart';

/// A versão do contrato entre a janela e os plugins. Sobe quando algo que um
/// plugin já usa muda de forma incompatível; acrescentar método não sobe.
const int mxPluginApi = 1;

/// Até onde vão os blocos que esta janela desenha. Não é um contrato que
/// quebra -- bloco desconhecido vira "bloco desconhecido" --, é a deixa pra
/// um plugin que usa os novos (a lista do OrbStack, o terminal embutido)
/// avisar que o app precisa de atualização em vez de desenhar pela metade.
/// Um app sem o campo no `initialize` é o 1.
const int mxPluginBlocks = 2;

/// O nome do manifesto na raiz da pasta de um plugin.
const String mxManifestName = 'maestria-plugin.json';

/// O que um plugin pode pedir à janela além do básico.
///
/// Não é um sandbox: o processo de um plugin roda com as permissões de quem
/// abriu o app e pode fazer no disco o que você pode. O que isto controla é o
/// que a *janela* faz a pedido dele -- digitar num painel seu, abrir sessão,
/// entregar o que as suas sessões estão fazendo. Declarado no manifesto,
/// mostrado na instalação, e recusado quando não foi declarado.
enum PluginPermission {
  hooks(
    'hooks',
    'ver os eventos das sessões do claude — o que você pede, que ferramentas '
        'rodam e com quais argumentos',
  ),
  terminalWrite('terminal.write', 'digitar e enviar texto nos seus painéis'),
  sessionsCreate('sessions.create', 'abrir sessões do claude e terminais'),
  notifications('notifications', 'mandar notificações do sistema');

  const PluginPermission(this.id, this.label);

  /// Como o manifesto escreve.
  final String id;

  /// Como a tela de instalação explica.
  final String label;

  static PluginPermission? byId(String id) => values.firstWhereOrNull((p) => p.id == id);
}

/// Onde um comando acontece.
enum CommandTarget {
  /// No processo do plugin: vira um `command.invoke`.
  plugin,

  /// Um painel de terminal novo rodando o `run`.
  terminal,

  /// O `run` num shell sem painel; o resultado volta como recado.
  background,

  /// O `send` colado e enviado na sessão do claude em foco.
  session,
}

/// Um comando que um plugin oferece: uma linha no menu do painel, e uma tecla
/// quando o manifesto dá uma.
@immutable
class PluginCommand {
  const PluginCommand({
    required this.pluginId,
    required this.id,
    required this.title,
    required this.target,
    this.run,
    this.send,
    this.key,
    this.icon,
    this.sidebar = false,
  });

  final String pluginId;
  final String id;
  final String title;
  final CommandTarget target;

  /// O comando de shell, pra [CommandTarget.terminal] e [CommandTarget.background].
  final String? run;

  /// O texto, pra [CommandTarget.session].
  final String? send;

  /// A tecla. Null quando o manifesto não deu nenhuma -- ou deu uma que não
  /// vale, e aí o aviso está no log do plugin.
  final MxChord? key;

  /// O desenho do comando, pelo nome dos ícones de bloco (`report`, `bug`…).
  final String? icon;

  /// Se o comando ganha um botão no rodapé da lateral, ao lado do histórico.
  final bool sidebar;

  /// O endereço do comando fora do plugin: é o que o menu devolve e o que
  /// identifica a linha.
  String get fullId => '$pluginId/$id';
}

/// O tipo de uma configuração de plugin -- e o campo que a tela desenha.
enum PluginSettingType { string, number, boolean, color, select }

/// Uma configuração que o plugin declarou (`contributes.settings`).
///
/// É o `contributes.configuration` do VS Code: o plugin diz o que dá pra
/// configurar, e a Maestria desenha o formulário, guarda o valor no config e
/// avisa o plugin quando muda (`settings.changed`). Nenhum plugin precisa
/// escrever uma tela de preferências.
@immutable
class PluginSetting {
  const PluginSetting({
    required this.id,
    required this.title,
    required this.type,
    this.description = '',
    this.defaultValue,
    this.options = const [],
    this.group,
  });

  final String id;
  final String title;
  final PluginSettingType type;
  final String description;

  /// O valor quando você não mexeu. Null vira o vazio do tipo.
  final Object? defaultValue;

  /// As opções de um [PluginSettingType.select].
  final List<({String value, String label})> options;

  /// Um título de bloco: configurações seguidas com o mesmo grupo aparecem
  /// debaixo dele ("cores do console").
  final String? group;

  static PluginSetting parse(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('cada configuração precisa de "id"');
    }
    final type = PluginSettingType.values.asNameMap()[j['type'] ?? 'string'];
    if (type == null) {
      throw FormatException(
        'a configuração "$id" tem "type": "${j['type']}" — vale '
        '${PluginSettingType.values.map((t) => t.name).join(', ')}',
      );
    }
    final options = [
      for (final o in (j['options'] as List? ?? const []))
        switch (o) {
          final String v => (value: v, label: v),
          {'value': final String v} => (value: v, label: (o['label'] as String?) ?? v),
          _ => throw FormatException('a opção de "$id" é um texto ou {"value", "label"}'),
        },
    ];
    if (type == PluginSettingType.select && options.isEmpty) {
      throw FormatException('a configuração "$id" é select e não tem "options"');
    }
    return PluginSetting(
      id: id,
      title: (j['title'] as String?) ?? id,
      type: type,
      description: (j['description'] as String?) ?? '',
      defaultValue: j['default'],
      options: options,
      group: j['group'] as String?,
    );
  }

  /// O valor que vale: o guardado quando ele é do tipo certo, senão o padrão.
  Object? resolve(Object? saved) {
    bool fits(Object? v) => switch (type) {
      PluginSettingType.string || PluginSettingType.color => v is String,
      PluginSettingType.number => v is num,
      PluginSettingType.boolean => v is bool,
      PluginSettingType.select => v is String && options.any((o) => o.value == v),
    };
    if (fits(saved)) return saved;
    if (fits(defaultValue)) return defaultValue;
    return switch (type) {
      PluginSettingType.boolean => false,
      PluginSettingType.number => 0,
      PluginSettingType.select => options.first.value,
      _ => '',
    };
  }
}

/// O `maestria-plugin.json`, lido e conferido.
@immutable
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.main,
    this.activation = const {},
    this.permissions = const {},
    this.commands = const [],
    this.themes = const [],
    this.api = mxPluginApi,
    this.warnings = const [],
    this.icon,
    this.settings = const [],
    this.sidebar = false,
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;

  /// O processo do plugin: o executável e os argumentos, rodados na pasta
  /// dele. Null num plugin só de declarações.
  final List<String>? main;

  /// Quando o processo sobe. Ver [activatesOn].
  final Set<String> activation;
  final Set<PluginPermission> permissions;
  final List<PluginCommand> commands;

  /// Os arquivos de tema, relativos à pasta do plugin.
  final List<String> themes;

  /// A versão do contrato que o plugin espera. Ver [mxPluginApi].
  final int api;

  /// O desenho do plugin: um nome de ícone de bloco, ou um `.svg` da pasta
  /// dele. É o que as janelas dele mostram no cabeçalho e na lateral.
  final String? icon;

  /// O que dá pra configurar neste plugin. Ver [PluginSetting].
  final List<PluginSetting> settings;

  /// Se o plugin desenha a própria aba na lateral (`contributes.sidebar`).
  ///
  /// Com ela, a aba do plugin na faixa é o que ele mandar por
  /// `sidebar.update`, com os blocos das janelas; sem ela, a Maestria monta
  /// uma aba genérica com as janelas abertas e a lista de comandos.
  final bool sidebar;

  /// O que o manifesto tinha de estranho sem ser motivo de recusa -- uma tecla
  /// que não vale, um campo que esta versão não conhece.
  final List<String> warnings;

  bool get hasProcess => main != null && main!.isNotEmpty;

  /// Se o processo deve subir quando [event] acontece.
  ///
  /// `*` e `onStartup` sobem com o app. Um plugin com processo e sem nenhum
  /// evento declarado sobe com o app também: exigir a lista de quem só quer
  /// estar de pé seria mais uma coisa pra errar no primeiro plugin.
  bool activatesOn(String event) {
    if (!hasProcess) return false;
    if (activation.isEmpty) return event == 'onStartup';
    if (activation.contains('*')) return true;
    return activation.contains(event);
  }

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]*$');
  static final _commandPattern = RegExp(r'^[A-Za-z0-9._-]+$');

  /// Lê o manifesto, ou diz o que está errado nele num [FormatException].
  ///
  /// Estrito no que faria o plugin se comportar diferente do que o autor
  /// quis -- permissão desconhecida, comando sem ação -- e tolerante no resto,
  /// que vira [warnings].
  static PluginManifest parse(Map<String, dynamic> j) {
    final warnings = <String>[];
    String need(String key) {
      final v = j[key];
      if (v is! String || v.trim().isEmpty) throw FormatException('"$key" é obrigatório');
      return v.trim();
    }

    final id = need('id');
    if (!_idPattern.hasMatch(id)) {
      throw FormatException(
        '"id" só pode ter minúsculas, dígitos, ponto, hífen e sublinhado: "$id"',
      );
    }
    final api = (j['maestria'] as num?)?.toInt() ?? mxPluginApi;
    if (api > mxPluginApi) {
      throw FormatException(
        'o plugin pede a versão $api da API e esta maestria só conhece até a $mxPluginApi',
      );
    }

    List<String>? main;
    switch (j['main']) {
      case null:
        break;
      case final String cmd when cmd.trim().isNotEmpty:
        main = [cmd.trim()];
      case final List<dynamic> list when list.isNotEmpty && list.every((e) => e is String):
        main = list.cast<String>();
      default:
        throw const FormatException('"main" é uma lista: ["node", "main.js"]');
    }

    final permissions = <PluginPermission>{};
    for (final p in (j['permissions'] as List? ?? const [])) {
      final perm = p is String ? PluginPermission.byId(p) : null;
      if (perm == null) {
        throw FormatException(
          'permissão desconhecida: "$p" — as que existem são '
          '${PluginPermission.values.map((p) => p.id).join(', ')}',
        );
      }
      permissions.add(perm);
    }

    final activation = <String>{
      for (final e in (j['activationEvents'] as List? ?? const []))
        if (e is String) e,
    };

    final contributes = (j['contributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final commands = <PluginCommand>[];
    for (final raw in (contributes['commands'] as List? ?? const [])) {
      if (raw is! Map) throw const FormatException('cada comando é um objeto');
      final c = raw.cast<String, dynamic>();
      final cid = c['id'];
      final title = c['title'];
      if (cid is! String || !_commandPattern.hasMatch(cid)) {
        throw FormatException('comando com "id" inválido: ${jsonEncode(cid)}');
      }
      if (title is! String || title.trim().isEmpty) {
        throw FormatException('o comando "$cid" precisa de "title"');
      }
      if (commands.any((o) => o.id == cid)) throw FormatException('comando repetido: "$cid"');
      final run = c['run'] is String ? (c['run'] as String) : null;
      final send = c['send'] is String ? (c['send'] as String) : null;
      if (run != null && send != null) {
        throw FormatException('o comando "$cid" tem "run" e "send" — escolha um');
      }
      final CommandTarget target;
      if (send != null) {
        target = CommandTarget.session;
      } else if (run != null) {
        target = switch (c['in']) {
          null || 'terminal' => CommandTarget.terminal,
          'background' => CommandTarget.background,
          final other => throw FormatException(
            'o comando "$cid" tem "in": "$other" — vale "terminal" ou "background"',
          ),
        };
      } else {
        if (main == null) {
          throw FormatException(
            'o comando "$cid" não tem "run" nem "send", e o plugin não tem "main" pra atendê-lo',
          );
        }
        target = CommandTarget.plugin;
      }
      MxChord? key;
      if (c['key'] case final String k) {
        // O manifesto escreve `meta` pensando no ⌘; no Linux isso é Ctrl+Shift.
        final chord = MxChord.parse(k)?.forHost;
        if (chord == null) {
          warnings.add('o comando "$cid" pede a tecla "$k", que não dá pra ler — ficou sem');
        } else if (chord.rejection case final why?) {
          warnings.add('o comando "$cid" pede ${chord.label}: $why — ficou sem');
        } else {
          key = chord;
        }
      }
      commands.add(
        PluginCommand(
          pluginId: id,
          id: cid,
          title: title.trim(),
          target: target,
          run: run,
          send: send,
          key: key,
          icon: c['icon'] is String ? c['icon'] as String : null,
          sidebar: c['sidebar'] == true,
        ),
      );
    }

    final themes = <String>[];
    for (final t in (contributes['themes'] as List? ?? const [])) {
      final path = switch (t) {
        final String p => p,
        {'path': final String p} => p,
        _ => null,
      };
      if (path == null) throw const FormatException('cada tema é {"path": "themes/x.json"}');
      themes.add(path);
    }

    final settings = <PluginSetting>[];
    for (final raw in (contributes['settings'] as List? ?? const [])) {
      if (raw is! Map) throw const FormatException('cada configuração é um objeto');
      final setting = PluginSetting.parse(raw.cast<String, dynamic>());
      if (settings.any((o) => o.id == setting.id)) {
        throw FormatException('configuração repetida: "${setting.id}"');
      }
      settings.add(setting);
    }

    final sidebar = contributes['sidebar'];
    if (sidebar != null && sidebar is! bool) {
      throw const FormatException('"contributes.sidebar" é true ou false');
    }
    if (sidebar == true && main == null) {
      throw const FormatException('"contributes.sidebar" precisa de "main" pra desenhar a aba');
    }

    const known = {'commands', 'themes', 'settings', 'sidebar'};
    for (final k in contributes.keys) {
      if (!known.contains(k)) warnings.add('"contributes.$k" não existe nesta versão — ignorado');
    }

    return PluginManifest(
      id: id,
      name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : id,
      version: need('version'),
      description: (j['description'] as String?) ?? '',
      author: switch (j['author']) {
        final String a => a,
        {'name': final String a} => a,
        _ => '',
      },
      main: main,
      activation: activation,
      permissions: permissions,
      commands: commands,
      themes: themes,
      icon: j['icon'] is String ? j['icon'] as String : null,
      settings: settings,
      api: api,
      warnings: warnings,
      sidebar: sidebar == true,
    );
  }

  /// O manifesto na pasta [dir], ou o [FormatException] que diz por que não.
  static PluginManifest read(String dir) {
    final file = File('$dir/$mxManifestName');
    if (!file.existsSync()) throw const FormatException('não tem $mxManifestName');
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw FormatException('$mxManifestName não é um json válido: ${e.message}');
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('$mxManifestName precisa ser um objeto');
    }
    return parse(json);
  }
}

/// Em que pé está um plugin.
enum PluginState {
  /// O manifesto não leu. Ver [MxPlugin.problem].
  invalid('com problema'),
  disabled('desligado'),

  /// Instalado e ligado, sem processo de pé -- porque não tem, ou porque
  /// nenhum evento dele aconteceu ainda.
  idle('pronto'),
  starting('subindo'),
  running('rodando'),

  /// O processo saiu sem ser mandado. Ver [MxPlugin.crash].
  crashed('parou');

  const PluginState(this.label);
  final String label;
}

/// Um plugin instalado.
class MxPlugin {
  MxPlugin({required this.dir, this.manifest, this.problem, this.linked = false});

  /// A pasta dele em `~/.maestria/plugins` -- ou o link pra pasta de
  /// desenvolvimento, quando [linked].
  final String dir;

  /// Mutável porque o objeto sobrevive a uma releitura da pasta (ver
  /// [Plugins.scan]): o processo de pé está pendurado nele, e um manifesto
  /// editado não é motivo pra perder o fio.
  PluginManifest? manifest;

  /// Por que o manifesto não leu. Não-null exatamente quando [manifest] é null.
  String? problem;

  /// Carregado de uma pasta de desenvolvimento por link simbólico: remover
  /// apaga o link, nunca a pasta de quem está escrevendo o plugin.
  final bool linked;

  bool enabled = true;

  /// A última razão de o processo ter caído, quando caiu.
  String? crash;

  /// Os temas que ele entregou e que leram. Os que não leram estão no [log].
  final List<MxPalette> palettes = [];

  /// O que o processo escreveu no stderr, o que ele mandou pelo `log`, e o que
  /// a janela tem a dizer sobre ele. Um teto, porque um plugin tagarela não
  /// pode crescer a memória do app pra sempre.
  final List<String> log = [];
  static const _maxLog = 400;

  PluginConnection? _conn;
  Future<PluginConnection?>? _starting;

  String get id => manifest?.id ?? dir.split('/').last;
  String get name => manifest?.name ?? id;

  PluginState get state {
    if (manifest == null) return PluginState.invalid;
    if (!enabled) return PluginState.disabled;
    if (_conn?.ready == true) return PluginState.running;
    if (_starting != null) return PluginState.starting;
    if (crash != null) return PluginState.crashed;
    return PluginState.idle;
  }

  bool get active => manifest != null && enabled;

  bool allows(PluginPermission p) => manifest?.permissions.contains(p) ?? false;

  /// A pasta onde o plugin guarda o que é dele. Fora da pasta do plugin de
  /// propósito: atualizar um plugin troca a pasta inteira, e o que ele
  /// guardou não pode ir junto.
  String get dataDir => '$mxStateDir/plugin-data/$id';

  void note(String line) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    log.add('${two(now.hour)}:${two(now.minute)}:${two(now.second)}  $line');
    if (log.length > _maxLog) log.removeRange(0, log.length - _maxLog);
  }
}

/// Um erro de JSON-RPC: o que volta pro plugin quando o pedido dele falha, e
/// o que sobe pra janela quando o pedido dela falha.
class PluginRpcError implements Exception {
  const PluginRpcError(this.code, this.message);

  final int code;
  final String message;

  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internal = -32603;

  /// Código próprio: a permissão não foi declarada no manifesto.
  static const forbidden = -32001;

  /// Código próprio: o plugin não está de pé pra responder.
  static const unavailable = -32002;

  @override
  String toString() => message;
}

/// A linha com o processo de um plugin: JSON-RPC 2.0, uma mensagem por linha.
///
/// Por linha e não com cabeçalho `Content-Length` como o LSP: é o que o MCP
/// por stdio faz, e é o que dá pra escrever num `print` em qualquer linguagem.
/// O json de uma mensagem não pode ter quebra de linha crua -- e nenhum
/// `JSON.stringify`/`json.dumps` sem indentação põe uma.
class PluginConnection {
  PluginConnection(
    this._process, {
    required this.onRequest,
    required this.onNotify,
    required this.onLog,
    required this.onExit,
  }) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onDone: () => _closed.complete());
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => onLog('stderr: $l'));
    _process.exitCode.then((code) {
      _exit = code;
      ready = false;
      for (final c in _pending.values) {
        c.completeError(const PluginRpcError(PluginRpcError.unavailable, 'o plugin saiu'));
      }
      _pending.clear();
      onExit(code);
    });
    // Escrever num stdin de processo morto é um erro assíncrono que ninguém
    // estaria esperando: engolido aqui, e a saída do processo conta a história.
    _process.stdin.done.catchError((_) {});
  }

  final Process _process;
  final Future<Object?> Function(String method, Map<String, dynamic> params) onRequest;
  final void Function(String method, Map<String, dynamic> params) onNotify;
  final void Function(String line) onLog;
  final void Function(int code) onExit;

  /// Se o `initialize` já voltou. Antes disso os eventos esperam em
  /// [PluginConnection] -- ver [Plugins._deliver].
  bool ready = false;
  int? _exit;
  final Completer<void> _closed = Completer<void>();
  int _next = 1;
  final Map<int, Completer<Object?>> _pending = {};

  bool get alive => _exit == null;
  int get pid => _process.pid;

  Future<Object?> request(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  ]) {
    if (!alive) {
      return Future.error(
        const PluginRpcError(PluginRpcError.unavailable, 'o plugin não está rodando'),
      );
    }
    final id = _next++;
    final done = Completer<Object?>();
    _pending[id] = done;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params});
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw PluginRpcError(
          PluginRpcError.unavailable,
          '"$method" ficou sem resposta por ${timeout.inSeconds}s',
        );
      },
    );
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    if (!alive) return;
    _send({'jsonrpc': '2.0', 'method': method, 'params': ?params});
  }

  void _send(Map<String, dynamic> message) {
    try {
      _process.stdin.writeln(jsonEncode(message));
    } catch (_) {
      // O processo foi embora entre o `alive` e a escrita: o `exitCode`
      // acima é quem avisa.
    }
  }

  Future<void> _line(String line) async {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      // Um `print` de depuração no stdout: vai pro log em vez de derrubar a
      // conversa. Ele quebraria o protocolo num cliente mais estrito.
      onLog('stdout: $line');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      onLog('stdout: $line');
      return;
    }
    final msg = decoded;
    final method = msg['method'];
    final id = msg['id'];
    final params = (msg['params'] is Map)
        ? (msg['params'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    if (method is String) {
      if (id == null) {
        onNotify(method, params);
        return;
      }
      try {
        final result = await onRequest(method, params);
        _send({'jsonrpc': '2.0', 'id': id, 'result': result});
      } on PluginRpcError catch (e) {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': e.code, 'message': e.message},
        });
      } catch (e) {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': PluginRpcError.internal, 'message': '$e'},
        });
      }
      return;
    }
    // Uma resposta a um pedido da janela.
    if (id is! int) return;
    final waiting = _pending.remove(id);
    if (waiting == null) return;
    if (msg['error'] case final Map<dynamic, dynamic> err) {
      waiting.completeError(
        PluginRpcError(
          (err['code'] as num?)?.toInt() ?? PluginRpcError.internal,
          (err['message'] as String?) ?? 'erro sem mensagem',
        ),
      );
    } else {
      waiting.complete(msg['result']);
    }
  }

  /// Pede pra sair e, se ele não sair, derruba.
  ///
  /// O `shutdown` é uma notificação e não um pedido: um plugin que não o
  /// conhece não precisa responder nada -- fechar o stdin já é o recado que
  /// qualquer loop de leitura entende.
  Future<void> close({Duration grace = const Duration(milliseconds: 800)}) async {
    if (!alive) return;
    notify('shutdown');
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(grace);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigterm);
      try {
        await _process.exitCode.timeout(grace);
      } on TimeoutException {
        _process.kill(ProcessSignal.sigkill);
      }
    }
  }

  void kill() {
    if (alive) _process.kill(ProcessSignal.sigkill);
  }
}

/// Um plugin baixado e lido, esperando o "instalar" de quem vai confiar nele.
///
/// Separado da instalação de propósito: é entre um e outro que a tela mostra
/// o que o plugin pede e o que ele vai rodar. Até lá nada dele saiu da pasta
/// de rascunho, e desistir apaga tudo.
class StagedPlugin {
  StagedPlugin({
    required this.staging,
    required this.dir,
    required this.manifest,
    required this.source,
    this.replacing,
  });

  /// A pasta de rascunho inteira, que some no fim de um jeito ou de outro.
  final String staging;

  /// Onde o manifesto está dentro dela -- a raiz, ou a única pasta dentro de
  /// um zip.
  final String dir;
  final PluginManifest manifest;
  final String source;

  /// A versão já instalada com o mesmo id, quando há uma: instalar é
  /// atualizar.
  final String? replacing;
}

class PluginInstallError implements Exception {
  const PluginInstallError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Os plugins instalados, e o que eles somam à janela.
///
/// Mora na [AppStore], mas não sabe dela: o que um plugin pede à janela passa
/// por [onCall], que a store liga ao `PluginApi`. Assim isto aqui é testável
/// com um plugin de verdade e uma janela de mentira.
class Plugins extends ChangeNotifier {
  Plugins({String? root}) : root = root ?? '$mxStateDir/plugins';

  /// A pasta dos plugins instalados.
  final String root;

  /// Na ordem em que a pasta os lista, que é a alfabética do id.
  final List<MxPlugin> all = [];

  /// Os ids que você desligou. Guardado no config da janela, e não na pasta
  /// do plugin: atualizar um plugin não pode religá-lo.
  final Set<String> disabled = {};

  /// Um pedido ou notificação de um plugin pra janela. Ver `PluginApi`.
  Future<Object?> Function(MxPlugin plugin, String method, Map<String, dynamic> params)? onCall;

  /// Toca quando o processo de um plugin termina o `initialize`. É por onde a
  /// janela conta a um processo recém-nascido o que ele perdeu enquanto não
  /// existia -- que a aba dele na lateral está na tela, por exemplo.
  void Function(MxPlugin plugin)? onReady;

  /// Toca quando um log muda. Separado do [notifyListeners], que repinta a
  /// janela inteira: um plugin que escreve no stderr a cada segundo não pode
  /// custar isso.
  final ValueNotifier<int> logs = ValueNotifier(0);

  bool _scanned = false;
  bool get scanned => _scanned;

  MxPlugin? byId(String id) => all.firstWhereOrNull((p) => p.id == id);

  /// Os comandos dos plugins ligados, na ordem dos plugins.
  List<PluginCommand> get commands => [
    for (final p in all)
      if (p.active) ...p.manifest!.commands,
  ];

  /// Os que pediram botão no rodapé da lateral. Com teto: a faixa tem a
  /// largura da lateral no mínimo, e um plugin a mais não pode empurrar a
  /// engrenagem pra fora dela.
  List<PluginCommand> get sidebarCommands =>
      commands.where((c) => c.sidebar).take(maxSidebarCommands).toList();
  static const maxSidebarCommands = 3;

  /// Os comandos que o plugin disse estar rodando (`command.busy`): o botão
  /// deles vira um spinner, como o do relatório sempre foi.
  final Set<String> busy = {};

  /// Um plugin que parou não está rodando comando nenhum: o spinner do botão
  /// dele não pode ficar girando pra sempre.
  void _unbusy(MxPlugin p) => busy.removeWhere((id) => id.startsWith('${p.id}/'));

  void setBusy(String fullId, bool on) {
    if (on ? busy.add(fullId) : busy.remove(fullId)) notifyListeners();
  }

  PluginCommand? commandById(String fullId) => commands.firstWhereOrNull((c) => c.fullId == fullId);

  /// O comando cuja tecla é este evento.
  ///
  /// Os atalhos da janela vêm antes: com [except], o que o mapa do app já
  /// responde não é nem consultado aqui -- um plugin nunca tira uma tecla sua.
  PluginCommand? commandFor(KeyEvent event, {MxKeymap? except}) {
    if (event is! KeyDownEvent) return null;
    if (except?.match(event) != null) return null;
    final hit = commands.firstWhereOrNull((c) => c.key != null && chordHits(c.key!, event));
    if (hit case final c?) {
      if (byId(c.pluginId) case final p?) _log(p, 'tecla ${c.key!.label} → ${c.id}');
    }
    return hit;
  }

  /// Se [event] é a tecla de [chord] -- pelo que ela escreve, ou pelo lugar
  /// dela no teclado.
  ///
  /// O segundo jeito é por causa das teclas mortas do macOS. Com ⌥, o E, o I,
  /// o N, o U e a crase são acentos esperando a próxima letra (nos layouts
  /// US, ABC e Brasileiro), e a tecla lógica que chega com ⌥⌘E não é o E: o
  /// atalho que o manifesto pediu simplesmente não disparava, sem erro
  /// nenhum. Pela posição física -- letras e dígitos, que são o que um
  /// atalho de plugin usa -- a tecla é a mesma com ou sem acento no caminho.
  /// Os modificadores continuam tendo que ser exatamente os do atalho.
  @visibleForTesting
  static bool chordHits(MxChord chord, KeyEvent event) {
    if (chord.accepts(event)) return true;
    final physical = _physicalOf(chord.key);
    if (physical == null || event.physicalKey != physical) return false;
    final k = HardwareKeyboard.instance;
    return k.isMetaPressed == chord.meta &&
        k.isControlPressed == chord.control &&
        k.isAltPressed == chord.alt &&
        k.isShiftPressed == chord.shift;
  }

  /// A posição, no padrão USB HID, da letra ou dígito [key]: `a`–`z` são
  /// 0x04–0x1d, `1`–`9` são 0x1e–0x26 e o `0` é 0x27.
  static PhysicalKeyboardKey? _physicalOf(LogicalKeyboardKey key) {
    final id = key.keyId;
    const hid = 0x00070000;
    if (id >= 0x61 && id <= 0x7a) return PhysicalKeyboardKey(hid + 0x04 + id - 0x61);
    if (id >= 0x31 && id <= 0x39) return PhysicalKeyboardKey(hid + 0x1e + id - 0x31);
    if (id == 0x30) return const PhysicalKeyboardKey(hid + 0x27);
    return null;
  }

  /// O que você configurou em cada plugin, por id do plugin. Só o que foi
  /// mexido -- o resto é o padrão do manifesto, e um padrão que muda numa
  /// versão nova do plugin tem que chegar em quem nunca mexeu.
  final Map<String, Map<String, Object?>> _settings = {};

  void load(Object? json) {
    disabled.clear();
    _settings.clear();
    if (json is Map && json['disabled'] is List) {
      disabled.addAll((json['disabled'] as List).whereType<String>());
    }
    if (json is Map && json['settings'] is Map) {
      for (final e in (json['settings'] as Map).entries) {
        if (e.key is String && e.value is Map) {
          _settings[e.key as String] = (e.value as Map).cast<String, Object?>();
        }
      }
    }
  }

  Map<String, dynamic> toJson() => {
    if (disabled.isNotEmpty) 'disabled': disabled.toList()..sort(),
    if (_settings.values.any((m) => m.isNotEmpty))
      'settings': {
        for (final e in _settings.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      },
  };

  /// As configurações de [p] como valem agora: o que você mexeu, e o padrão
  /// do manifesto no resto.
  Map<String, Object?> settingsOf(MxPlugin p) {
    final saved = _settings[p.id] ?? const {};
    return {
      for (final s in p.manifest?.settings ?? const <PluginSetting>[]) s.id: s.resolve(saved[s.id]),
    };
  }

  /// Troca uma configuração e avisa o plugin, se ele estiver de pé. Null volta
  /// pro padrão.
  void setSetting(MxPlugin p, String id, Object? value) {
    final saved = _settings.putIfAbsent(p.id, () => {});
    value == null ? saved.remove(id) : saved[id] = value;
    if (p._conn case final conn? when conn.ready) {
      conn.notify('settings.changed', {'settings': settingsOf(p)});
    }
    notifyListeners();
  }

  /// Lê a pasta de plugins de novo.
  ///
  /// Síncrono de propósito: roda na abertura antes de o tema salvo ser
  /// aplicado, e um tema de plugin só existe depois que o plugin é lido.
  /// São uns poucos jsons pequenos.
  void scan() {
    _scanned = true;
    final previous = {for (final p in all) p.dir: p};
    all.clear();
    final dir = Directory(root);
    if (dir.existsSync()) {
      final entries = dir.listSync(followLinks: false).where((e) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) return false;
        return e is Directory || (e is Link && FileSystemEntity.isDirectorySync(e.path));
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final linked = e is Link;
        PluginManifest? manifest;
        String? problem;
        try {
          manifest = PluginManifest.read(e.path);
        } on FormatException catch (err) {
          problem = err.message;
        } on FileSystemException catch (err) {
          problem = err.message;
        }
        if (manifest != null && all.any((p) => p.id == manifest!.id)) {
          problem = 'outro plugin já usa o id "${manifest.id}"';
          manifest = null;
        }
        // O mesmo objeto de antes, quando a pasta é a mesma: o processo de pé
        // está pendurado nele, e reler a pasta depois de instalar um plugin
        // não pode derrubar os outros. Só cai quem mudou de id ou de `main`
        // -- aí o processo de pé é de outro programa.
        final old = previous.remove(e.path);
        final plugin = old ?? MxPlugin(dir: e.path, linked: linked);
        if (old != null &&
            (old.manifest?.id != manifest?.id || !listEquals(old.manifest?.main, manifest?.main))) {
          _stop(old);
        }
        plugin
          ..manifest = manifest
          ..problem = problem;
        plugin.enabled = !disabled.contains(plugin.id);
        for (final w in manifest?.warnings ?? const <String>[]) {
          plugin.note('aviso: $w');
        }
        all.add(plugin);
      }
    }
    // Os que sumiram da pasta levam o processo junto.
    for (final gone in previous.values) {
      _stop(gone);
    }
    _loadThemes();
    notifyListeners();
  }

  /// Remonta [MxThemes.extra] com os temas dos plugins ligados.
  void _loadThemes() {
    MxThemes.extra.clear();
    for (final p in all) {
      p.palettes.clear();
      if (!p.active) continue;
      for (final path in p.manifest!.themes) {
        try {
          final file = File('${p.dir}/$path');
          final json = jsonDecode(file.readAsStringSync());
          if (json is! Map<String, dynamic>) throw const FormatException('não é um objeto');
          final palette = MxPalette.fromJson(json);
          if (MxThemes.isBuiltIn(palette.id)) {
            throw FormatException('"${palette.id}" é o id de um tema embutido');
          }
          if (MxThemes.extra.any((o) => o.id == palette.id)) {
            throw FormatException('outro plugin já tem um tema "${palette.id}"');
          }
          p.palettes.add(palette);
          MxThemes.extra.add(palette);
        } on FileSystemException catch (e) {
          p.note('tema $path: ${e.message}');
        } on FormatException catch (e) {
          p.note('tema $path: ${e.message}');
        }
      }
    }
  }

  /// Sobe os plugins que pediram pra subir com o app.
  void startup() {
    for (final p in all) {
      if (p.active && p.manifest!.activatesOn('onStartup')) unawaited(_start(p));
    }
  }

  /// Liga ou desliga um plugin. Desligar derruba o processo e tira os temas e
  /// comandos dele na hora.
  Future<void> setEnabled(MxPlugin p, bool on) async {
    if (p.enabled == on) return;
    p.enabled = on;
    on ? disabled.remove(p.id) : disabled.add(p.id);
    if (!on) await _stop(p);
    p.crash = null;
    _loadThemes();
    notifyListeners();
    if (on && p.manifest!.activatesOn('onStartup')) unawaited(_start(p));
  }

  /// Derruba e sobe de novo -- o botão de quem está escrevendo o plugin.
  ///
  /// Relê a pasta antes de subir: é o ciclo de quem escreve o plugin -- mexeu
  /// no manifesto ou no código, apertou reiniciar, está valendo.
  Future<void> restart(MxPlugin p) async {
    await _stop(p);
    p.crash = null;
    scan();
    notifyListeners();
    if (p.active && p.manifest!.hasProcess) await _start(p);
  }

  /// Sobe o processo de [p], se ainda não está de pé. Um pedido que chega com
  /// ele subindo espera a mesma subida em vez de abrir um segundo processo.
  Future<PluginConnection?> _start(MxPlugin p) {
    if (p._conn?.alive == true) return Future.value(p._conn);
    return p._starting ??= _spawn(p).whenComplete(() {
      p._starting = null;
      notifyListeners();
    });
  }

  Future<PluginConnection?> _spawn(MxPlugin p) async {
    final m = p.manifest;
    if (m == null || !m.hasProcess || !p.enabled) return null;
    // Depois de [_start] anotar a subida, pra que quem repinta já leia
    // "subindo".
    scheduleMicrotask(notifyListeners);
    final env = {
      ...Sh.env,
      'MAESTRIA_API': '$mxPluginApi',
      'MAESTRIA_PLUGIN_ID': p.id,
      'MAESTRIA_PLUGIN_DIR': p.dir,
      'MAESTRIA_PLUGIN_DATA': p.dataDir,
    };
    final exe = resolveExecutable(m.main!.first, p.dir, env['PATH'] ?? '');
    if (exe == null) {
      _fail(p, 'não achei "${m.main!.first}" — nem na pasta do plugin, nem no PATH');
      return null;
    }
    try {
      await Directory(p.dataDir).create(recursive: true);
      final process = await Process.start(
        exe,
        m.main!.sublist(1),
        workingDirectory: p.dir,
        environment: env,
      );
      late final PluginConnection conn;
      conn = PluginConnection(
        process,
        onRequest: (method, params) => _call(p, method, params),
        onNotify: (method, params) => unawaited(_call(p, method, params).catchError((_) => null)),
        onLog: (line) => _log(p, line),
        onExit: (code) {
          if (p._conn != conn) return;
          p._conn = null;
          // Saiu porque mandamos ([_stop] tira a conexão antes) não chega
          // aqui; o que chega é o processo indo embora sozinho.
          p.crash = 'o processo saiu (código $code)';
          _unbusy(p);
          _log(p, p.crash!);
          notifyListeners();
        },
      );
      p._conn = conn;
      _log(p, 'processo ${conn.pid} subiu: ${m.main!.join(' ')}');
      await conn.request('initialize', {
        'apiVersion': mxPluginApi,
        'blocks': mxPluginBlocks,
        // A interface que o plugin monta com widgets (ver [PluginView.rfwLibrary]).
        // 2: com o `Draggable` e o `DropTarget` de arrastar e soltar.
        'rfw': 2,
        // O painel pequeno por cima da janela (`float.show`). Ver [PluginFloats].
        'floats': 1,
        'pluginId': p.id,
        'pluginDir': p.dir,
        'dataDir': p.dataDir,
        'permissions': [for (final perm in m.permissions) perm.id],
        'settings': settingsOf(p),
      }, const Duration(seconds: 10));
      conn.ready = true;
      p.crash = null;
      notifyListeners();
      // Numa microtarefa: quem está esperando esta subida (um `_deliver`)
      // precisa receber a conexão antes de o aviso sair por ela.
      scheduleMicrotask(() => onReady?.call(p));
      return conn;
    } on PluginRpcError catch (e) {
      _fail(p, 'o initialize falhou: ${e.message}');
    } on ProcessException catch (e) {
      _fail(p, 'não deu pra rodar: ${e.message}');
    } catch (e) {
      _fail(p, '$e');
    }
    return null;
  }

  void _fail(MxPlugin p, String why) {
    p.crash = why;
    p._conn?.kill();
    p._conn = null;
    _log(p, why);
    notifyListeners();
  }

  Future<void> _stop(MxPlugin p) async {
    final conn = p._conn;
    p._conn = null;
    p._starting = null;
    _unbusy(p);
    if (conn == null) return;
    await conn.close();
    _log(p, 'processo parado');
  }

  void _log(MxPlugin p, String line) {
    p.note(line);
    logs.value++;
  }

  Future<Object?> _call(MxPlugin p, String method, Map<String, dynamic> params) async {
    // O `log` é daqui: não tem nada a ver com a janela, e é o jeito de um
    // plugin escrever sem sujar o stdout, que é o protocolo.
    if (method == 'log') {
      _log(p, '${params['message'] ?? ''}');
      return null;
    }
    final handler = onCall;
    if (handler == null) {
      throw const PluginRpcError(PluginRpcError.unavailable, 'a janela ainda não está pronta');
    }
    return handler(p, method, params);
  }

  /// Um evento da janela pros plugins que o querem.
  ///
  /// Quem já está de pé recebe. Quem não está sobe se [activations] tem um
  /// evento dele -- mas não quem caiu: um plugin que morre a cada evento
  /// subiria de novo em todo hook, pra sempre. Esse espera o "reiniciar".
  void emit(
    String type,
    Map<String, dynamic> data, {
    List<String> activations = const [],
    PluginPermission? needs,
  }) {
    for (final p in all) {
      if (!p.active || !p.manifest!.hasProcess) continue;
      if (needs != null && !p.allows(needs)) continue;
      final up = p._conn?.alive == true || p._starting != null;
      if (!up && (p.crash != null || !activations.any(p.manifest!.activatesOn))) continue;
      unawaited(_deliver(p, 'event', {'type': type, ...data}));
    }
  }

  Future<void> _deliver(MxPlugin p, String method, Map<String, dynamic> params) async {
    final conn = await _start(p);
    if (conn == null || !conn.ready) return;
    conn.notify(method, params);
  }

  /// Roda um comando que o processo do plugin atende.
  ///
  /// Aqui sim um plugin caído sobe de novo: é você pedindo, e não um evento
  /// que se repete sozinho.
  Future<Object?> invoke(PluginCommand command, Map<String, dynamic> context) async {
    final p = byId(command.pluginId);
    if (p == null || !p.active) {
      throw const PluginRpcError(PluginRpcError.unavailable, 'o plugin não está ligado');
    }
    p.crash = null;
    _log(p, 'comando ${command.id}');
    final conn = await _start(p);
    if (conn == null || !conn.ready) {
      throw PluginRpcError(PluginRpcError.unavailable, p.crash ?? 'o plugin não subiu');
    }
    try {
      return await conn.request('command.invoke', {'command': command.id, 'context': context});
    } on PluginRpcError catch (e) {
      _log(p, 'comando ${command.id} falhou: ${e.message}');
      rethrow;
    }
  }

  /// Se o processo de [p] está de pé e respondendo.
  bool isUp(MxPlugin p) => p._conn?.ready == true && p._conn?.alive == true;

  /// Sobe o processo de [p], se ele tem um e ainda não está de pé. Quem quer
  /// falar com ele depois espera o [onReady].
  void wake(MxPlugin p) {
    if (!p.active || !p.manifest!.hasProcess) return;
    p.crash = null;
    unawaited(_start(p));
  }

  /// Um evento pra um plugin só, e só se ele estiver de pé -- o de subir é o
  /// [wake].
  void tell(MxPlugin p, String type, [Map<String, dynamic> data = const {}]) {
    if (!isUp(p)) return;
    unawaited(_deliver(p, 'event', {'type': type, ...data}));
  }

  /// Um clique ou envio numa janela de plugin, de volta pro plugin.
  void viewAction(String pluginId, String viewId, String action, Map<String, dynamic> values) {
    final p = byId(pluginId);
    if (p == null || !p.active) return;
    unawaited(_deliver(p, 'view.action', {'viewId': viewId, 'action': action, 'values': values}));
  }

  // --- instalação --------------------------------------------------------

  static bool _isGit(String source) =>
      source.startsWith('https://') ||
      source.startsWith('http://') ||
      source.startsWith('git@') ||
      source.startsWith('ssh://') ||
      source.endsWith('.git');

  /// Baixa (ou copia) [source] pra uma pasta de rascunho e lê o manifesto.
  ///
  /// [source] é uma URL de git, um `.zip` ou uma pasta no disco. Nada é
  /// instalado aqui -- ver [StagedPlugin].
  Future<StagedPlugin> stage(String source) async {
    final src = expandHome(source.trim()).replaceFirst(RegExp(r'/+$'), '');
    if (src.isEmpty) throw const PluginInstallError('diga de onde instalar');
    final base = Directory('$root/.staging');
    await base.create(recursive: true);
    final staging = await base.createTemp('p');
    final into = '${staging.path}/src';
    try {
      final ShResult r;
      if (_isGit(src)) {
        r = await Sh.run('git clone --depth 1 ${Sh.q(src)} ${Sh.q(into)}');
      } else if (src.toLowerCase().endsWith('.zip') && File(src).existsSync()) {
        r = Platform.isMacOS
            ? await Sh.run('ditto -x -k ${Sh.q(src)} ${Sh.q(into)}')
            : await Sh.run('unzip -q ${Sh.q(src)} -d ${Sh.q(into)}');
      } else if (Directory(src).existsSync()) {
        r = await Sh.run('cp -R ${Sh.q(src)} ${Sh.q(into)}');
      } else {
        throw PluginInstallError(
          '"$source" não é uma URL de git, um .zip nem uma pasta que exista',
        );
      }
      if (!r.ok) {
        final why = r.stderr.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
        throw PluginInstallError(why ?? 'falhou (código ${r.code})');
      }
      final dir = _manifestDir(into);
      if (dir == null) throw const PluginInstallError('não achei um $mxManifestName ali');
      final PluginManifest manifest;
      try {
        manifest = PluginManifest.read(dir);
      } on FormatException catch (e) {
        throw PluginInstallError(e.message);
      }
      return StagedPlugin(
        staging: staging.path,
        dir: dir,
        manifest: manifest,
        source: source.trim(),
        replacing: byId(manifest.id)?.manifest?.version,
      );
    } catch (_) {
      await _rm(staging.path);
      rethrow;
    }
  }

  /// O manifesto na raiz, ou na única pasta dentro dela -- o formato de todo
  /// zip que o GitHub gera, e de quem compacta a pasta em vez do conteúdo.
  static String? _manifestDir(String dir) {
    if (File('$dir/$mxManifestName').existsSync()) return dir;
    final children = Directory(dir).listSync().whereType<Directory>().where((d) {
      final name = d.path.split('/').last;
      return !name.startsWith('.') && name != '__MACOSX';
    }).toList();
    if (children.length == 1 && File('${children.single.path}/$mxManifestName').existsSync()) {
      return children.single.path;
    }
    return null;
  }

  /// Instala o que [stage] preparou, no lugar de uma versão anterior se houver.
  Future<MxPlugin> commit(StagedPlugin staged) async {
    final id = staged.manifest.id;
    try {
      if (byId(id) case final old?) await _remove(old);
      await Directory(root).create(recursive: true);
      await Directory(staged.dir).rename('$root/$id');
    } finally {
      await _rm(staged.staging);
    }
    scan();
    final plugin = byId(id)!;
    plugin.note('instalado de ${staged.source}');
    if (plugin.active && plugin.manifest!.activatesOn('onStartup')) unawaited(_start(plugin));
    return plugin;
  }

  Future<void> discard(StagedPlugin staged) => _rm(staged.staging);

  /// Carrega um plugin direto da pasta em que ele está sendo escrito.
  ///
  /// Um link em vez de uma cópia: é o "abrir pasta de extensão" do VS Code.
  /// Salvou no editor, apertou "reiniciar", está valendo.
  Future<MxPlugin> link(String path) async {
    final src = expandHome(path.trim()).replaceFirst(RegExp(r'/+$'), '');
    if (!Directory(src).existsSync()) throw PluginInstallError('"$path" não é uma pasta');
    final PluginManifest manifest;
    try {
      manifest = PluginManifest.read(src);
    } on FormatException catch (e) {
      throw PluginInstallError(e.message);
    }
    if (byId(manifest.id) != null) {
      throw PluginInstallError('já existe um plugin "${manifest.id}" — remova ele antes');
    }
    await Directory(root).create(recursive: true);
    await Link('$root/${manifest.id}').create(Directory(src).absolute.path);
    scan();
    final plugin = byId(manifest.id)!;
    plugin.note('carregado de $src (desenvolvimento)');
    if (plugin.active && manifest.activatesOn('onStartup')) unawaited(_start(plugin));
    return plugin;
  }

  /// Tira o plugin: o processo, a pasta (ou só o link) e o que ele guardou.
  Future<void> uninstall(MxPlugin p) async {
    await _remove(p);
    await _rm(p.dataDir);
    disabled.remove(p.id);
    scan();
  }

  Future<void> _remove(MxPlugin p) async {
    await _stop(p);
    if (FileSystemEntity.isLinkSync(p.dir)) {
      await Link(p.dir).delete();
    } else {
      await _rm(p.dir);
    }
  }

  static Future<void> _rm(String path) async {
    try {
      final d = Directory(path);
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Derruba todo mundo, com a carência de cada um correndo em paralelo.
  Future<void> stopAll() => Future.wait([for (final p in all) _stop(p)]);

  /// O fim sem futuro -- ver [AppStore.dispose].
  void killAll() {
    for (final p in all) {
      p._conn?.kill();
      p._conn = null;
    }
  }

  /// O executável de `main`: um caminho relativo é da pasta do plugin, um nome
  /// solto é procurado no [path] -- o mesmo PATH com fallbacks com que o app
  /// acha o `claude` (ver [Sh.env]), porque o app aberto pelo Finder não tem o
  /// do seu shell.
  @visibleForTesting
  static String? resolveExecutable(String exe, String dir, String path) {
    final named = expandHome(exe);
    if (named.contains('/')) {
      final full = named.startsWith('/') ? named : '$dir/$named';
      return File(full).existsSync() ? full : null;
    }
    for (final d in path.split(':')) {
      if (d.isEmpty) continue;
      final f = File('$d/$named');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  @override
  void dispose() {
    killAll();
    logs.dispose();
    super.dispose();
  }
}

/// O que um `view.open`/`view.update`/`sidebar.update` traz de interface
/// própria: `rfw: { library?, root? }` e `data`. Ver [PluginView.rfwLibrary].
typedef PluginRfwUpdate = ({String? library, String? root, Map<String, Object?>? data});

/// Uma janela que um plugin desenhou: um título e uma lista de blocos.
///
/// Os blocos são json que a Maestria desenha com o tema dela -- o Block Kit do
/// Slack, e não uma webview. O plugin descreve o que quer mostrar; o botão
/// que ele pede é um botão da janela, com a cor e o corpo de qualquer outro.
/// Os tipos estão em `ui/plugin_pane.dart` e em `docs/plugins.md`.
class PluginView {
  PluginView({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.title,
    required List<Map<String, dynamic>> blocks,
  }) : _blocks = blocks {
    _adoptConsoles();
  }

  final String pluginId;
  final String pluginName;
  final String id;
  String title;

  /// A interface que o plugin monta ele mesmo (ver `ui/plugin_rfw.dart`): o
  /// texto da biblioteca de widgets, o widget de cima e os dados. Com a
  /// biblioteca, os blocos ficam de fora.
  String? rfwLibrary;
  String rfwRoot = 'root';
  final Map<String, Object?> rfwData = {};

  /// Sobe quando os dados mudam: é como o painel sabe o que repassar.
  int rfwRevision = 0;

  /// Troca a biblioteca e/ou junta dados (cada chave de cima substitui a que
  /// havia). Ver [PluginView.rfwLibrary].
  void setRfw({String? library, String? root, Map<String, Object?>? data}) {
    if (library != null) rfwLibrary = library;
    if (root != null) rfwRoot = root;
    if (data != null) {
      rfwData.addAll(data);
      rfwRevision += 1;
    }
  }

  List<Map<String, dynamic>> _blocks;
  List<Map<String, dynamic>> get blocks => _blocks;

  /// Os consoles desta janela, por `id` do bloco. Ver [PluginConsole].
  final Map<String, PluginConsole> consoles = {};

  /// Sobe a cada troca de blocos: é como o painel sabe que os campos que ele
  /// guardava podem não existir mais.
  int revision = 0;

  /// Troca os blocos. Um console que continua com o mesmo `id` e veio sem
  /// `lines` fica com as linhas que já tinha -- é o que deixa o plugin
  /// redesenhar a barra de botões sem reenviar dez mil linhas de log.
  void setBlocks(List<Map<String, dynamic>> blocks) {
    _blocks = blocks;
    revision += 1;
    _adoptConsoles();
  }

  PluginConsole console(String id) => consoles.putIfAbsent(id, PluginConsole.new);

  void _adoptConsoles() {
    final seen = <String>{};
    void visit(List<Map<String, dynamic>> of) {
      for (final b in of) {
        if (b['type'] == 'row' || b['type'] == 'card' || b['type'] == 'columns') {
          visit(blocksFrom(b['children']));
        }
        if (b['type'] != 'console' || b['id'] is! String) continue;
        final id = b['id'] as String;
        seen.add(id);
        final c = console(id);
        if (b['max'] case final num max) c.max = max.toInt();
        if (b.containsKey('lines')) c.replace(b['lines']);
      }
    }

    visit(_blocks);
    for (final gone in consoles.keys.where((k) => !seen.contains(k)).toList()) {
      consoles.remove(gone)!.dispose();
    }
  }

  static List<Map<String, dynamic>> blocksFrom(Object? raw) => [
    if (raw is List)
      for (final b in raw)
        if (b is Map) b.cast<String, dynamic>(),
  ];
}

/// As linhas de um bloco `console`, fora dos blocos de propósito.
///
/// Um log de `flutter run` chega às dezenas de linhas por segundo, e passar
/// cada lote por `view.update` seria reenviar a janela inteira e repintar o
/// app inteiro a cada lote. Aqui o lote entra por `view.appendLines`, e quem
/// escuta é só o console na tela.
/// Um pedaço de uma linha de console com cor própria: o nome do serviço na
/// frente de um log do compose, o `ERROR` no meio da linha, a cor que o
/// programa pediu com um código ANSI.
typedef PluginSpan = ({String text, String? tone, bool bold});

/// Uma linha de console. `spans`, quando vem, é a linha em pedaços -- e
/// `text` continua sendo a linha inteira, que é o que se busca e se copia.
typedef PluginLine = ({String text, String? tone, List<PluginSpan>? spans});

class PluginConsole extends ChangeNotifier {
  final List<PluginLine> lines = [];

  /// Quantas linhas ficam. As mais velhas saem primeiro.
  int max = 5000;

  static PluginLine? _line(Object? raw) => switch (raw) {
    final String text => (text: text, tone: null, spans: null),
    {'spans': final List spans} => _fromSpans(spans, raw['tone'] as String?),
    {'text': final Object? text} => (
      text: '${text ?? ''}',
      tone: raw['tone'] as String?,
      spans: null,
    ),
    _ => null,
  };

  static PluginLine _fromSpans(List raw, String? tone) {
    final spans = <PluginSpan>[
      for (final s in raw)
        if (s case {'text': final Object? t})
          (text: '${t ?? ''}', tone: s['tone'] as String?, bold: s['bold'] == true)
        else if (s is String)
          (text: s, tone: null, bold: false),
    ];
    return (text: spans.map((s) => s.text).join(), tone: tone, spans: spans);
  }

  void replace(Object? raw) {
    lines.clear();
    append(raw);
  }

  void append(Object? raw) {
    if (raw is List) {
      for (final r in raw) {
        if (_line(r) case final l?) lines.add(l);
      }
    } else if (_line(raw) case final l?) {
      lines.add(l);
    }
    if (lines.length > max) lines.removeRange(0, lines.length - max);
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }
}
