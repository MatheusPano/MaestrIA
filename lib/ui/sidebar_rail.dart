import 'package:flutter/material.dart';

import '../models.dart';
import '../services/plugins.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'plugin_dialogs.dart';
import 'plugin_pane.dart';

/// A faixa de ícones à esquerda da lateral: as sessões, e uma aba por plugin
/// que tem um lugar a oferecer. A barra de atividades do VS Code.
///
/// Existe porque cada plugin empilhava a própria seção embaixo dos avulsos, e
/// duas ferramentas abertas já eram duas réguas, dois respiros e duas linhas
/// de duas alturas disputando espaço com o trabalho. Aqui cada plugin custa um
/// ícone, e a lateral inteira é dele só quando você pede.
///
/// Fica no canvas, fora do cartão da lateral: não sai da largura da lista --
/// no `minSidebar` a busca já estava no osso -- e continua na tela com a
/// lateral escondida, que é quando ela também serve de caminho de volta.
///
/// Aparece sempre, mesmo sem plugin nenhum: no fim dela há um "+" apagado que
/// abre o [showInstallPlugin]. Sem ele, a faixa de quem não instalou nada seria
/// um ícone solitário das sessões, uma coluna que não troca nada.
class SidebarRail extends StatelessWidget {
  const SidebarRail({super.key, required this.store});
  final AppStore store;

  /// A largura do alvo. O [Mx.gap] à direita é o vão até o cartão.
  static const width = 36.0;

  @override
  Widget build(BuildContext context) {
    final shown = store.sidebarHidden ? null : (store.shownPlugin?.id ?? '');
    final waiting = store.waitingSessions;
    final toggleKeys = store.keymap[MxAction.toggleSidebar].map((c) => c.label);
    String tip(String label, bool current) =>
        current ? ['esconder a lateral', ...toggleKeys].join('  ') : label;

    return Padding(
      padding: const EdgeInsets.only(right: Mx.gap),
      child: SizedBox(
        width: width,
        child: Column(
          spacing: 4,
          children: [
            _RailIcon(
              selected: shown == '',
              tooltip: tip(
                waiting.isEmpty ? 'sessões' : 'sessões — ${waiting.length} esperando por você',
                shown == '',
              ),
              // Com a lista das sessões fora da tela, é este selo que diz que
              // uma delas quer você. Sem ele, a aba de um plugin esconderia
              // justamente o que a janela existe pra mostrar.
              badge: shown == '' || waiting.isEmpty
                  ? null
                  : _RailBadge(text: '${waiting.length}', color: waiting.first.status.color),
              onTap: () => store.showSidebarView(null),
              // Painéis em grade, e não a marca do claude: a lista é de tudo
              // que a janela tem aberto -- terminais, leitores, programas --, e
              // a rajada dizia que era só das sessões dele.
              builder: (color) => Icon(Icons.space_dashboard_outlined, size: 18, color: color),
            ),
            for (final p in store.railPlugins) _pluginIcon(p, shown, tip),
            // Um convite, não uma aba: nunca fica aceso, e em repouso é mais
            // apagado que os ícones de verdade -- quem já tem os plugins que
            // quer não precisa de um "+" disputando o olho com eles.
            _RailIcon(
              selected: false,
              faint: true,
              tooltip: 'instalar plugin',
              onTap: () => showInstallPlugin(context, store),
              builder: (color) => Icon(Icons.add, size: 16, color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pluginIcon(MxPlugin p, String? shown, String Function(String, bool) tip) {
    final current = shown == p.id;
    final open = store.viewsOf(p).length + store.ownedBy(p).length;
    final busy = store.plugins.busy.any((id) => id.startsWith('${p.id}/'));
    final said = store.sidebarBadges[p.id];
    return _RailIcon(
      selected: current,
      tooltip: tip(
        open == 0 ? p.name : '${p.name} — $open ${open == 1 ? 'janela aberta' : 'janelas abertas'}',
        current,
      ),
      // As janelas abertas, em cinza: é contagem, não alarme. E o ponto de
      // "rodando" quando algum comando do plugin está em curso -- o relatório,
      // um build --, que é o que a aba fechada não teria como contar.
      //
      // O selo que o plugin pediu vem na frente da contagem: ele sabe o que
      // importa nele (três arquivos mudados) melhor que a janela.
      badge: busy
          ? _RailBadge(color: Mx.accent)
          : said != null
          ? _RailBadge(text: said, color: Mx.bgActive, textColor: Mx.fg)
          : open > 0 && !current
          ? _RailBadge(text: '$open', color: Mx.bgActive, textColor: Mx.fgDim)
          : null,
      onTap: () => store.showSidebarView(p.id),
      builder: (color) => PluginGlyph(icon: p.manifest?.icon, dir: p.dir, size: 18, color: color),
    );
  }
}

class _RailIcon extends StatefulWidget {
  const _RailIcon({
    required this.selected,
    required this.tooltip,
    required this.onTap,
    required this.builder,
    this.badge,
    this.faint = false,
  });

  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final Widget Function(Color color) builder;
  final Widget? badge;

  /// Mais apagado em repouso, e só o cinza do texto no hover: é o "+" do fim.
  final bool faint;

  @override
  State<_RailIcon> createState() => _RailIconState();
}

class _RailIconState extends State<_RailIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.selected || _hover;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: SidebarRail.width,
            height: SidebarRail.width,
            decoration: BoxDecoration(
              // A aba na tela é um cartão pequeno da cor da lateral: o ícone
              // e o cartão grande ao lado leem como a mesma coisa.
              color: widget.selected ? Mx.bgSidebar : (_hover ? Mx.bgHover : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: widget.selected ? Mx.border : Colors.transparent),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: widget.builder(
                    widget.faint
                        ? (_hover ? Mx.fgDim : Mx.fgFaint.withValues(alpha: 0.55))
                        : (lit ? Mx.fg : Mx.fgFaint),
                  ),
                ),
                if (widget.badge case final b?) Positioned(right: 1, bottom: 1, child: b),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O selo no canto de um ícone da faixa: um número, ou só um ponto.
class _RailBadge extends StatelessWidget {
  const _RailBadge({this.text, required this.color, this.textColor});
  final String? text;
  final Color color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    if (text == null) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Mx.canvas, width: 1.5),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 14),
      height: 14,
      padding: const EdgeInsets.symmetric(horizontal: 3.5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Mx.canvas, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        text!,
        style: TextStyle(
          fontSize: 8.5,
          height: 1,
          fontWeight: FontWeight.w700,
          color: textColor ?? (color.computeLuminance() > 0.5 ? Mx.canvas : Colors.white),
        ),
      ),
    );
  }
}
