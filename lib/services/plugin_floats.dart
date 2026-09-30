import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import 'plugins.dart';
import 'store.dart';

/// O canto a que um flutuante está preso. Ver [FloatSpot].
enum FloatCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get right => this == topRight || this == bottomRight;
  bool get bottom => this == bottomLeft || this == bottomRight;

  static FloatCorner of({required bool right, required bool bottom}) => switch ((right, bottom)) {
    (false, false) => topLeft,
    (true, false) => topRight,
    (false, true) => bottomLeft,
    (true, true) => bottomRight,
  };

  static FloatCorner? parse(Object? raw) => values.firstWhereOrNull((c) => c.name == raw);
}

/// Onde um flutuante mora: o canto mais perto dele e a distância até as duas
/// bordas daquele canto.
///
/// Preso ao canto, e não ao topo-esquerdo da janela, porque a janela muda de
/// tamanho: o pomodoro que você largou embaixo à direita continua embaixo à
/// direita quando ela encolhe, em vez de sumir do lado de fora.
typedef FloatSpot = ({FloatCorner corner, double dx, double dy});

/// Um painel pequeno de plugin que flutua por cima da janela inteira, e não
/// um pedaço da grade: o pomodoro, um cronômetro, um "gravando".
///
/// A mesma interface das janelas -- um [PluginView] com `rfw` ou blocos --
/// num [MxTab] fora de [AppStore.tabs], como a aba da lateral. Quem arrasta e
/// guarda o lugar é a janela; o plugin só diz o tamanho e o que vai dentro.
class PluginFloat {
  PluginFloat({required this.tab, required this.width, required this.height, required this.start});

  final MxTab tab;
  double width;
  double height;

  /// O canto do primeiro `float.show`, até você arrastar.
  FloatCorner start;

  PluginView get view => tab.view!;
  String get pluginId => view.pluginId;
  String get id => view.id;
  String get key => '$pluginId/$id';

  static const minWidth = 80.0, maxWidth = 480.0;
  static const minHeight = 32.0, maxHeight = 320.0;
}

/// Os flutuantes na tela e o lugar de cada um.
///
/// Um [ChangeNotifier] à parte do [AppStore] de propósito: o pomodoro troca
/// o número uma vez por segundo, e cada troca repintaria o app inteiro. Aqui
/// só a camada dos flutuantes escuta.
class PluginFloats extends ChangeNotifier {
  PluginFloats({required this.onMoved});

  /// Chamado quando você larga um flutuante noutro lugar: é a deixa pro
  /// config ser gravado.
  final VoidCallback onMoved;

  final Map<String, PluginFloat> _shown = {};

  /// Os lugares, por `plugin/id`. Ficam mesmo com o flutuante escondido --
  /// o pomodoro que volta amanhã volta onde estava.
  final Map<String, FloatSpot> spots = {};

  Iterable<PluginFloat> get shown => _shown.values;

  PluginFloat? of(MxPlugin plugin, String id) => _shown['${plugin.id}/$id'];

  /// Mostra (ou troca) o flutuante [id] de [plugin].
  PluginFloat show(
    MxPlugin plugin,
    String id, {
    double? width,
    double? height,
    FloatCorner? corner,
    List<Map<String, dynamic>>? blocks,
    PluginRfwUpdate? rfw,
  }) {
    final float = _shown.putIfAbsent(
      '${plugin.id}/$id',
      () => PluginFloat(
        tab: MxTab(
          id: 'float:${plugin.id}/$id',
          folder: Folder.loose('/'),
          kind: TabKind.plugin,
          cwd: '/',
          branch: '',
          view: PluginView(
            pluginId: plugin.id,
            pluginName: plugin.name,
            id: id,
            title: plugin.name,
            blocks: const [],
          ),
        ),
        width: 200,
        height: 64,
        start: FloatCorner.bottomRight,
      ),
    );
    _apply(float, width: width, height: height, blocks: blocks, rfw: rfw);
    if (corner != null) float.start = corner;
    notifyListeners();
    return float;
  }

  /// Troca o conteúdo (e o tamanho) de um flutuante na tela. Diz se ele
  /// estava na tela.
  bool update(
    MxPlugin plugin,
    String id, {
    double? width,
    double? height,
    List<Map<String, dynamic>>? blocks,
    PluginRfwUpdate? rfw,
  }) {
    final float = of(plugin, id);
    if (float == null) return false;
    _apply(float, width: width, height: height, blocks: blocks, rfw: rfw);
    notifyListeners();
    return true;
  }

  void hide(MxPlugin plugin, String id) {
    if (_shown.remove('${plugin.id}/$id') != null) notifyListeners();
  }

  /// Tira os flutuantes de um plugin desligado, desinstalado ou trocado por
  /// outra versão: não há mais ninguém do outro lado pra atender um clique.
  void dropPlugin(String pluginId) {
    final before = _shown.length;
    _shown.removeWhere((_, f) => f.pluginId == pluginId);
    if (_shown.length != before) notifyListeners();
  }

  /// Onde [float] mora, ou null antes do primeiro arraste (a camada põe no
  /// canto de [PluginFloat.start]).
  FloatSpot? spotOf(PluginFloat float) => spots[float.key];

  void move(PluginFloat float, FloatSpot spot) {
    spots[float.key] = spot;
    notifyListeners();
    onMoved();
  }

  static void _apply(
    PluginFloat float, {
    double? width,
    double? height,
    List<Map<String, dynamic>>? blocks,
    PluginRfwUpdate? rfw,
  }) {
    if (width != null) float.width = width.clamp(PluginFloat.minWidth, PluginFloat.maxWidth);
    if (height != null) float.height = height.clamp(PluginFloat.minHeight, PluginFloat.maxHeight);
    if (rfw != null) float.view.setRfw(library: rfw.library, root: rfw.root, data: rfw.data);
    if (blocks != null) {
      float.view
        ..rfwLibrary = null
        ..setBlocks(blocks);
    }
  }

  // --- config --------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    for (final e in spots.entries)
      e.key: {
        'corner': e.value.corner.name,
        'dx': e.value.dx.roundToDouble(),
        'dy': e.value.dy.roundToDouble(),
      },
  };

  void readJson(Object? raw) {
    spots.clear();
    if (raw is! Map) return;
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final corner = FloatCorner.parse(v['corner']);
      final dx = v['dx'], dy = v['dy'];
      if (corner == null || dx is! num || dy is! num) continue;
      spots['${e.key}'] = (corner: corner, dx: dx.toDouble(), dy: dy.toDouble());
    }
  }
}
