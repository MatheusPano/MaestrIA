import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:rfw/rfw.dart';

/// O `Sprite` de `import maestria;`: um quadro de uma folha de sprites (um
/// `.png` da pasta do plugin), animado aqui na janela.
///
/// O rfw só anima o que muda de valor: o `Positioned` vai de um lugar pro outro
/// sozinho, mas trocar o desenho a cada quadro seria o plugin mandando dados
/// seis vezes por segundo, por boneco, pelo stdin. Com o `Sprite` o plugin diz
/// qual animação (a linha da folha, quantos quadros, a que velocidade) e a
/// janela vira os quadros no ritmo da tela; o plugin só fala de novo quando o
/// boneco muda de animação.
///
/// ```
/// Sprite(
///   sheet: "sprites/claude.png", columns: 4, rows: 6,
///   row: 2, start: 0, frames: 4, fps: 8.0,
///   width: 16.0, height: 24.0, flip: false, paused: false, loop: true,
/// )
/// ```
///
/// A folha é uma grade de `columns` × `rows` quadros do mesmo tamanho. A
/// animação é a linha `row`, do quadro `start` até `start + frames - 1`. O
/// desenho sai sem suavizar (pixel art continua pixel em qualquer escala), e
/// `flip` o espelha -- a caminhada pra esquerda é a da direita ao contrário.
/// Os números podem vir dos dados como inteiros: o json não diz `8.0`.
Widget buildPluginSprite(String? dir, DataSource source) {
  double? n(String k) => source.v<double>([k]) ?? source.v<int>([k])?.toDouble();
  int? i(String k) => source.v<int>([k]) ?? source.v<double>([k])?.round();
  return PluginSprite(
    file: pluginFileOf(source.v<String>(['sheet']), dir),
    columns: i('columns') ?? 1,
    rows: i('rows') ?? 1,
    row: i('row') ?? 0,
    start: i('start') ?? 0,
    frames: i('frames') ?? 1,
    fps: n('fps') ?? 6,
    width: n('width'),
    height: n('height'),
    flip: source.v<bool>(['flip']) == true,
    paused: source.v<bool>(['paused']) == true,
    loop: source.v<bool>(['loop']) ?? true,
  );
}

/// O arquivo [rel] de dentro da pasta do plugin, ou `null` se ele sair dela (um
/// `../`) ou não existir.
File? pluginFileOf(String? rel, String? dir) {
  if (rel == null || rel.isEmpty || dir == null || rel.contains('..')) return null;
  final root = Directory(dir).absolute.path;
  final file = File('$root/$rel').absolute;
  if (!file.path.startsWith('$root/')) return null;
  return file.existsSync() ? file : null;
}

/// O quadro da animação em [elapsed]: dá a volta com [loop], e para no último
/// sem ele.
@visibleForTesting
int spriteFrame(Duration elapsed, {required double fps, required int frames, bool loop = true}) {
  if (frames <= 1 || fps <= 0) return 0;
  final n = (elapsed.inMicroseconds * fps / Duration.microsecondsPerSecond).floor();
  return loop ? n % frames : n.clamp(0, frames - 1);
}

class PluginSprite extends StatefulWidget {
  const PluginSprite({
    super.key,
    required this.file,
    this.columns = 1,
    this.rows = 1,
    this.row = 0,
    this.start = 0,
    this.frames = 1,
    this.fps = 6,
    this.width,
    this.height,
    this.flip = false,
    this.paused = false,
    this.loop = true,
  });

  final File? file;
  final int columns;
  final int rows;
  final int row;
  final int start;
  final int frames;
  final double fps;
  final double? width;
  final double? height;
  final bool flip;
  final bool paused;
  final bool loop;

  @override
  State<PluginSprite> createState() => PluginSpriteState();
}

class PluginSpriteState extends State<PluginSprite> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  ImageStream? _stream;
  ImageInfo? _image;
  late final ImageStreamListener _listener = ImageStreamListener(
    _loaded,
    onError: (_, _) {},
  );

  int _frame = 0;

  /// O quadro na tela, contando do `start`.
  @visibleForTesting
  int get frame => _frame;

  bool get _animates => !widget.paused && widget.frames > 1 && widget.fps > 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PluginSprite oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.file?.path != widget.file?.path) _resolve();
    // Outra animação começa do primeiro quadro; a mesma, com os dados de novo
    // (o boneco andou), segue de onde estava.
    if (old.row != widget.row ||
        old.start != widget.start ||
        old.frames != widget.frames ||
        old.fps != widget.fps ||
        old.paused != widget.paused ||
        old.loop != widget.loop) {
      _restart();
    }
  }

  void _restart() {
    _ticker.stop();
    _frame = 0;
    if (_animates) _ticker.start();
  }

  void _tick(Duration elapsed) {
    final f = spriteFrame(elapsed, fps: widget.fps, frames: widget.frames, loop: widget.loop);
    if (f != _frame) setState(() => _frame = f);
    if (!widget.loop && f == widget.frames - 1) _ticker.stop();
  }

  void _resolve() {
    final file = widget.file;
    if (file == null) {
      _stream?.removeListener(_listener);
      _stream = null;
      return;
    }
    final stream = FileImage(file).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _loaded(ImageInfo info, bool _) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = info;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _stream?.removeListener(_listener);
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image?.image;
    final cols = widget.columns < 1 ? 1 : widget.columns;
    final rows = widget.rows < 1 ? 1 : widget.rows;
    final cell = image == null
        ? null
        : Size(image.width / cols, image.height / rows);
    final width = widget.width ?? cell?.width ?? 0;
    final height = widget.height ?? cell?.height ?? 0;
    if (image == null || cell == null) return SizedBox(width: width, height: height);
    final col = (widget.start + _frame).clamp(0, cols - 1);
    final row = widget.row.clamp(0, rows - 1);
    // Numa camada só dele: trocar de quadro (seis, oito vezes por segundo, por
    // boneco) repinta o boneco, e não a cena em volta.
    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _SpritePainter(
            image: image,
            source: Rect.fromLTWH(col * cell.width, row * cell.height, cell.width, cell.height),
            flip: widget.flip,
          ),
        ),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  const _SpritePainter({required this.image, required this.source, required this.flip});

  final ui.Image image;
  final Rect source;
  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    if (flip) {
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    canvas.drawImageRect(
      image,
      source,
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.image != image || old.source != source || old.flip != flip;
}
