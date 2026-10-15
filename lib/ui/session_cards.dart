import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/plugins.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'dialogs.dart';
import 'icons.dart';
import 'plugin_dialogs.dart';
import 'plugin_pane.dart';
import 'terminal_pane.dart';

/// A marca de um painel: a mesma na linha da lateral e no cartão da tela
/// vazia, pra que um seja reconhecido pelo outro sem ler o nome.
class TabGlyph extends StatelessWidget {
  const TabGlyph({super.key, required this.store, required this.tab});
  final AppStore store;
  final MxTab tab;

  @override
  Widget build(BuildContext context) => switch (tab.kind) {
    TabKind.claude => ClaudeAvatar(status: tab.status, size: 26, dim: tab.done),
    // Um leitor na lista se distingue pelo que é: uma folha, não um
    // prompt esperando comando.
    TabKind.reader => Icon(Icons.article_outlined, size: 18, color: Mx.fgDim),
    // E a configuração pelos ajustes: é um painel de mexer em coisas.
    TabKind.setup => Icon(Icons.tune, size: 18, color: Mx.fgDim),
    // E a janela de plugin pela peça de quebra-cabeça: é o que o VS Code
    // e o resto do mundo usam pra "veio de uma extensão".
    TabKind.plugin => PluginGlyph(
      icon: store.plugins.byId(tab.view!.pluginId)?.manifest?.icon,
      dir: store.plugins.byId(tab.view!.pluginId)?.dir,
    ),
    // O terminal que subiu dentro de um programa se anuncia como o
    // programa: o `>_` é o prompt esperando comando, e ali não há prompt
    // nenhum -- há um btop rodando.
    //
    // O prompt vem dentro de uma tela cheia, e não como chevron solto,
    // por duas razões. Solto, ele é a mesma seta que abre as pastas e os
    // grupos duas linhas acima -- na lista, um `>` sozinho se lê como
    // "clique pra expandir". E sólido ele tem peso: ao lado da rajada do
    // claude, que enche os 26px dela, um contorno fino sumia.
    //
    // Por ser sólido é que vai a 22 e não aos 17 dos glifos de launcher:
    // o que precisa empatar é a mancha, não a caixa. Isso não desloca o
    // título -- o `leading` mora num slot de 34 centralizado.
    TabKind.shell => switch (tab.launcher) {
      final l? => Icon(l.icon.glyph, size: 17, color: l.color),
      null => MxIcon(MxIcons.terminal, size: 22, color: Mx.fgDim),
    },
  };
}

/// As sessões que ficaram na lateral, em cartões, pra tela vazia.
///
/// A tela vazia dizia "9 sessões rodando na lateral — clique numa" e mandava
/// o olho e o mouse pra outra coluna. Aqui elas vêm até você, separadas pelo
/// que pedem: primeiro as que esperam uma resposta sua, depois as que
/// terminaram sem você ver, as que ainda trabalham e, por fim, o resto.
class SessionCards extends StatelessWidget {
  const SessionCards({super.key, required this.store, required this.width});
  final AppStore store;

  /// A largura disponível, de onde sai quantas colunas cabem.
  final double width;

  static const _gap = 12.0;
  static const _cardMin = 280.0;

  /// O que dá pra trazer de volta: o que está vivo e mora na lateral das
  /// sessões. Fora as janelas de plugin e os terminais de um plugin, que
  /// voltam pela aba dele (ver [AppStore.tabsOf]).
  static List<MxTab> of(AppStore store) => store.tabs
      .where(
        (t) =>
            !t.exited &&
            !t.embedded &&
            !t.isPluginView &&
            (t.owner == null || store.plugins.byId(t.owner!) == null),
      )
      .toList();

  /// Quantas colunas a [width] comporta, e a largura de cada uma.
  static (int, double) columns(double width) {
    final cols = ((width + _gap) / (_cardMin + _gap)).floor().clamp(1, 99);
    return (cols, (width - _gap * (cols - 1)) / cols);
  }

