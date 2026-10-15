import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models.dart';
import 'docs.dart';
import 'editor.dart';
import 'history.dart';
import 'notify.dart';
import 'plugin_floats.dart';
import 'plugins.dart';
import 'pty.dart' show TermSession;
import 'store.dart';

/// O que um plugin pode pedir à janela: os métodos do lado de cá do JSON-RPC.
///
/// Um lugar só, e um `switch` só, porque isto *é* a API -- o que não está
/// aqui um plugin não alcança. `docs/plugins.md` descreve cada método; quem
/// acrescentar um aqui acrescenta lá.
///
/// Os erros sobem como [PluginRpcError] e voltam pro plugin como a resposta
/// de erro do pedido dele: um painel que não existe, uma permissão que o
/// manifesto não declarou. Nada disso é motivo pra janela reclamar -- quem
/// precisa saber é quem pediu.
class PluginApi {
  PluginApi(this.store);

  final AppStore store;

  Future<Object?> handle(MxPlugin plugin, String method, Map<String, dynamic> p) async {
    switch (method) {
      case 'window.showBanner':
        store.showBanner('${plugin.name}: ${_text(p, 'text')}', sticky: p['sticky'] == true);
        return null;
      case 'window.notify':
        _need(plugin, PluginPermission.notifications);
        await store.notifier.alert((p['title'] as String?) ?? plugin.name, _text(p, 'body'));
        return null;
      case 'window.openUrl':
        final url = _text(p, 'url');
        // Só a web: um `file://` ou um esquema de app seria um jeito de o
        // plugin abrir o que quisesse por um caminho que o nome do método não
        // anuncia.
        if (!url.startsWith('https://') && !url.startsWith('http://')) {
          throw const PluginRpcError(PluginRpcError.invalidParams, 'só dá pra abrir http(s)');
        }
        await Notifier.openLink(url);
        return null;
      case 'window.pick':
        final pick = store.quickPick;
        if (pick == null) {
          throw const PluginRpcError(PluginRpcError.unavailable, 'a janela não tem onde perguntar');
        }
        final items = [
          for (final it in (p['items'] as List? ?? const []))
            if (it is Map && it['value'] is String)
              (
                value: it['value'] as String,
                label: (it['label'] as String?) ?? it['value'] as String,
                detail: it['detail'] as String?,
              ),
        ];
        if (items.isEmpty) return null;
        return pick(
          title: (p['title'] as String?) ?? plugin.name,
          placeholder: p['placeholder'] as String?,
          items: items,
        );
      case 'window.input':
        final input = store.quickInput;
        if (input == null) {
          throw const PluginRpcError(PluginRpcError.unavailable, 'a janela não tem onde perguntar');
        }
        return input(
          title: (p['title'] as String?) ?? plugin.name,
          placeholder: p['placeholder'] as String?,
          value: p['value'] as String?,
          prompt: p['prompt'] as String?,
        );
      case 'window.form':
        final show = store.quickForm;
        if (show == null) {
          throw const PluginRpcError(PluginRpcError.unavailable, 'a janela não tem onde perguntar');
        }
        final PluginForm form;
        try {
          form = PluginForm.parse(p, fallbackTitle: plugin.name);
        } on FormatException catch (e) {
          throw PluginRpcError(PluginRpcError.invalidParams, e.message);
        }
        final answer = await show(form);
        return answer == null ? null : {'action': answer.action, 'values': answer.values};
      case 'settings.get':
        return store.plugins.settingsOf(plugin);
      case 'clipboard.write':
        await Clipboard.setData(ClipboardData(text: _text(p, 'text')));
        return null;
      case 'sessions.list':
        return [for (final t in store.tabs) sessionJson(t, plugin: plugin)];
      case 'sessions.focused':
        final tab = store.focusedTab;
        return tab == null ? null : sessionJson(tab, plugin: plugin);
      case 'folders.list':
        return [
          for (final f in store.folders)
            {
              'name': f.name,
              'root': f.root,
              'isRepo': f.isRepo,
              'branch': f.branch,
              'worktrees': [
                for (final w in store.worktrees[f.root] ?? const <WorktreeInfo>[])
                  {
                    'path': w.path,
                    'branch': w.branch,
                    'isMain': w.isMain,
                    'label': w.shortLabel,
                    'prunable': w.prunable,
                  },
              ],
              'workspaces': [for (final w in store.workspacesOf(f)) w.name],
            },
        ];
      // `projects.list` é o nome de antes do rename, e plugins já instalados
      // chamam por ele. Os dois respondem a mesma lista.
      case 'featuresOrHotfixes.list':
      case 'projects.list':
        return [
          for (final pr in store.featuresOrHotfixes)
            {
              'id': pr.id,
              'name': pr.name,
              'kind': pr.kind.name,
              'folder': pr.folderRoot,
              'brief': pr.brief,
            },
        ];
      case 'workspaces.list':
        return [
          for (final w in store.workspaces)
            {
              'id': w.id,
              'name': w.name,
              'folders': [for (final f in store.foldersOf(w)) f.root],
              if (w.codeWorkspacePath != null) 'codeWorkspacePath': w.codeWorkspacePath,
            },
        ];
      case 'chats.list':
        // Os títulos das conversas são o que você pediu nelas: a mesma
        // permissão dos hooks, que é a que diz isso na instalação.
        _need(plugin, PluginPermission.hooks);
        final day = DateTime.tryParse(_text(p, 'day'));
        if (day == null) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"day" é AAAA-MM-DD');
        }
        return [
          for (final c in await ChatHistory.read(on: day))
            {
              'sessionId': c.sessionId,
              'title': c.title,
              'cwd': c.cwd,
              'folder': c.where,
              'at': c.at.toIso8601String(),
              'size': c.size,
            },
        ];
      case 'editor.open':
        final path = _text(p, 'path');
        final line = (p['line'] as num?)?.toInt();
        if (line == null) {
          await store.openInEditor(path);
        } else if (!await Editor.open(path, line: line)) {
          store.showBanner('Não achei o vscode — nem o `code` no PATH, nem o app', sticky: true);
        }
        return null;
      case 'session.focus':
        // Pôr um painel na tela é o que um clique na lateral faz: não mexe no
        // que está dentro dele, então não pede permissão.
        store.select(_tab(p));
        return null;
      case 'terminal.sendText':
        _need(plugin, PluginPermission.terminalWrite);
        final tab = _sessionTab(p);
        if (tab.isPassive || tab.exited || tab.hibernated) {
          throw PluginRpcError(
            PluginRpcError.invalidParams,
            '"${tab.title}" não tem processo pra receber texto',
          );
        }
        _trustGate(tab);
        final text = _text(p, 'text');
        if (p['submit'] == true) {
          // Sem texto, o enter sozinho: manda o que já está no prompt (a
          // imagem que o `terminal.pasteClipboard` pôs lá).
          if (text.trim().isEmpty) {
            tab.term.enter();
          } else {
            await tab.term.submit(text);
          }
        } else {
          tab.term.terminal.paste(text);
        }
        return null;
      case 'terminal.sendKeys':
        // Teclas de verdade, e não uma colagem: as setas e o enter que
        // respondem a pergunta de um claude (o `AskUserQuestion`) do chat de
        // um plugin.
        _need(plugin, PluginPermission.terminalWrite);
        final tab = _sessionTab(p);
        if (tab.isPassive || tab.exited || tab.hibernated) {
          throw PluginRpcError(PluginRpcError.invalidParams, '"${tab.title}" não tem processo pra receber teclas');
        }
        _trustGate(tab);
        final keys = p['keys'];
        if (keys is! List ||
            keys.isEmpty ||
            keys.length > 200 ||
            keys.any((k) => !TermSession.terminalKeys.containsKey(k) && !(k is Map && k['text'] is String))) {
          throw PluginRpcError(
            PluginRpcError.invalidParams,
            '`keys`: uma lista de ${TermSession.terminalKeys.keys.join(', ')} ou { text }',
          );
        }
        await tab.term.sendKeys(keys);
        return null;
      case 'terminal.pasteClipboard':
        // O ⌘V de um terminal, feito pelo plugin: texto entra como colagem; uma
        // imagem (o print), num claude, vira o ^V com que ele mesmo a lê da área
        // de transferência -- o "colar um print" do chat de um plugin.
        _need(plugin, PluginPermission.terminalWrite);
        final tab = _sessionTab(p);
        if (tab.isPassive || tab.exited || tab.hibernated) {
          throw PluginRpcError(PluginRpcError.invalidParams, '"${tab.title}" não tem processo pra receber a colagem');
        }
        _trustGate(tab);
        await tab.term.pasteClipboard(imagesViaCtrlV: tab.kind == TabKind.claude);
        return null;
      case 'session.openClaude':
        _need(plugin, PluginPermission.sessionsCreate);
        final (folder, cwd) = _place(p);
        final tab = store.openClaude(
          folder,
          cwd: cwd,
          label: p['label'] as String?,
          prompt: p['prompt'] as String?,
          featureOrHotfix: store.focusedFeatureOrHotfix,
          // Em segundo plano: a sessão sobe e aparece na lateral, e você fica
          // onde está (a tela do plugin que a abriu).
          place: p['background'] != true,
        );
        return {'tabId': tab.id};
      case 'session.rename':
        // O nome da sessão, como o "renomear" da lateral: vale pra lateral, o
        // cabeçalho e o histórico. Vazio volta pro nome de sempre (a pasta, a
        // branch). Pede o `tabId`: renomear o painel em foco por engano não.
        _need(plugin, PluginPermission.sessionsCreate);
        if (p['tabId'] is! String) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"tabId" é obrigatório');
        }
        final tab = _tab(p);
        final title = _text(p, 'title').trim();
        store.renameTab(tab, title.length > 80 ? title.substring(0, 80) : title);
        return {'title': tab.title};
      case 'session.wake':
        // Religa uma sessão hibernada, na mesma conversa -- o clique na linha
        // dela, feito pelo plugin. Ela volta como `starting` e, quando o
        // claude sobe, `ready`; os dois chegam como `session.status`.
        _need(plugin, PluginPermission.sessionsCreate);
        // Sem o "painel em foco" de reserva: acordar é ligar um processo, e
        // tem que ser o que o plugin pediu.
        if (p['tabId'] is! String) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"tabId" é obrigatório');
        }
        final tab = _tab(p);
        if (!tab.hibernated) return {'woke': false};
        await store.wake(tab);
        return {'woke': true};
      case 'session.portrait':
        // O retrato de uma sessão do claude (um png do próprio plugin), que a
        // notificação de quando ela para por você leva junto. Só arquivo da
        // pasta do plugin ou da de dados dele: o plugin não aponta a janela
        // pra um arquivo qualquer da máquina.
        if (p['tabId'] is! String) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"tabId" é obrigatório');
        }
        final tab = _tab(p);
        if (tab.kind != TabKind.claude) {
          throw const PluginRpcError(PluginRpcError.invalidParams, 'só uma sessão do claude tem retrato');
        }
        final image = p['image'];
        if (image == null) {
          tab.portrait = null;
          return null;
        }
        if (image is! String || !image.toLowerCase().endsWith('.png') || !File(image).existsSync()) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"image": o caminho de um .png que existe');
        }
        final real = File(image).absolute.resolveSymbolicLinksSync();
        bool inside(String dir) {
          final d = Directory(dir);
          if (!d.existsSync()) return false;
          return real.startsWith('${d.absolute.resolveSymbolicLinksSync()}/');
        }
        final mine = inside(plugin.dir) || inside(plugin.dataDir);
        if (!mine) {
          throw const PluginRpcError(PluginRpcError.forbidden, '"image" tem que estar na pasta do plugin ou na de dados dele');
        }
        tab.portrait = real;
        return null;
      case 'session.hibernate':
        // O "hibernar" da lateral, feito pelo plugin: desliga o processo de
        // uma sessão parada e fica com a conversa. Volta com `session.wake`.
        // Desligar um processo é parente de fechar: pede `sessions.close`.
        _need(plugin, PluginPermission.sessionsClose);
        if (p['tabId'] is! String) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"tabId" é obrigatório');
        }
        final tab = _tab(p);
        if (tab.hibernated) return {'hibernated': false};
        if (!store.canHibernate(tab)) {
          throw PluginRpcError(
            PluginRpcError.invalidParams,
            tab.kind != TabKind.claude || tab.exited
                ? '"${tab.title}" não é uma sessão do claude rodando'
                : '"${tab.title}" ainda não tem conversa pra retomar',
          );
        }
        // No meio de um turno, ou com agentes rodando, o processo é trabalho
        // em andamento -- como no hibernar sozinho, só a sessão parada.
        final status = tab.status;
        if ((status != ClaudeStatus.ready && !status.atRest) || tab.hooks.busyForks) {
          throw PluginRpcError(
            PluginRpcError.invalidParams,
            '"${tab.title}" está trabalhando: hiberne quando ele parar',
          );
        }
        store.hibernate(tab);
        return {'hibernated': true};
      case 'suggestion.created':
        // O fim do `suggestion.start`: a tarefa existe no tracker, e a
        // Maestria faz o que foi escolhido no cartão. Ver
        // [AppStore.suggestionTracked].
        if (plugin.manifest?.suggestions == null) {
          throw const PluginRpcError(
            PluginRpcError.forbidden,
            'só quem declara "contributes.suggestions" recebe tarefas sugeridas',
          );
        }
        final id = p['suggestionId'];
        final ref = p['ref'];
        if (id is! String || ref is! String || ref.trim().isEmpty) {
          throw const PluginRpcError(PluginRpcError.invalidParams, 'faltam "suggestionId" e "ref"');
        }
        final tab = await store.suggestionTracked(
          plugin,
          suggestionId: id,
          ref: ref.trim(),
          intro: (p['intro'] as String?) ?? '',
          branch: p['branch'] as String?,
          dir: p['dir'] as String?,
        );
        return tab == null ? null : {'tabId': tab.id, 'cwd': tab.cwd};
      case 'session.openShell':
        _need(plugin, PluginPermission.sessionsCreate);
        final (folder, cwd) = _place(p);
        // Embutido é do plugin por definição: mora numa janela dele, desenhado
        // por um bloco `terminal`, e não entra na grade. Ver [MxTab.embedded].
        final embedded = p['embedded'] == true;
        final tab = store.openShell(
          folder,
          cwd: cwd,
          command: p['command'] as String?,
          place: !embedded,
        );
        if (p['label'] case final String label when label.isNotEmpty) tab.customLabel = label;
        // Do plugin: sai dos avulsos e vai pra aba dele. Ver [MxTab.owner].
        if (p['owned'] == true || embedded) {
          tab
            ..owner = plugin.id
            ..ownerTag = p['tag'] as String?
            ..embedded = embedded;
        }
        store.touch();
        return {'tabId': tab.id};
      case 'session.close':
        // O que é dele, sempre. Uma sessão sua do claude, só com
        // `sessions.close` -- declarada no manifesto, e vista na instalação --,
        // e com o `tabId` dito: nada de fechar o painel em foco por engano. O
        // plugin é quem pergunta antes (o "mandar pra casa" do escritório).
        if (p['tabId'] is! String) {
          throw const PluginRpcError(PluginRpcError.invalidParams, '"tabId" é obrigatório');
        }
        final tab = _tab(p);
        final mine = tab.owner == plugin.id;
        final claude = tab.kind == TabKind.claude && tab.owner == null;
        if (!mine && !(claude && plugin.allows(PluginPermission.sessionsClose))) {
          throw PluginRpcError(
            PluginRpcError.forbidden,
            claude
                ? 'fechar uma sessão do claude pede a permissão "sessions.close"'
                : 'só dá pra fechar um terminal que o plugin abriu com "owned"',
          );
        }
        store.closeTab(tab);
        return null;
      case 'pane.openMarkdown':
        final tab = store.showDoc(
          MxDoc(
            source: DocSource.plugin,
            title: (p['title'] as String?) ?? plugin.name,
            text: _text(p, 'markdown'),
            origin: plugin.name,
          ),
        );
        return {'tabId': tab.id};
      case 'sidebar.update':
        if (plugin.manifest?.sidebar != true) {
          throw const PluginRpcError(
            PluginRpcError.invalidParams,
            'o manifesto não declara "contributes.sidebar"',
          );
        }
        final shown = store.updatePluginSidebar(
          plugin,
          blocks: p.containsKey('blocks') ? PluginView.blocksFrom(p['blocks']) : null,
          rfw: _rfw(p),
          badge: switch (p['badge']) {
            _ when !p.containsKey('badge') => null,
            null => '',
            final Object b => '$b',
          },
        );
        return {'shown': shown};
      case 'view.open':
        if (_text(p, 'viewId') == AppStore.sidebarViewId) {
          throw const PluginRpcError(
            PluginRpcError.invalidParams,
            '"sidebar" é o id da aba da lateral — use sidebar.update',
          );
        }
        final tab = store.openPluginView(
          plugin,
          _text(p, 'viewId'),
          title: (p['title'] as String?) ?? plugin.name,
          blocks: PluginView.blocksFrom(p['blocks']),
          rfw: _rfw(p),
          modal: p['modal'] == true,
          from: p['from'] as String?,
          width: (p['width'] as num?)?.toDouble(),
          height: (p['height'] as num?)?.toDouble(),
        );
        return {'tabId': tab.id};
      case 'view.update':
        final ok = store.updatePluginView(
          plugin,
          _text(p, 'viewId'),
          title: p['title'] as String?,
          blocks: p.containsKey('blocks') ? PluginView.blocksFrom(p['blocks']) : null,
          rfw: _rfw(p),
        );
        return {'open': ok};
      case 'command.busy':
        final id = _text(p, 'command');
        if (plugin.manifest?.commands.any((c) => c.id == id) != true) {
          throw PluginRpcError(PluginRpcError.invalidParams, 'o plugin não tem o comando "$id"');
        }
        store.plugins.setBusy('${plugin.id}/$id', p['busy'] == true);
        return null;
      case 'view.appendLines':
        final console = store.pluginConsole(plugin, _text(p, 'viewId'), _text(p, 'id'));
        console?.append(p['lines']);
        return {'open': console != null};
      case 'view.clearLines':
        store.pluginConsole(plugin, _text(p, 'viewId'), _text(p, 'id'))?.clear();
        return null;
      case 'view.close':
        store.closePluginView(plugin, _text(p, 'viewId'));
        return null;
      case 'float.show':
        final corner = p['corner'];
        if (corner != null && FloatCorner.parse(corner) == null) {
          throw const PluginRpcError(
            PluginRpcError.invalidParams,
            '"corner" é topLeft, topRight, bottomLeft ou bottomRight',
          );
        }
        store.floats.show(
          plugin,
          _text(p, 'id'),
          width: (p['width'] as num?)?.toDouble(),
          height: (p['height'] as num?)?.toDouble(),
          corner: FloatCorner.parse(corner),
          blocks: p.containsKey('blocks') ? PluginView.blocksFrom(p['blocks']) : null,
          rfw: _rfw(p),
        );
        return {'shown': true};
      case 'float.update':
        final shown = store.floats.update(
          plugin,
          _text(p, 'id'),
          width: (p['width'] as num?)?.toDouble(),
          height: (p['height'] as num?)?.toDouble(),
          blocks: p.containsKey('blocks') ? PluginView.blocksFrom(p['blocks']) : null,
          rfw: _rfw(p),
        );
        return {'shown': shown};
      case 'float.hide':
        store.floats.hide(plugin, _text(p, 'id'));
        return null;
      default:
        throw PluginRpcError(PluginRpcError.methodNotFound, 'método desconhecido: $method');
    }
  }

  /// Um painel como o plugin o vê. De propósito sem nada do terminal: o que
  /// está escrito no pty é seu, e um plugin que quer saber o que a sessão
  /// faz tem os hooks -- com a permissão que diz isso na instalação.
  ///
  /// A atividade -- quantos pedidos, o último pedido e a última resposta, os
  /// arquivos que a sessão escreveu -- só vai pra quem declarou `hooks`: é o
  /// mesmo conteúdo que os eventos de hook carregam.
  Map<String, dynamic> sessionJson(MxTab t, {MxPlugin? plugin}) => {
    'id': t.id,
    'kind': t.kind.name,
    'title': t.title,
    'cwd': t.cwd,
    'folder': t.folder.root,
    'branch': t.branch,
    'status': t.status.name,
    'statusLabel': t.status.label,
    // A pergunta que quase todo plugin quer fazer sobre uma sessão, feita do
    // jeito que a lateral faz -- sem o plugin ter que conhecer os seis
    // estados que querem dizer isso.
    'needsYou': !t.done && t.status.needsHuman,
    'sessionId': t.resumeId,
    'done': t.done,
    'hibernated': t.hibernated,
    'exited': t.exited,
    'onScreen': store.isOpen(t),
    'focused': store.focusedTab?.id == t.id,
    'startedAt': t.startedAt.toIso8601String(),
    'project': store.featureOrHotfixOf(t)?.name,
    // `project` é o nome de antes do rename; fica pelos plugins que já o leem.
    'featureOrHotfix': store.featureOrHotfixOf(t)?.name,
    'featureOrHotfixKind': store.featureOrHotfixOf(t)?.kind.name,
    'workspaces': [for (final w in store.workspacesOf(t.folder)) w.name],
    'launcher': t.launcher?.name,
    // Quanto da janela de contexto a sessão já ocupa, da linha de status do
    // Claude Code; `null` antes da primeira resposta e logo depois de um
    // `/compact`. Muda com o evento `session.context`.
    'context': contextJson(t.context),
    'owner': t.owner,
    'embedded': t.embedded,
    // O tag é conversa entre o plugin e os terminais dele.
    if (plugin != null && t.owner == plugin.id) 'tag': t.ownerTag,
    if (plugin?.allows(PluginPermission.hooks) ?? false)
      'activity': {
        'prompts': t.hooks.prompts,
        'tools': t.hooks.tools,
        'touched': t.hooks.touched,
        'lastPrompt': t.hooks.lastPrompt,
        'lastMessage': t.hooks.lastMessageFull ?? t.hooks.lastMessage,
      },
  };

  static Map<String, int>? contextJson(ContextUsage? c) =>
      c == null ? null : {'percent': c.percent, 'tokens': c.tokens, 'window': c.window};

  /// Com o "confia nesta pasta?" do Claude Code na tela, nada de fora entra
  /// no terminal: o "No, exit" vem marcado, e o enter de uma mensagem fecha a
  /// sessão. Quem responde essa pergunta é você, no terminal.
  static void _trustGate(MxTab tab) {
    if (tab.kind == TabKind.claude && tab.term.asksTrust) {
      throw PluginRpcError(
        PluginRpcError.invalidParams,
        '"${tab.title}" está perguntando se você confia na pasta: responda no terminal dele',
      );
    }
  }

  static void _need(MxPlugin plugin, PluginPermission perm) {
    if (plugin.allows(perm)) return;
    throw PluginRpcError(
      PluginRpcError.forbidden,
      'o manifesto não declara a permissão "${perm.id}"',
    );
  }

  static String _text(Map<String, dynamic> p, String key) {
    final v = p[key];
    if (v is! String) throw PluginRpcError(PluginRpcError.invalidParams, '"$key" é obrigatório');
    return v;
  }

  MxTab _tab(Map<String, dynamic> p) {
    final id = p['tabId'] as String?;
    final tab = id == null ? store.focusedTab : store.tabById(id);
    if (tab == null) {
      throw PluginRpcError(
        PluginRpcError.invalidParams,
        id == null ? 'nenhum painel em foco' : 'não há painel "$id"',
      );
    }
    return tab;
  }

  /// O painel que recebe texto: o pedido, ou o em foco -- e, quando o em foco
  /// não tem processo, o primeiro da tela que tem. É o caso de todo botão de
  /// janela de plugin: clicar nele põe o foco na própria janela, e "mandar
  /// pra sessão em foco" não pode querer dizer mandar pra ela.
  MxTab _sessionTab(Map<String, dynamic> p) {
    if (p['tabId'] != null) return _tab(p);
    final focused = store.focusedTab;
    if (focused != null && !focused.isPassive) return focused;
    final shown = store.openPanes.where((t) => !t.isPassive);
    return shown.where((t) => t.kind == TabKind.claude).firstOrNull ??
        shown.firstOrNull ??
        (throw const PluginRpcError(PluginRpcError.invalidParams, 'nenhuma sessão na tela'));
  }

  /// A pasta e o cwd de um painel novo: o `cwd` pedido, pendurado na pasta da
  /// lateral que o contém -- ou, sem `cwd`, onde está o painel em foco.
  /// A interface própria de um pedido (ver [PluginView.rfwLibrary]):
  /// `rfw: { library?, root? }` e `data`, cada um opcional.
  PluginRfwUpdate? _rfw(Map<String, dynamic> p) {
    final rfw = p['rfw'];
    final data = p['data'];
    if (rfw == null && data == null) return null;
    if (rfw != null && rfw is! Map) {
      throw const PluginRpcError(PluginRpcError.invalidParams, '"rfw" é { library, root? }');
    }
    if (data != null && data is! Map) {
      throw const PluginRpcError(PluginRpcError.invalidParams, '"data" é um objeto');
    }
    final r = (rfw as Map?)?.cast<String, dynamic>();
    return (
      library: r?['library'] as String?,
      root: r?['root'] as String?,
      data: (data as Map?)?.cast<String, Object?>(),
    );
  }

  (Folder, String) _place(Map<String, dynamic> p) {
    final cwd = p['cwd'] as String?;
    if (cwd == null) {
      final focused = store.focusedTab;
      final folder = focused?.folder ?? store.focusedFolder;
      return (folder, focused?.cwd ?? folder.root);
    }
    return (store.folderAt(cwd) ?? store.loose, cwd);
  }
}
