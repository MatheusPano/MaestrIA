import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/shortcuts.dart';

const _m4 = MxChord.mouse(kBackMouseButton);
const _m5 = MxChord.mouse(kForwardMouseButton);

void main() {
  group('a combinação de um botão', () {
    test('se escreve mouse4 no disco e volta igual', () {
      expect(_m4.id, 'mouse4');
      expect(_m5.id, 'mouse5');
      expect(MxChord.parse('mouse4'), _m4);
      const ctrlM5 = MxChord.mouse(kForwardMouseButton, control: true);
      expect(ctrlM5.id, 'ctrl+mouse5');
      expect(MxChord.parse('ctrl+mouse5'), ctrlM5);
    });

    test('não é a mesma coisa que tecla nenhuma', () {
      expect(_m4, isNot(MxChord.parse('4')));
      expect(_m4.activator, isNull);
    });

    test('um número que não é botão é descartado, não explode', () {
      for (final id in ['mouse', 'mouse0', 'mouse33', 'mouse04', 'mousex', 'hyper+mouse4']) {
        expect(MxChord.parse(id), isNull, reason: id);
      }
    });

    test('o esquerdo, o direito e o do meio são do terminal', () {
      for (final b in [kPrimaryMouseButton, kSecondaryMouseButton, kMiddleMouseButton]) {
        expect(MxChord.mouse(b).valid, isFalse);
        expect(MxChord.mouse(b, control: true).valid, isFalse);
      }
    });

    test('o de lado vale sem modificador: ele não escreve nada no terminal', () {
      expect(_m4.rejection, isNull);
      expect(_m5.rejection, isNull);
    });

    test('no Linux, do M6 em diante é recusado: o GTK não entrega', () {
      final was = MxChord.linux;
      addTearDown(() => MxChord.linux = was);
      const m6 = MxChord.mouse(kForwardMouseButton << 1);
      MxChord.linux = true;
      expect(m6.rejection, isNotNull);
      expect(_m5.rejection, isNull);
      MxChord.linux = false;
      expect(m6.rejection, isNull);
    });

    test('se lê como o número impresso no mouse', () {
      final was = MxChord.linux;
      addTearDown(() => MxChord.linux = was);
      MxChord.linux = true;
      expect(_m4.label, 'Mouse 4');
      expect(const MxChord.mouse(kBackMouseButton, control: true).label, 'Ctrl+Mouse 4');
    });
  });

  group('o mapa', () {
    test('grava o botão e o lê de volta', () {
      final keymap = MxKeymap()
        ..bind(MxAction.prevPane, _m4)
        ..bind(MxAction.nextPane, _m5);
      final json = keymap.toJson();
      expect(json[MxAction.prevPane.id], contains('mouse4'));

      final loaded = MxKeymap()..load(json);
      expect(loaded.owner(_m4), MxAction.prevPane);
      expect(loaded.owner(_m5), MxAction.nextPane);
      expect(loaded[MxAction.prevPane], MxAction.prevPane.defaults + [_m4]);
    });

    test('um config de antes, só com teclas, continua igual', () {
      final keymap = MxKeymap()
        ..load({
          MxAction.newClaude.id: ['meta+alt+t'],
        });
      expect(keymap[MxAction.newClaude], [
        const MxChord(LogicalKeyboardKey.keyT, meta: true, alt: true),
      ]);
      expect(keymap.isDefault(MxAction.nextPane), isTrue);
    });

    test('um clique esquerdo escrito à mão no arquivo é jogado fora', () {
      final keymap = MxKeymap()
        ..load({
          MxAction.prevPane.id: ['mouse1', 'mouse4'],
        });
      expect(keymap[MxAction.prevPane], [_m4]);
    });
  });


  test('um plugin que pede botão do mouse fica sem, com aviso', () {
    final m = PluginManifest.parse({
      'id': 'x',
      'version': '1',
      'contributes': {
        'commands': [
          {'id': 'c', 'title': 'c', 'run': 'ls', 'key': 'mouse4'},
        ],
      },
    });
    expect(m.commands.single.key, isNull);
    expect(m.warnings.single, contains('só usa teclado'));
  });
}