  @override
  Widget build(BuildContext context) {
    final live = of(store);
    bool working(MxTab t) =>
        t.kind == TabKind.claude &&
        (t.status == ClaudeStatus.working ||
            t.status == ClaudeStatus.tool ||
            t.status == ClaudeStatus.starting);
    final waiting = <MxTab>[];
    final fresh = <MxTab>[];
    final busy = <MxTab>[];
    final rest = <MxTab>[];
    for (final t in live) {
      if (t.kind == TabKind.claude && !t.done && t.status.needsHuman) {
        waiting.add(t);
      } else if (t.unseen && t.rested && !t.done) {
        fresh.add(t);
      } else if (working(t)) {
        busy.add(t);
      } else {
        rest.add(t);
      }
    }
    final sections = [
      ('Esperando você', Mx.yellow, waiting),
      ('Terminaram enquanto você não via', Mx.green, fresh),
      ('Trabalhando', Mx.accent, busy),
      ('Em repouso', Mx.fgFaint, rest),
    ].where((s) => s.$3.isNotEmpty);
    final (_, cardWidth) = columns(width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (label, color, tabs) in sections) ...[
          _SectionHeader(label: label, color: color, count: tabs.length),
          const SizedBox(height: 8),
          Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [for (final t in tabs) _SessionCard(store: store, tab: t, width: cardWidth)],
          ),
          const SizedBox(height: 22),
        ],
      ],
    );
  }
}

/// Os plugins da faixa, em ladrilhos, pra tela vazia.
///
/// O mesmo conjunto e o mesmo clique da faixa à esquerda da lateral (ver
/// `SidebarRail`): só que aqui com nome e descrição, que é o que um ícone de
/// 18px não tem como dizer. E um "+" no fim, como lá, pro catálogo.
///
/// Duas medidas. Com sessões na tela vazia, uma faixa baixa no topo: os
/// plugins são o caminho pro lado, e os cartões das sessões são o assunto.
/// Sem sessão nenhuma, [large]: ícones de app no meio da tela, que é o que o
/// app é pra quem o usa só pelos plugins e nunca abre um painel.
class PluginTiles extends StatelessWidget {
  const PluginTiles({super.key, required this.store, required this.width, this.large = false});
  final AppStore store;
  final double width;
  final bool large;

  static const _gap = 10.0;
  static const _tileMin = 220.0;
  static const _appGap = 16.0;
  static const _appWidth = 196.0;

  @override
  Widget build(BuildContext context) {
    final plugins = store.railPlugins;
    if (large) {
      final tile = _appWidth.clamp(0.0, width);
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: _appGap,
        runSpacing: _appGap,
        children: [
          for (final p in plugins) _PluginTile(store: store, plugin: p, width: tile, large: true),
          _AddPluginTile(store: store, width: tile, large: true),
        ],
      );
    }
    // Poucos plugins não esticam até a borda: um ladrilho de 600px com um nome
    // de oito letras é um botão perdido. Eles ficam na largura de quando a
    // linha está cheia.
    final cols = ((width + _gap) / (_tileMin + _gap)).floor().clamp(1, 99);
    final tileWidth = (width - _gap * (cols - 1)) / cols;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionHeader(label: 'Plugins', count: plugins.length),
        const SizedBox(height: 8),
        Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final p in plugins) _PluginTile(store: store, plugin: p, width: tileWidth),
            _AddPluginTile(store: store, width: tileWidth),
          ],
        ),
      ],
    );
  }
}

class _PluginTile extends StatefulWidget {
  const _PluginTile({
    required this.store,
    required this.plugin,
    required this.width,
    this.large = false,
  });
  final AppStore store;
  final MxPlugin plugin;
  final double width;
  final bool large;

  @override
  State<_PluginTile> createState() => _PluginTileState();
}

class _PluginTileState extends State<_PluginTile> {
  bool _hover = false;

  /// O clique do ícone da faixa, menos o "clicar de novo esconde a lateral":
  /// lá o ícone aceso é a aba que você está vendo, e aqui o ladrilho é sempre
  /// um "abrir".
  void _open() {
    final store = widget.store;
    if (!store.sidebarHidden && store.shownPlugin?.id == widget.plugin.id) return;
    store.showSidebarView(widget.plugin.id);
  }

