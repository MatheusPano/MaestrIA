import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/store.dart';
import '../theme.dart';
import 'panel.dart';
import 'plugin_pane.dart';

/// A janela de plugin em modal (`view.open` com `modal: true`): por cima da
/// tela, com o fundo escurecido, até você fechar (o x, o esc ou o clique fora)
/// ou mandá-la pra grade ("abrir como painel"). O conteúdo é o de uma janela
/// qualquer -- o [PluginPane] sem a moldura de painel. Ver [AppStore.pluginModal].
class PluginModalLayer extends StatelessWidget {
  const PluginModalLayer({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tab = store.pluginModal;
        if (tab == null) return const SizedBox.shrink();
        return _Modal(key: ValueKey(tab.id), store: store, tab: tab);
      },
    );
  }
}

class _Modal extends StatelessWidget {
  const _Modal({super.key, required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  @override
  Widget build(BuildContext context) {
    final plugin = store.plugins.byId(tab.view!.pluginId);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): store.closeModal},
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: store.closeModal,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 140),
                    builder: (context, t, _) =>
                        ColoredBox(color: Colors.black.withValues(alpha: 0.42 * t)),
                  ),
                ),
              ),
              Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.scale(scale: 0.97 + 0.03 * t, child: child),
                  ),
                  child: Container(
                    width: (box.maxWidth - 48).clamp(320.0, 820.0),
                    height: (box.maxHeight - 48).clamp(240.0, box.maxHeight * 0.88),
                    decoration: BoxDecoration(
                      color: Mx.bg,
                      borderRadius: BorderRadius.circular(Mx.radius + 4),
                      border: Border.all(color: Mx.border),
                      boxShadow: const [
                        BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 16)),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Column(
                        children: [
                          Container(
                            height: 44,
                            padding: const EdgeInsets.only(left: 14, right: 8),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: Mx.border)),
                            ),
                            child: Row(
                              children: [
                                PluginGlyph(
                                  icon: plugin?.manifest?.icon,
                                  dir: plugin?.dir,
                                  size: 17,
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: Text(
                                    tab.title,
                                    overflow: TextOverflow.ellipsis,
                                    style: paneTitleStyle.copyWith(color: Mx.fg),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    tab.subtitle,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: Mx.fgDim, fontSize: 12),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: store.dockModal,
                                  style: TextButton.styleFrom(
                                    foregroundColor: Mx.fgDim,
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    minimumSize: const Size(0, 30),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: const Icon(Icons.vertical_split_outlined, size: 15),
                                  label: const Text(
                                    'abrir como painel',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                IconButton(
                                  tooltip: 'fechar (esc)',
                                  iconSize: 15,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                                  style: const ButtonStyle(
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: store.closeModal,
                                  icon: Icon(Icons.close, color: Mx.fgDim),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: PluginPane(store: store, tab: tab, framed: false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
