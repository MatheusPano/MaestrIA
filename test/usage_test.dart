import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/usage.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/settings.dart';
import 'package:maestria/ui/sidebar.dart';

/// A resposta de verdade do endpoint, cortada no que esta tela lê.
///
/// Os campos soltos (`five_hour`, `seven_day`, ...) que vêm ao lado da
/// `limits` ficaram de fora de propósito: [Usage.parse] não os lê, e mantê-los
/// aqui faria o teste passar por um caminho que o app não usa.
const _resposta = '''
{
  "limits": [
    {"kind": "session", "group": "session", "percent": 3, "severity": "normal",
     "resets_at": "2026-09-10T16:09:59.634925+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all", "group": "weekly", "percent": 18, "severity": "normal",
     "resets_at": "2026-09-13T19:59:59.634945+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 14, "severity": "normal",
     "resets_at": "2026-09-13T19:59:59.635165+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
     "is_active": false}
  ],
  "spend": {"used": {"amount_minor": 0, "currency": "BRL", "exponent": 2},
            "limit": null, "percent": 0, "enabled": false}
}
''';

void main() {
  group('Usage.parse', () {
    test('as três janelas do plano, na ordem em que a api as manda', () {
      final reading = Usage.parse(_resposta);

      expect(reading.ok, isTrue, reason: reading.problem);
      expect(
        reading.windows.map((w) => w.label),
        ['sessão (5h)', 'semanal (7 dias)', 'semanal Fable'],
      );
      expect(reading.windows.map((w) => w.percent), [3, 18, 14]);
    });

    // O nome do modelo é a única coisa que separa esta barra da semanal comum;
    // sem ele são duas linhas "semanal" e quem lê não sabe qual é qual.
    test('a janela por modelo se chama pelo modelo', () {
      final fable = Usage.parse(_resposta).windows.last;

      expect(fable.label, 'semanal Fable');
    });

    test('o reset vira data, e é a mesma instante que veio', () {
      final session = Usage.parse(_resposta).windows.first;

      expect(session.resetsAt, isNotNull);
      expect(
        session.resetsAt!.toUtc(),
        DateTime.utc(2026, 9, 10, 16, 9, 59, 634, 925),
      );
    });

    // O caso que motivou ler a `limits` em vez dos campos soltos: uma janela
    // nova aparece com o nome cru em vez de sumir da conta de quem lê.
    test('uma janela desconhecida entra mesmo assim', () {
      final reading = Usage.parse('''
        {"limits": [{"kind": "monthly_whatever", "percent": 7, "resets_at": null}]}
      ''');

      expect(reading.ok, isTrue);
      expect(reading.windows.single.label, 'monthly whatever');
      expect(reading.windows.single.percent, 7);
      expect(reading.windows.single.resetsAt, isNull);
    });

    test('uma janela sem percentual não vira barra nenhuma', () {
      final reading = Usage.parse('''
        {"limits": [{"kind": "session", "percent": null},
                    {"kind": "weekly_all", "percent": 18}]}
      ''');

      expect(reading.windows.map((w) => w.percent), [18]);
    });

    test('passar de 100 é um número, não um erro', () {
      final reading = Usage.parse('{"limits": [{"kind": "session", "percent": 104}]}');

      expect(reading.windows.single.percent, 104);
    });

    group('não deu', () {
      test('resposta que não é json', () {
        final reading = Usage.parse('<html>502 bad gateway</html>');

        expect(reading.ok, isFalse);
        expect(reading.windows, isEmpty);
        expect(reading.problem, contains('json'));
      });

      test('json sem a lista de limites', () {
        expect(Usage.parse('{"spend": {}}').ok, isFalse);
      });

      // Uma lista vazia é uma resposta bem formada que não diz nada -- e uma
      // seção com zero barras e nenhuma explicação parece um bug daqui.
      test('lista de limites vazia', () {
        expect(Usage.parse('{"limits": []}').ok, isFalse);
      });
    });

    group('créditos extras', () {
      test('desligados não viram linha', () {
        expect(Usage.parse(_resposta).credits, isNull);
      });

      test('ligados dizem quanto foi de quanto', () {
        final reading = Usage.parse('''
          {"limits": [{"kind": "session", "percent": 3}],
           "spend": {"enabled": true,
                     "used": {"amount_minor": 1234, "currency": "BRL", "exponent": 2},
                     "limit": {"amount_minor": 50000, "currency": "BRL", "exponent": 2}}}
        ''');

        expect(reading.credits, 'créditos extras: BRL 12,34 de BRL 500,00');
      });

      test('ligados sem teto dizem só o quanto', () {
        final reading = Usage.parse('''
          {"limits": [{"kind": "session", "percent": 3}],
           "spend": {"enabled": true, "limit": null,
                     "used": {"amount_minor": 1234, "currency": "BRL", "exponent": 2}}}
        ''');

        expect(reading.credits, 'créditos extras: BRL 12,34');
      });

      // O expoente vem na resposta porque nem toda moeda tem duas casas.
      test('uma moeda sem centavos não ganha centavos', () {
        final reading = Usage.parse('''
          {"limits": [{"kind": "session", "percent": 3}],
           "spend": {"enabled": true, "limit": null,
                     "used": {"amount_minor": 900, "currency": "JPY", "exponent": 0}}}
        ''');

        expect(reading.credits, 'créditos extras: JPY 900');
      });
    });
  });

  group('shortUntil', () {
    final agora = DateTime(2026, 9, 10, 13, 0);

    test('as unidades, na régua do shortAgo', () {
      expect(shortUntil(agora.add(const Duration(minutes: 40)), now: agora), '40min');
      expect(shortUntil(agora.add(const Duration(hours: 2)), now: agora), '2h');
      expect(shortUntil(agora.add(const Duration(days: 3)), now: agora), '3d');
    });

    // A diferença que justifica a função existir em vez de um shortAgo
    // invertido: "agora" num medidor convida a mandar o prompt que vai bater
    // no teto, e a janela ainda não zerou.
    test('quase zerando não é "agora"', () {
      expect(shortUntil(agora.add(const Duration(seconds: 40)), now: agora), '<1min');
    });

    test('uma data que já passou é agora', () {
      expect(shortUntil(agora.subtract(const Duration(minutes: 5)), now: agora), 'agora');
    });

    test('passada uma semana, a data diz mais que a contagem', () {
      expect(shortUntil(DateTime(2026, 9, 30, 13), now: agora), '30/9');
    });
  });

  group('a seção conta & uso', () {
    // A leitura de verdade sai de cena: ela iria à rede, e antes disso à
    // credencial de quem está rodando a suíte. Ver [Usage.reader].
    tearDown(Usage.resetReader);

    /// A tela aberta já na seção nova, com a leitura que o teste quiser.
    Future<AppStore> pumpAccount(WidgetTester tester, UsageReading reading) async {
      Usage.reader = () async => reading;
      final store = AppStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: Mx.theme(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showSettings(ctx, store, section: MxSection.account),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      return store;
    }

    Future<void> closeWindow(WidgetTester tester, AppStore store) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
    }

    testWidgets('desenha uma barra por janela, com o número ao lado', (tester) async {
      final store = await pumpAccount(tester, Usage.parse(_resposta));

      expect(find.text('sessão (5h)'), findsOneWidget);
      expect(find.text('3%'), findsOneWidget);
      expect(find.text('semanal (7 dias)'), findsOneWidget);
      expect(find.text('18%'), findsOneWidget);
      expect(find.text('semanal Fable'), findsOneWidget);
      expect(find.text('14%'), findsOneWidget);

      await closeWindow(tester, store);
    });

    testWidgets('o reset de cada janela vira quanto falta', (tester) async {
      final store = await pumpAccount(
        tester,
        UsageReading.ok([
          UsageWindow(
            label: 'sessão (5h)',
            percent: 3,
            resetsAt: DateTime.now().add(const Duration(hours: 2, minutes: 10)),
          ),
        ]),
      );

      expect(find.text('reseta em 2h'), findsOneWidget);

      await closeWindow(tester, store);
    });

    // Uma janela sem data continua valendo pelo número: o que não pode é a
    // linha sumir por falta de um campo que é opcional na resposta.
    testWidgets('uma janela sem reset ainda desenha a barra', (tester) async {
      final store = await pumpAccount(
        tester,
        const UsageReading.ok([UsageWindow(label: 'sessão (5h)', percent: 3)]),
      );

      expect(find.text('sessão (5h)'), findsOneWidget);
      expect(find.textContaining('reseta'), findsNothing);

      await closeWindow(tester, store);
    });

    testWidgets('a conta aparece acima das barras quando o config a tem', (tester) async {
      final store = await pumpAccount(
        tester,
        const UsageReading.ok(
          [UsageWindow(label: 'sessão (5h)', percent: 3)],
          account: UsageAccount(
            email: 'alguem@exemplo.com',
            organization: 'Marrow',
            plan: 'Claude team',
          ),
        ),
      );

      expect(find.text('Marrow · Claude team'), findsOneWidget);
      expect(find.text('alguem@exemplo.com'), findsOneWidget);

      await closeWindow(tester, store);
    });

    testWidgets('sem conta no config, só as barras', (tester) async {
      final store = await pumpAccount(
        tester,
        const UsageReading.ok([UsageWindow(label: 'sessão (5h)', percent: 3)]),
      );

      expect(find.text('sessão (5h)'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);

      await closeWindow(tester, store);
    });

    // O caso que a tela existe pra não fazer: sumir em branco quando a
    // leitura não deu.
    testWidgets('o motivo de não ter dado é o que fica na tela', (tester) async {
      final store = await pumpAccount(
        tester,
        const UsageReading.failed('a credencial venceu'),
      );

      expect(find.text('a credencial venceu'), findsOneWidget);

      await closeWindow(tester, store);
    });

    // O botão que existe porque esta é a única seção cuja resposta envelhece
    // sozinha: o número velho tem de poder virar o novo sem fechar a tela.
    testWidgets('recarregar pede a leitura de novo', (tester) async {
      final store = await pumpAccount(
        tester,
        const UsageReading.ok([UsageWindow(label: 'sessão (5h)', percent: 3)]),
      );
      expect(find.text('3%'), findsOneWidget);

      var vezes = 0;
      Usage.reader = () async {
        vezes++;
        return const UsageReading.ok([UsageWindow(label: 'sessão (5h)', percent: 9)]);
      };

      await tester.tap(find.byTooltip('ler de novo'));
      await tester.pumpAndSettle();

      expect(vezes, 1);
      expect(find.text('9%'), findsOneWidget);
      expect(find.text('3%'), findsNothing);

      await closeWindow(tester, store);
    });
  });

  // O atalho pro medidor: a seção mora no settings, e o pé da lateral é o
  // caminho de um clique até ela.
  group('o glifo do rodapé da lateral', () {
    tearDown(Usage.resetReader);

    Future<AppStore> pumpSidebar(WidgetTester tester) async {
      Usage.reader = () async =>
          const UsageReading.ok([UsageWindow(label: 'sessão (5h)', percent: 3)]);
      final store = AppStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: Mx.theme(),
          home: Scaffold(
            body: SizedBox(width: 360, height: 900, child: Sidebar(store: store)),
          ),
        ),
      );
      return store;
    }

    testWidgets('abre o settings já na seção de uso', (tester) async {
      final store = await pumpSidebar(tester);

      await tester.tap(find.byTooltip('conta & uso'));
      await tester.pumpAndSettle();

      // A barra é a prova de que caiu na seção certa: aberto no padrão, o
      // diálogo mostraria a aparência.
      expect(find.text('sessão (5h)'), findsOneWidget);
      expect(find.text('3%'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
    });

    // Os três da esquerda continuam sendo os três da esquerda: o vão entre
    // eles e o medidor é o que diz que ele não é o quarto da fileira.
    testWidgets('não desloca os glifos que já estavam lá', (tester) async {
      final store = await pumpSidebar(tester);

      final pasta = tester.getCenter(find.byTooltip('adicionar uma pasta ao cockpit'));
      final medidor = tester.getCenter(find.byTooltip('conta & uso'));

      expect(pasta.dx, lessThan(medidor.dx));
      expect(medidor.dx - pasta.dx, greaterThan(200));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
    });
  });
}