  /// O mesmo selo da faixa, na mesma ordem: rodando, e o que o plugin pediu.
  /// A contagem de janelas abertas não entra, como lá.
  Widget? _badge() {
    final store = widget.store;
    final p = widget.plugin;
    if (store.plugins.busy.any((id) => id.startsWith('${p.id}/'))) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: Mx.accent, shape: BoxShape.circle),
      );
    }
    final said = store.sidebarBadges[p.id];
    if (said == null) return null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Mx.bgActive, borderRadius: BorderRadius.circular(8)),
      child: Text(
        said,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Mx.fg),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final p = widget.plugin;
    final shown = !store.sidebarHidden && store.shownPlugin?.id == p.id;
    final about = p.manifest?.description ?? '';
    final lit = _hover || shown;
    final badge = _badge();
    final large = widget.large;
    final border = Border.all(
      color: _hover
          ? Mx.accent.withValues(alpha: 0.6)
          : shown
          ? Mx.accent.withValues(alpha: 0.35)
          : Mx.border,
    );
    final glyph = PluginGlyph(
      icon: p.manifest?.icon,
      dir: p.dir,
      size: large ? 30 : 18,
      color: lit ? Mx.fg : Mx.fgDim,
    );

    final tile = large
        ? AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: widget.width,
            height: 184,
            transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Mx.bgSidebar,
              borderRadius: BorderRadius.circular(16),
              border: border,
              boxShadow: [
                if (_hover) BoxShadow(color: Mx.shadow, blurRadius: 20, offset: const Offset(0, 8)),
              ],
            ),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 22, 16, 14),
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: lit ? Mx.accent.withValues(alpha: 0.16) : Mx.bgActive,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Center(child: glyph),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Mx.fg, fontSize: 14.5, fontWeight: FontWeight.w600),
                      ),
                      if (about.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          about,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Mx.fgFaint, fontSize: 11.5, height: 1.35),
                        ),
                      ],
                    ],
                  ),
                ),
                if (badge != null) Positioned(top: 12, right: 12, child: badge),
              ],
            ),
          )
        : AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: widget.width,
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Mx.bgSidebar,
              borderRadius: BorderRadius.circular(Mx.radius),
              border: border,
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Mx.bgActive,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(child: glyph),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Mx.fg, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      if (about.isNotEmpty)
                        Text(
                          about,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Mx.fgFaint, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                if (badge != null) Padding(padding: const EdgeInsets.only(left: 8), child: badge),
              ],
            ),
          );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: _open, child: tile),
    );
  }
}

/// O "+" do fim da faixa, em ladrilho: abre o catálogo.
class _AddPluginTile extends StatefulWidget {
  const _AddPluginTile({required this.store, required this.width, this.large = false});
  final AppStore store;
  final double width;
  final bool large;

  @override
  State<_AddPluginTile> createState() => _AddPluginTileState();
}

class _AddPluginTileState extends State<_AddPluginTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? Mx.fgDim : Mx.fgFaint;
    final large = widget.large;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => showPluginCatalog(context, widget.store),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: widget.width,
          height: large ? 184 : 58,
          decoration: BoxDecoration(
            color: _hover ? Mx.bgHover : Colors.transparent,
            borderRadius: BorderRadius.circular(large ? 16 : Mx.radius),
            border: Border.all(color: Mx.border),
          ),
          child: large
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Mx.border),
                      ),
                      child: Icon(Icons.add, size: 26, color: color),
                    ),
                    const SizedBox(height: 14),
                    Text('Instalar plugin', style: TextStyle(color: color, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('Do catálogo', style: TextStyle(color: Mx.fgFaint, fontSize: 11.5)),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 16, color: color),
                    const SizedBox(width: 6),
                    Text('Instalar plugin', style: TextStyle(color: color, fontSize: 12)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.color, required this.count});
  final String label;

  /// O ponto antes do rótulo. Sem cor, sem ponto: é a seção dos plugins, que
  /// não tem estado nenhum a dizer.
  final Color? color;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (color case final c?) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(color: Mx.fgDim, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(color: Mx.fgFaint, fontSize: 11.5, fontFamily: Mx.mono),
        ),
      ],
    );
  }
}

class _SessionCard extends StatefulWidget {
  const _SessionCard({required this.store, required this.tab, required this.width});
  final AppStore store;
  final MxTab tab;
  final double width;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _hover = false;

  static const _height = 118.0;

  /// A pasta e a branch, menos o que o título já disse: um painel no checkout
  /// principal já se chama pela pasta.
  String get _where {
    final tab = widget.tab;
    final folder = tab.folder;
    return [
      if (!folder.isLoose && tab.title != folder.name) folder.name,
      if (tab.branch.isNotEmpty && tab.branch != '(detached)') tab.branch,
    ].join(' · ');
  }

