import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models.dart';
import 'docs.dart';
import 'editor.dart';
import 'history.dart';
import 'notify.dart';
import 'plugins.dart';
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
            },
        ];
      case 'projects.list':
        return [
          for (final pr in store.projects)
            {'id': pr.id, 'name': pr.name, 'folder': pr.folderRoot, 'brief': pr.brief},
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
          store.showBanner('não achei o vscode — nem o `code` no PATH, nem o app', sticky: true);
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
        final text = _text(p, 'text');
        if (p['submit'] == true) {
          await tab.term.submit(text);
        } else {
          tab.term.terminal.paste(text);
        }
        return null;
      case 'session.openClaude':
        _need(plugin, PluginPermission.sessionsCreate);
        final (folder, cwd) = _place(p);
        final tab = store.openClaude(
          folder,
          cwd: cwd,
          label: p['label'] as String?,
          prompt: p['prompt'] as String?,
          project: store.focusedProject,
        );
        return {'tabId': tab.id};
      case 'session.openShell':
        _need(plugin, PluginPermission.sessionsCreate);
        final (folder, cwd) = _place(p);
        final tab = store.openShell(folder, cwd: cwd, command: p['command'] as String?);
        if (p['label'] case final String label when label.isNotEmpty) tab.customLabel = label;
        // Do plugin: sai dos avulsos e vai pra aba dele. Ver [MxTab.owner].
        if (p['owned'] == true) {
          tab
            ..owner = plugin.id
            ..ownerTag = p['tag'] as String?;
        }
        store.touch();
        return {'tabId': tab.id};
      case 'session.close':
        // Só o que é dele: fechar a sessão de outra pessoa -- a sua -- não é
        // coisa que um plugin faça.
        final tab = _tab(p);
        if (tab.owner != plugin.id) {
          throw const PluginRpcError(
            PluginRpcError.forbidden,
            'só dá pra fechar um terminal que o plugin abriu com "owned"',
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
        );
        return {'tabId': tab.id};
      case 'view.update':
        final ok = store.updatePluginView(
          plugin,
          _text(p, 'viewId'),
          title: p['title'] as String?,
          blocks: p.containsKey('blocks') ? PluginView.blocksFrom(p['blocks']) : null,
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
    'project': store.projectOf(t)?.name,
    'launcher': t.launcher?.name,
    'owner': t.owner,
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
