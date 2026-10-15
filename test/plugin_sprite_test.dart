import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/ui/plugin_sprite.dart';

/// O `Sprite` de `import maestria;`: a folha de sprites que a janela anima
/// sozinha. Ver `ui/plugin_sprite.dart`.
void main() {
  group('spriteFrame', () {
    test('vira os quadros no ritmo do fps e dá a volta', () {
      int at(int ms) => spriteFrame(Duration(milliseconds: ms), fps: 4, frames: 4);
      expect([at(0), at(249), at(250), at(500), at(750), at(1000), at(1250)], [0, 0, 1, 2, 3, 0, 1]);
    });

    test('sem loop, para no último', () {
      final f = spriteFrame(const Duration(seconds: 9), fps: 4, frames: 3, loop: false);
      expect(f, 2);
    });

    test('um quadro só, ou parado, é sempre o primeiro', () {
      expect(spriteFrame(const Duration(seconds: 3), fps: 8, frames: 1), 0);
      expect(spriteFrame(const Duration(seconds: 3), fps: 0, frames: 4), 0);
    });
  });

  group('pluginFileOf', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('sprite');
      File('${dir.path}/a.png').writeAsBytesSync([0]);
      File('${dir.path}-irmao.png').writeAsBytesSync([0]);
    });
    tearDown(() {
      dir.deleteSync(recursive: true);
      File('${dir.path}-irmao.png').deleteSync();
    });

    test('lê de dentro da pasta do plugin', () {
      expect(pluginFileOf('a.png', dir.path)?.path, endsWith('/a.png'));
    });

    test('não sai dela, nem pra uma pasta irmã de nome parecido', () {
      expect(pluginFileOf('../a.png', dir.path), isNull);
      expect(pluginFileOf('/etc/hosts', dir.path), isNull);
      expect(pluginFileOf('', dir.path), isNull);
      expect(pluginFileOf('nao-existe.png', dir.path), isNull);
      expect(pluginFileOf('a.png', null), isNull);
    });
  });

  testWidgets('anima sozinho e recomeça quando a animação muda', (tester) async {
    Widget sprite({int row = 0, bool paused = false}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: PluginSprite(
          file: null,
          columns: 4,
          rows: 2,
          row: row,
          frames: 4,
          fps: 10,
          width: 16,
          height: 24,
          paused: paused,
        ),
      ),
    );
    PluginSpriteState state() => tester.state(find.byType(PluginSprite));

    await tester.pumpWidget(sprite());
    expect(state().frame, 0);
    expect(tester.getSize(find.byType(PluginSprite)), const Size(16, 24));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 250));
    expect(state().frame, 2);

    // O mesmo boneco com os dados de novo segue de onde estava.
    await tester.pumpWidget(sprite());
    expect(state().frame, 2);

    // Outra linha da folha começa do primeiro quadro.
    await tester.pumpWidget(sprite(row: 1));
    expect(state().frame, 0);

    await tester.pumpWidget(sprite(row: 1, paused: true));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state().frame, 0);
  });
}