  /// O corpo do cartão, e se ele é um caminho.
  ///
  /// Num terminal sem programa o subtítulo é só "Shell", e isso o rodapé já
  /// diz -- o que distingue um do outro é onde ele está. E numa sessão que
  /// ainda não disse nada o subtítulo é o próprio estado ("Pronto"), que o
  /// rodapé também diz: ali vale mais o último pedido, ou nada.
  (String?, bool) get _body {
    final tab = widget.tab;
    if (tab.kind == TabKind.shell && tab.launcher == null) {
      final home = Platform.environment['HOME'];
      final cwd = tab.cwd;
      return (home != null && cwd.startsWith(home) ? '~${cwd.substring(home.length)}' : cwd, true);
    }
    final said = tab.subtitle;
    if (tab.kind == TabKind.claude && (said == tab.status.label || said == 'Pronto')) {
      return (tab.hooks.lastPrompt, false);
    }
    return (said, false);
  }

  /// O que a sessão é, ou em que pé está, pro canto de baixo.
  (String, Color) get _state {
    final tab = widget.tab;
    return switch (tab.kind) {
      TabKind.claude => (tab.status.label, tab.status.color),
      TabKind.shell => (tab.launcher != null ? 'Programa' : 'Terminal', Mx.fgFaint),
      TabKind.reader => ('Documento', Mx.fgFaint),
      TabKind.setup => ('Configuração', Mx.fgFaint),
      TabKind.plugin => ('Plugin', Mx.fgFaint),
    };
  }

  void _open() {
    final store = widget.store;
    final tab = widget.tab;
    // O mesmo que o clique na linha: a de um painel agrupado abre o grupo.
    final group = store.groupOf(tab);
    group == null ? store.select(tab) : store.openGroup(group);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final tab = widget.tab;
    final attention = tab.kind == TabKind.claude && !tab.done && tab.status.needsHuman;
    final tint = store.tintOf(tab);
    final borderColor = _hover
        ? Mx.accent.withValues(alpha: 0.6)
        : attention
        ? tab.status.color.withValues(alpha: 0.45)
        : Mx.border;
    final (stateLabel, stateColor) = _state;
    final where = _where;
    final ago = tab.restedAgo;

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      width: widget.width,
      height: _height,
      transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
      decoration: BoxDecoration(
        color: _hover ? Mx.bgHover : Mx.bgSidebar,
        borderRadius: BorderRadius.circular(Mx.radius),
        border: Border.all(color: borderColor),
        boxShadow: [
          if (_hover) BoxShadow(color: Mx.shadow, blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // A cor que você deu ao painel, ou ao grupo dele: a mesma que pinta a
          // linha da lateral, pra que um seja reconhecido pelo outro.
          if (tint != null)
            Positioned(left: 0, top: 0, bottom: 0, child: Container(width: 3, color: tint)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 30,
                      child: Center(
                        child: TabGlyph(store: store, tab: tab),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tab.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: tab.done ? Mx.fgDim : Mx.fg,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (where.isNotEmpty)
                            Text(
                              where,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Mx.fgFaint,
                                fontSize: 10.5,
                                fontFamily: Mx.mono,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (tab.hotkey case final k?)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: Mx.bgActive,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          k.label,
                          style: TextStyle(fontFamily: Mx.mono, fontSize: 10, color: Mx.fgDim),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 9),
                Expanded(
                  child: switch (_body) {
                    (final text?, final path) => Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Mx.fgDim,
                        fontSize: path ? 11.5 : 12,
                        fontFamily: path ? Mx.mono : null,
                        height: 1.4,
                      ),
                    ),
                    _ => Text(
                      'Nada dito ainda',
                      style: TextStyle(
                        color: Mx.fgFaint,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  },
                ),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(stateLabel, style: TextStyle(color: stateColor, fontSize: 11)),
                    const Spacer(),
                    if (tab.done)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.task_alt, size: 13, color: Mx.green),
                      ),
                    if (tab.followUps.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: FollowUpMark(tab: tab),
                      ),
                    if (ago != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          ago,
                          style: TextStyle(fontSize: 11, color: tab.unseen ? Mx.green : Mx.fgFaint),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Arrastável como a linha da lateral: soltar aqui mesmo é o clique, e a
      // tela vazia já aceita o drop (ver `_EmptyDrop`).
      child: Draggable<MxTab>(
        data: tab,
        feedback: Material(
          type: MaterialType.transparency,
          child: Opacity(opacity: 0.92, child: card),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: card),
        child: GestureDetector(
          onTap: _open,
          onSecondaryTapDown: (d) => showPanelMenu(context, store, tab, d.globalPosition),
          child: card,
        ),
      ),
    );
  }
}
