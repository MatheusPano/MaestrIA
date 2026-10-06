import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/plugin_dialogs.dart';

MxPlugin ssh() => MxPlugin(
  dir: '/p',
  manifest: const PluginManifest(id: 'ssh', name: 'SSH', version: '1', main: ['node']),
);

void main() {
  group('o campo de texto rápido (window.input)', () {
    Future<Future<String?>> ask(WidgetTester tester, {String? value}) async {
      late Future<String?> answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => answer = showQuickInput(
                context,
                title: 'nome do grupo',
                placeholder: 'trabalho, pessoal…',
                value: value,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('o enter devolve o texto, sem os espaços das pontas', (tester) async {
      final answer = await ask(tester);
      expect(find.text('nome do grupo'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  AWS  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await answer, 'AWS');
    });

    testWidgets('vazio ou esc é null', (tester) async {
      var answer = await ask(tester);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await answer, isNull);

      answer = await ask(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(await answer, isNull);
    });

    testWidgets('o valor de antes vem todo selecionado, pronto pra trocar', (tester) async {
      await ask(tester, value: 'Staging');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Staging');
      expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 7));
    });

    test('a API repassa o pedido, e sem tela volta com erro', () async {
      final store = AppStore();
      final api = PluginApi(store);
      await expectLater(
        api.handle(ssh(), 'window.input', {'title': 'x'}),
        throwsA(isA<PluginRpcError>()),
      );

      Map<String, String?>? asked;
      store.quickInput = ({required title, placeholder, value, prompt}) async {
        asked = {'title': title, 'placeholder': placeholder, 'value': value, 'prompt': prompt};
        return 'AWS';
      };
      expect(await api.handle(ssh(), 'window.input', {'placeholder': 'nome', 'value': 'a'}), 'AWS');
      expect(asked, {'title': 'SSH', 'placeholder': 'nome', 'value': 'a', 'prompt': null});
      store.dispose();
    });
  });

  group('o formulário em modal (window.form)', () {
    PluginForm host({String? error}) => PluginForm.parse({
      'title': 'novo host',
      'error': ?error,
      'fields': [
        {'id': 'name', 'label': 'nome'},
        {'id': 'host', 'label': 'host', 'required': true},
        {'id': 'user', 'label': 'usuário', 'half': true},
        {'id': 'port', 'label': 'porta', 'half': true, 'value': 22},
        {
          'id': 'group',
          'type': 'select',
          'label': 'grupo',
          'value': 'AWS',
          'options': [
            {'value': '', 'label': 'sem grupo'},
            'AWS',
            {'value': '::novo', 'label': 'novo grupo…'},
          ],
        },
        {
          'id': 'newGroup',
          'label': 'nome do novo grupo',
          'required': true,
          'showIf': {'field': 'group', 'value': '::novo'},
        },
      ],
      'buttons': [
        {'action': 'apagar', 'label': 'apagar', 'style': 'danger'},
        {'action': 'conectar', 'label': 'salvar e conectar'},
        {'action': 'salvar', 'label': 'salvar', 'style': 'primary'},
      ],
    }, fallbackTitle: 'SSH');

    Future<Future<({String action, Map<String, String> values})?>> show(
      WidgetTester tester,
      PluginForm form,
    ) async {
      late Future<({String action, Map<String, String> values})?> answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => answer = showQuickForm(context, form),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return answer;
    }

    Finder field(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TextField));

    testWidgets('o obrigatório vazio segura o botão, e o enter salva', (tester) async {
      final answer = await show(tester, host());
      expect(find.text('novo host'), findsOneWidget);
      expect(find.text('nome do novo grupo'), findsNothing, reason: 'o showIf esconde');
      expect(
        tester.getCenter(field('usuário')).dy,
        tester.getCenter(field('porta')).dy,
        reason: 'meia largura: lado a lado',
      );

      await tester.tap(find.text('salvar'));
      await tester.pumpAndSettle();
      expect(find.text('falta host'), findsOneWidget, reason: 'o modal não fecha');

      await tester.enterText(field('host'), 'exemplo.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final got = await answer;
      expect(got!.action, 'salvar');
      expect(got.values, {
        'name': '',
        'host': 'exemplo.com',
        'user': '',
        'port': '22',
        'group': 'AWS',
        'newGroup': '',
      });
    });

    testWidgets('o select mostra o campo do showIf, que também é obrigatório', (tester) async {
      final answer = await show(tester, host());
      await tester.enterText(field('host'), 'exemplo.com');
      await tester.tap(find.text('AWS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('novo grupo…').last);
      await tester.pumpAndSettle();
      expect(find.text('nome do novo grupo'), findsOneWidget);

      await tester.tap(find.text('salvar e conectar'));
      await tester.pumpAndSettle();
      expect(find.text('falta nome do novo grupo'), findsOneWidget);
      await tester.enterText(field('nome do novo grupo'), 'Clientes');
      await tester.tap(find.text('salvar e conectar'));
      await tester.pumpAndSettle();
      final got = await answer;
      expect(got!.action, 'conectar');
      expect(got.values['group'], '::novo');
      expect(got.values['newGroup'], 'Clientes');
    });

    testWidgets('o perigoso passa sem o obrigatório; o erro aparece; cancelar é null', (
      tester,
    ) async {
      var answer = await show(tester, host(error: 'a porta é um número de 1 a 65535'));
      expect(find.text('a porta é um número de 1 a 65535'), findsOneWidget);
      await tester.tap(find.text('apagar'));
      await tester.pumpAndSettle();
      expect((await answer)!.action, 'apagar');

      answer = await show(tester, host());
      await tester.tap(find.text('cancelar'));
      await tester.pumpAndSettle();
      expect(await answer, isNull);
    });

    test('um pedido malformado volta com erro pro plugin', () async {
      final store = AppStore();
      store.quickForm = (form) async => (action: 'ok', values: const <String, String>{});
      final api = PluginApi(store);
      await expectLater(
        api.handle(ssh(), 'window.form', {'fields': []}),
        throwsA(isA<PluginRpcError>()),
      );
      await expectLater(
        api.handle(ssh(), 'window.form', {
          'fields': [
            {'id': 'a', 'type': 'data'},
          ],
        }),
        throwsA(isA<PluginRpcError>()),
      );
      expect(
        await api.handle(ssh(), 'window.form', {
          'fields': [
            {'id': 'a'},
          ],
        }),
        {'action': 'ok', 'values': <String, String>{}},
      );
      store.dispose();
    });
  });
}
