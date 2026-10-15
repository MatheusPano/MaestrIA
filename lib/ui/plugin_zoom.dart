import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:rfw/rfw.dart';

/// O `ZoomView` de `import maestria;`: o conteúdo com zoom e arrasto, como um
/// mapa -- a bolinha do mouse aproxima e afasta em volta do cursor, arrastar
/// com o mouse move, e o trackpad rola com dois dedos e dá zoom na pinça.
///
/// ```
/// ZoomView(
///   maxScale: 6.0,
///   command: data.zoom.command, commandRev: data.zoom.rev,
///   onZoom: event "zoom" {},
///   child: FittedBox(fit: "contain", child: …),
/// )
/// ```
///
/// O `child` ocupa o tamanho do `ZoomView` (um `FittedBox` dentro faz caber),
/// e a escala 1 é ele inteiro na tela: não dá pra afastar além disso. O zoom
/// mora aqui na janela, sem ida e volta pelo plugin a cada giro da bolinha.
/// O plugin manda botões pelo `command` (`"in"`, `"out"` ou `"fit"`), que vale
/// cada vez que o `commandRev` muda, e fica sabendo a escala pelo `onZoom`
/// (com `scale` a mais nos argumentos) quando o zoom assenta.
Widget buildPluginZoomView(DataSource source) {
  double? n(String k) => source.v<double>([k]) ?? source.v<int>([k])?.toDouble();
  return PluginZoomView(
    maxScale: math.max(1, n('maxScale') ?? 6),
    command: source.v<String>(['command']),
    commandRev: source.v<int>(['commandRev']) ?? source.v<double>(['commandRev'])?.round() ?? 0,
    onZoom: source.handler<void Function(DynamicMap)>(
      ['onZoom'],
      (trigger) =>
          (extra) => trigger(extra),
    ),
    child: source.optionalChild(['child']) ?? const SizedBox.shrink(),
  );
}

class PluginZoomView extends StatefulWidget {
  const PluginZoomView({
    super.key,
    required this.child,
    this.maxScale = 6,
    this.command,
    this.commandRev = 0,
    this.onZoom,
  });

  final Widget child;
  final double maxScale;
  final String? command;
  final int commandRev;
  final void Function(DynamicMap)? onZoom;

  /// Quanto um clique no + (ou no −) aproxima (ou afasta).
  static const step = 1.5;

  @override
  State<PluginZoomView> createState() => _PluginZoomViewState();
}

class _PluginZoomViewState extends State<PluginZoomView> with SingleTickerProviderStateMixin {
  final _matrix = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_animate);
  Matrix4Tween? _tween;
  Size _size = Size.zero;
  Timer? _settle;
  double _reported = 1;

  @override
  void initState() {
    super.initState();
    _matrix.addListener(_changed);
  }

  @override
  void didUpdateWidget(PluginZoomView old) {
    super.didUpdateWidget(old);
    if (widget.commandRev != old.commandRev) _run(widget.command);
  }

  @override
  void dispose() {
    _settle?.cancel();
    _anim.dispose();
    _matrix.dispose();
    super.dispose();
  }

  double get _scale => _matrix.value.getMaxScaleOnAxis();

  /// O botão do plugin: aproxima ou afasta em volta do meio da janela, ou volta a caber.
  void _run(String? command) {
    final target = switch (command) {
      'in' => _scale * PluginZoomView.step,
      'out' => _scale / PluginZoomView.step,
      'fit' => 1.0,
      _ => null,
    };
    if (target == null) return;
    final to = target.clamp(1.0, widget.maxScale);
    final center = Offset(_size.width / 2, _size.height / 2);
    // O ponto do conteúdo que está no meio da janela continua no meio.
    final focal = _matrix.toScene(center);
    final next = to <= 1.0001
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(center.dx - focal.dx * to, center.dy - focal.dy * to, 0, 1)
            ..scaleByDouble(to, to, 1, 1));
    _tween = Matrix4Tween(begin: _matrix.value.clone(), end: _clamp(next, to));
    _anim.forward(from: 0);
  }

  /// [m] sem deixar aparecer nada além das bordas do conteúdo.
  Matrix4 _clamp(Matrix4 m, double scale) {
    final t = m.getTranslation();
    final minX = _size.width - _size.width * scale;
    final minY = _size.height - _size.height * scale;
    final x = t.x.clamp(math.min(minX, 0.0), 0.0).toDouble();
    final y = t.y.clamp(math.min(minY, 0.0), 0.0).toDouble();
    return Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _animate() {
    final tween = _tween;
    if (tween == null) return;
    _matrix.value = tween.transform(Curves.easeOutCubic.transform(_anim.value));
  }

  /// O zoom mudou: avisa o plugin quando parar de mexer.
  void _changed() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 200), () {
      final s = _scale;
      if (!mounted || (s - _reported).abs() < 0.005) return;
      _reported = s;
      widget.onZoom?.call(<String, Object?>{'scale': s});
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return InteractiveViewer(
          transformationController: _matrix,
          minScale: 1,
          maxScale: widget.maxScale,
          // Um giro da bolinha mexe uns 10% no zoom.
          scaleFactor: 200,
          onInteractionStart: (_) => _anim.stop(),
          child: SizedBox.fromSize(size: _size, child: widget.child),
        );
      },
    );
  }
}
