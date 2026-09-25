import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/services/plugin_api.dart';
import 'package:maestria/ui/plugin_dialogs.dart';
import 'package:maestria/ui/plugin_pane.dart';
import 'package:maestria/ui/sidebar.dart';
import 'package:maestria/ui/sidebar_rail.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Uma pasta de plugin escrita à mão, com o manifesto [manifest] e os
/// arquivos extras de [files].
Directory writePlugin(
  String parent,
  String name,
  Map<String, dynamic> manifest, {
  Map<String, String> files = const {},
}) {
  final dir = Directory('$parent/$name')..createSync(recursive: true);
  File('${dir.path}/$mxManifestName').writeAsStringSync(jsonEncode(manifest));
  for (final e in files.entries) {
    File('${dir.path}/${e.key}')
      ..createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
  return dir;
}

/// O tema do exemplo do repositório: é o arquivo que um autor copiaria.
Map<String, dynamic> get aurora =>
    jsonDecode(File('examples/plugins/tema-e-atalhos/themes/aurora.json').readAsStringSync())
        as Map<String, dynamic>;

/// Um plugin em sh que fala o protocolo o bastante pra ser testado: responde o
/// `initialize`, pede um recado à janela quando um comando chega, e escreve no
/// log a cada evento. O `id` da janela é o único número depois de `"id":` na
/// linha -- o `pluginId` e o `tabId` têm outra letra antes das aspas.
const shPlugin = r'''#!/bin/sh
idof() { echo "$1" | sed 's/.*"id":\([0-9]*\).*/\1/'; }
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":{}}" ;;
    *'"method":"command.invoke"'*)
      echo '{"jsonrpc":"2.0","id":"p1","method":"window.showBanner","params":{"text":"oi"}}'
      echo 'isto não é json'
      echo "{\"jsonrpc\":\"2.0\",\"id\":$(idof "$line"),\"result\":\"feito\"}" ;;
    *'"method":"event"'*)
      echo '{"jsonrpc":"2.0","method":"log","params":{"message":"evento"}}' ;;
    *'"method":"shutdown"'*)
      exit 0 ;;
  esac
done
''';

Future<void> until(bool Function() ok, {String reason = ''}) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  expect(ok(), isTrue, reason: reason);
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('mx-plugins-'));
  tearDown(() {
    MxThemes.extra.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('o manifesto', () {
    test('o mínimo é id e versão, e o nome cai no id', () {
      final m = PluginManifest.parse({'id': 'meu.plugin', 'version': '0.1.0'});
      expect(m.name, 'meu.plugin');
      expect(m.hasProcess, isFalse);
      expect(m.commands, isEmpty);
    });

    test('recusa o que faria o plugin fazer outra coisa que o autor quis', () {
      void bad(Map<String, dynamic> j, String says) => expect(
        () => PluginManifest.parse({'id': 'x', 'version': '1', ...j}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(says))),
      );
      bad({'id': 'Com Espaço'}, '"id"');
      bad({
        'permissions': ['root'],
      }, 'permissão desconhecida');
      bad({'maestria': 99}, 'versão 99');
      bad({'main': 3}, '"main"');
      bad({
        'contributes': {
          'commands': [
            {'id': 'a', 'title': 'A'},
          ],
        },
      }, 'não tem "main"');
      bad({
        'contributes': {
          'commands': [
            {'id': 'a', 'title': 'A', 'run': 'ls', 'send': 'oi'},
          ],
        },
      }, 'escolha um');
      bad({
        'contributes': {
          'commands': [
            {'id': 'a', 'title': 'A', 'run': 'ls', 'in': 'nuvem'},
          ],
        },
      }, '"in"');
    });

    test('lê os três jeitos de um comando acontecer', () {
      final m = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'main': 'bin/plugin',
        'contributes': {
          'commands': [
            {'id': 'a', 'title': 'A'},
            {'id': 'b', 'title': 'B', 'run': 'ls', 'in': 'background'},
            {'id': 'c', 'title': 'C', 'send': 'revise'},
            {'id': 'd', 'title': 'D', 'run': 'htop'},
          ],
        },
      });
      expect(m.main, ['bin/plugin']);
      expect(m.commands.map((c) => c.target), [
        CommandTarget.plugin,
        CommandTarget.background,
        CommandTarget.session,
        CommandTarget.terminal,
      ]);
      expect(m.commands.first.fullId, 'x/a');
    });

    test('uma tecla que não vale vira aviso, e o comando fica sem ela', () {
      final m = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'contributes': {
          'commands': [
            {'id': 'a', 'title': 'A', 'run': 'ls', 'key': 'meta+q'},
            {'id': 'b', 'title': 'B', 'run': 'ls', 'key': 'meta+alt+g'},
            {'id': 'c', 'title': 'C', 'run': 'ls', 'key': 'banana+z+'},
          ],
        },
      });
      expect(m.commands[0].key, isNull);
      expect(m.commands[1].key, const MxChord(LogicalKeyboardKey.keyG, meta: true, alt: true));
      expect(m.commands[2].key, isNull);
      expect(m.warnings, hasLength(2));
      expect(m.warnings.first, contains('⌘Q'));
    });

    test('sem evento declarado, um plugin com processo sobe com o app', () {
      final plain = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'main': ['node', 'm.js'],
      });
      expect(plain.activatesOn('onStartup'), isTrue);
      expect(plain.activatesOn('onHook:Stop'), isFalse);

      final lazy = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'main': ['node', 'm.js'],
        'activationEvents': ['onHook:Stop'],
      });
      expect(lazy.activatesOn('onStartup'), isFalse);
      expect(lazy.activatesOn('onHook:Stop'), isTrue);

      final declarative = PluginManifest.parse({'id': 'x', 'version': '1'});
      expect(declarative.activatesOn('onStartup'), isFalse, reason: 'não há o que subir');
    });

    test('os manifestos dos exemplos do repositório leem sem aviso', () {
      for (final name in ['tema-e-atalhos', 'exemplo-completo']) {
        final m = PluginManifest.read('examples/plugins/$name');
        expect(m.warnings, isEmpty, reason: name);
      }
    });
  });

  group('o tema de plugin', () {
    test('lê o json do exemplo, com os bright caindo na cor normal', () {
      final p = MxPalette.fromJson(aurora);
      expect(p.id, 'exemplo-aurora');
      expect(p.accent, const Color(0xFF5EE3C1));
      expect(p.ansi.brightBlack, const Color(0xFF5F7385));
      expect(p.ansi.brightRed, p.ansi.red);
    });

    test('diz qual campo faltou', () {
      final broken = {...aurora}..remove('bgHover');
      expect(
        () => MxPalette.fromJson(broken),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('bgHover'))),
      );
      final ansi = {
        ...aurora,
        'ansi': {...aurora['ansi'] as Map<String, dynamic>, 'cyan': 'azul'},
      };
      expect(
        () => MxPalette.fromJson(ansi),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('ansi.cyan'))),
      );
    });

    test('um id de tema de plugin é achado pelo byId', () {
      MxThemes.extra.add(MxPalette.fromJson(aurora));
      expect(MxThemes.byId('exemplo-aurora').label, 'Aurora');
      expect(MxThemes.byId('nao-existe').id, MxThemes.maestria.id);
    });
  });

  group('a pasta de plugins', () {
    test('lê os bons, marca os ruins e não deixa dois com o mesmo id', () {
      writePlugin(
        tmp.path,
        'a-tema',
        {
          'id': 'a.tema',
          'version': '1.0.0',
          'contributes': {
            'themes': ['t.json'],
          },
        },
        files: {'t.json': jsonEncode(aurora)},
      );
      writePlugin(tmp.path, 'b-quebrado', {'id': 'b'});
      writePlugin(tmp.path, 'c-repetido', {'id': 'a.tema', 'version': '2'});
      Directory('${tmp.path}/.staging').createSync();

      final plugins = Plugins(root: tmp.path)..scan();
      expect(plugins.all.map((p) => p.state), [
        PluginState.idle,
        PluginState.invalid,
        PluginState.invalid,
      ]);
      expect(plugins.all[1].problem, contains('"version"'));
      expect(plugins.all[2].problem, contains('já usa o id'));
      expect(MxThemes.extra.map((p) => p.id), ['exemplo-aurora']);
      expect(plugins.byId('a.tema')!.palettes, hasLength(1));
    });

    test('desligar tira os temas e os comandos; o config lembra', () async {
      writePlugin(
        tmp.path,
        'p',
        {
          'id': 'p',
          'version': '1',
          'contributes': {
            'themes': ['t.json'],
            'commands': [
              {'id': 'ls', 'title': 'listar', 'run': 'ls'},
            ],
          },
        },
        files: {'t.json': jsonEncode(aurora)},
      );
      final plugins = Plugins(root: tmp.path)..scan();
      expect(plugins.commands, hasLength(1));

      await plugins.setEnabled(plugins.byId('p')!, false);
      expect(plugins.commands, isEmpty);
      expect(MxThemes.extra, isEmpty);
      expect(plugins.toJson(), {
        'disabled': ['p'],
      });

      final again = Plugins(root: tmp.path)
        ..load(plugins.toJson())
        ..scan();
      expect(again.byId('p')!.state, PluginState.disabled);
    });

    test('um tema com o id de um embutido é recusado, e o motivo vai pro log', () {
      writePlugin(
        tmp.path,
        'p',
        {
          'id': 'p',
          'version': '1',
          'contributes': {
            'themes': ['t.json'],
          },
        },
        files: {
          't.json': jsonEncode({...aurora, 'id': 'nord'}),
        },
      );
      final plugins = Plugins(root: tmp.path)..scan();
      expect(MxThemes.extra, isEmpty);
      expect(plugins.byId('p')!.log.single, contains('embutido'));
    });
  });

  group('instalar', () {
    test('de uma pasta: rascunho, instalar, e remover', () async {
      final root = '${tmp.path}/plugins';
      final src = writePlugin(tmp.path, 'fonte', {'id': 'meu.plugin', 'version': '1.0.0'});
      final plugins = Plugins(root: root)..scan();

      final staged = await plugins.stage(src.path);
      expect(staged.manifest.id, 'meu.plugin');
      expect(staged.replacing, isNull);
      expect(Directory('$root/meu.plugin').existsSync(), isFalse, reason: 'nada instalado ainda');

      final plugin = await plugins.commit(staged);
      expect(plugin.dir, '$root/meu.plugin');
      expect(File('$root/meu.plugin/$mxManifestName').existsSync(), isTrue);
      expect(Directory(staged.staging).existsSync(), isFalse, reason: 'o rascunho some');

      // A mesma coisa de novo, numa versão nova, é uma atualização.
      File(
        '${src.path}/$mxManifestName',
      ).writeAsStringSync(jsonEncode({'id': 'meu.plugin', 'version': '1.1.0'}));
      final update = await plugins.stage(src.path);
      expect(update.replacing, '1.0.0');
      await plugins.commit(update);
      expect(plugins.all.single.manifest!.version, '1.1.0');

      await plugins.uninstall(plugins.all.single);
      expect(plugins.all, isEmpty);
      expect(Directory('$root/meu.plugin').existsSync(), isFalse);
      expect(src.existsSync(), isTrue, reason: 'a fonte não é tocada');
    });

    test('acha o manifesto dentro da única pasta de um pacote', () async {
      final pack = Directory('${tmp.path}/pacote')..createSync();
      writePlugin(pack.path, 'maestria-plugin-x-main', {'id': 'x', 'version': '1'});
      Directory('${pack.path}/__MACOSX').createSync();
      final plugins = Plugins(root: '${tmp.path}/plugins');
      final staged = await plugins.stage(pack.path);
      expect(staged.dir, endsWith('maestria-plugin-x-main'));
      await plugins.discard(staged);
      expect(Directory(staged.staging).existsSync(), isFalse);
    });

    test('recusa o que não é plugin sem deixar rascunho', () async {
      final empty = Directory('${tmp.path}/vazia')..createSync();
      final plugins = Plugins(root: '${tmp.path}/plugins');
      await expectLater(
        plugins.stage(empty.path),
        throwsA(
          isA<PluginInstallError>().having((e) => e.message, 'message', contains(mxManifestName)),
        ),
      );
      await expectLater(
        plugins.stage('${tmp.path}/nao-existe'),
        throwsA(isA<PluginInstallError>()),
      );
      expect(Directory('${tmp.path}/plugins/.staging').listSync(), isEmpty);
    });

    test('a pasta de desenvolvimento entra por link, e remover não a apaga', () async {
      final root = '${tmp.path}/plugins';
      final dev = writePlugin(tmp.path, 'dev', {'id': 'dev.plugin', 'version': '0.0.1'});
      final plugins = Plugins(root: root)..scan();
      final plugin = await plugins.link(dev.path);
      expect(plugin.linked, isTrue);
      expect(FileSystemEntity.isLinkSync('$root/dev.plugin'), isTrue);
      await expectLater(plugins.link(dev.path), throwsA(isA<PluginInstallError>()));

      await plugins.uninstall(plugin);
      expect(FileSystemEntity.isLinkSync('$root/dev.plugin'), isFalse);
      expect(File('${dev.path}/$mxManifestName').existsSync(), isTrue);
    });
  });

  group('o processo do plugin', () {
    late Plugins plugins;
    final calls = <String>[];

    setUp(() {
      calls.clear();
      final dir = writePlugin(
        tmp.path,
        'sh',
        {
          'id': 'sh',
          'version': '1',
          'main': ['./plugin.sh'],
          'activationEvents': ['onCommand:oi', 'onSession'],
          'contributes': {
            'commands': [
              {'id': 'oi', 'title': 'dizer oi'},
            ],
          },
        },
        files: {'plugin.sh': shPlugin},
      );
      Process.runSync('chmod', ['+x', '${dir.path}/plugin.sh']);
      plugins = Plugins(root: tmp.path)
        ..onCall = (plugin, method, params) async {
          calls.add('$method ${jsonEncode(params)}');
          return null;
        }
        ..scan();
    });

    tearDown(() => plugins.stopAll());

    test('não sobe sem um evento dele', () {
      plugins.startup();
      expect(plugins.byId('sh')!.state, PluginState.idle);
    });

    test('um comando sobe o processo, que pede coisas à janela e responde', () async {
      final result = await plugins.invoke(plugins.commands.single, {'cwd': '/repo'});
      expect(result, 'feito');
      expect(calls, ['window.showBanner {"text":"oi"}']);
      final plugin = plugins.byId('sh')!;
      expect(plugin.state, PluginState.running);
      expect(plugin.log.any((l) => l.contains('stdout: isto não é json')), isTrue);
    });

    test('um evento que ele declarou o sobe; o log dele chega', () async {
      plugins.emit('session.opened', {'tabId': 'tab1'}, activations: ['onSession']);
      final plugin = plugins.byId('sh')!;
      await until(() => plugin.log.any((l) => l.endsWith('evento')), reason: plugin.log.join('\n'));
    });

    test('um evento que ele não declarou não o sobe, e hook sem permissão não chega', () async {
      plugins.emit('hook', {'name': 'Stop'}, activations: ['onHook:Stop']);
      plugins.emit(
        'hook',
        {'name': 'Stop'},
        activations: ['onSession'],
        needs: PluginPermission.hooks,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(plugins.byId('sh')!.state, PluginState.idle);
    });

    test('parar e subir de novo pelo reiniciar', () async {
      await plugins.invoke(plugins.commands.single, {});
      final plugin = plugins.byId('sh')!;
      await plugins.restart(plugin);
      expect(plugin.state, PluginState.running);
      await plugins.stopAll();
      expect(plugin.state, PluginState.idle);
    });
  });

  test('um main que não existe cai com o motivo, sem derrubar nada', () async {
    writePlugin(tmp.path, 'x', {
      'id': 'x',
      'version': '1',
      'main': ['programa-que-nao-existe-em-lugar-nenhum'],
    });
    final plugins = Plugins(root: tmp.path)..scan();
    plugins.startup();
    final plugin = plugins.byId('x')!;
    await until(() => plugin.state == PluginState.crashed);
    expect(plugin.crash, contains('não achei'));
  });

  test('um processo que morre na largada fica como parou, e evento não o ressuscita', () async {
    final dir = writePlugin(
      tmp.path,
      'x',
      {
        'id': 'x',
        'version': '1',
        'main': ['./morre.sh'],
        'activationEvents': ['onSession'],
      },
      files: {'morre.sh': '#!/bin/sh\nexit 3\n'},
    );
    Process.runSync('chmod', ['+x', '${dir.path}/morre.sh']);
    final plugins = Plugins(root: tmp.path)..scan();
    plugins.emit('x', {}, activations: ['onSession']);
    final plugin = plugins.byId('x')!;
    await until(() => plugin.state == PluginState.crashed);
    final before = plugin.log.length;
    plugins.emit('x', {}, activations: ['onSession']);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(plugin.log.length, before, reason: 'não tentou subir de novo');
  });

  group('a tecla do plugin', () {
    const chord = MxChord(LogicalKeyboardKey.keyE, meta: true, alt: true);

    /// O ⌥E como o macOS o manda nos layouts com acento: o lugar do E, e uma
    /// tecla lógica que é o acento, não o E. Montado à mão porque o simulador
    /// do flutter_test só aceita teclas que ele conhece.
    const deadE = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyE,
      logicalKey: LogicalKeyboardKey(0xB4),
      character: '´',
      timeStamp: Duration.zero,
    );

    testWidgets('⌥⌘E dispara mesmo quando o ⌥E chega como acento', (tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(chord.accepts(deadE), isFalse, reason: 'pela tecla lógica não casa');
      expect(Plugins.chordHits(chord, deadE), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });

    testWidgets('o lugar do E sem o ⌥ não é o atalho', (tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(Plugins.chordHits(chord, deadE), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });
  });

  group('as peças da central', () {
    test('o comando lê ícone e lugar na lateral, com teto', () {
      final m = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'contributes': {
          'commands': [
            for (var i = 0; i < 5; i++)
              {'id': 'c$i', 'title': 'C$i', 'run': 'ls', 'icon': 'bug', 'sidebar': true},
            {'id': 'fora', 'title': 'fora', 'run': 'ls'},
          ],
        },
      });
      expect(m.commands.first.icon, 'bug');
      expect(m.commands.last.sidebar, isFalse);
      writePlugin(tmp.path, 'x', {
        'id': 'x',
        'version': '1',
        'contributes': {
          'commands': [
            for (final c in m.commands)
              {'id': c.id, 'title': c.title, 'run': 'ls', 'sidebar': c.sidebar},
          ],
        },
      });
      final plugins = Plugins(root: tmp.path)..scan();
      expect(plugins.sidebarCommands, hasLength(Plugins.maxSidebarCommands));
    });

    test('um console guarda as linhas quando os blocos mudam sem mandá-las', () {
      final view = PluginView(
        pluginId: 'p',
        pluginName: 'P',
        id: 'v',
        title: 't',
        blocks: PluginView.blocksFrom([
          {
            'type': 'console',
            'id': 'log',
            'lines': [
              'um',
              {'text': 'dois', 'tone': 'red'},
            ],
            'max': 3,
          },
        ]),
      );
      final log = view.console('log');
      expect(log.lines.map((l) => l.text), ['um', 'dois']);
      expect(log.lines.last.tone, 'red');
      log.append(['três', 'quatro']);
      expect(log.lines.map((l) => l.text), [
        'dois',
        'três',
        'quatro',
      ], reason: 'o teto tira as velhas');

      view.setBlocks(
        PluginView.blocksFrom([
          {'type': 'button', 'action': 'x'},
          {'type': 'console', 'id': 'log'},
        ]),
      );
      expect(view.console('log'), same(log));
      expect(log.lines, hasLength(3));

      view.setBlocks(const []);
      expect(view.consoles, isEmpty, reason: 'o console que sumiu dos blocos vai embora');
    });

    testWidgets('botão de ícone, console que ocupa o resto e seletor travado', (tester) async {
      final store = AppStore();
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
      );
      final tab = store.openPluginView(
        plugin,
        'central',
        title: 'flutter',
        blocks: PluginView.blocksFrom([
          {
            'type': 'row',
            'children': [
              {
                'type': 'select',
                'id': 'cfg',
                'options': ['Debug'],
                'value': 'Debug',
                'disabled': true,
              },
              {
                'type': 'button',
                'style': 'icon',
                'icon': 'reload',
                'tooltip': 'hot reload',
                'action': 'reload',
                'tone': 'yellow',
              },
            ],
          },
          {
            'type': 'console',
            'id': 'log',
            'expand': true,
            'lines': ['linha um'],
          },
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('hot reload'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
      expect(find.text('linha um'), findsOneWidget);
      final dropdown = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(dropdown.onChanged, isNull);

      // O console ocupa a altura que sobra do painel.
      final console = tester.getRect(find.byType(ListView));
      expect(console.height, greaterThan(400));

      // Linhas novas chegam sem passar pela store.
      store.pluginConsole(plugin, 'central', 'log')!.append(['linha dois']);
      await tester.pump();
      await tester.pump();
      expect(find.text('linha dois'), findsOneWidget);
    });
  });

  group('seletor, ícone e overflow', () {
    test('window.pick pergunta pela janela e devolve o escolhido', () async {
      final store = AppStore();
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
      );
      final api = PluginApi(store);
      await expectLater(
        api.handle(plugin, 'window.pick', {
          'items': [
            {'value': 'a'},
          ],
        }),
        throwsA(isA<PluginRpcError>()),
        reason: 'sem janela não há onde perguntar',
      );
      List<String>? shown;
      store.quickPick = ({required title, placeholder, required items}) async {
        shown = [title, for (final it in items) '${it.label}|${it.detail}'];
        return items.last.value;
      };
      final picked = await api.handle(plugin, 'window.pick', {
        'title': 'qual projeto?',
        'items': [
          {'value': '/a', 'label': 'a', 'detail': '~/a'},
          {'value': '/b'},
          {'label': 'sem valor'},
        ],
      });
      expect(picked, '/b');
      expect(shown, ['qual projeto?', 'a|~/a', '/b|null']);
    });

    testWidgets('o seletor rápido filtra, anda com as setas e escolhe no enter', (tester) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => picked = await showQuickPick(
                ctx,
                title: 'projeto',
                items: const [
                  (value: '/x/app-a', label: 'app-a', detail: '~/x/app-a'),
                  (value: '/x/app-b', label: 'app-b', detail: '~/x/app-b'),
                  (value: '/y/outro', label: 'outro', detail: '~/y/outro'),
                ],
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'app');
      await tester.pump();
      expect(find.text('outro'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, '/x/app-b');
    });

    testWidgets('o svg da pasta do plugin vira o ícone, e não sai da pasta', (tester) async {
      final dir = writePlugin(
        tmp.path,
        'p',
        {'id': 'p', 'version': '1'},
        files: {
          'icons/logo.svg':
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>',
        },
      );
      expect(PluginGlyph.svgOf('icons/logo.svg', dir.path), isNotNull);
      expect(PluginGlyph.svgOf('../p/icons/logo.svg', dir.path), isNull);
      expect(PluginGlyph.svgOf('icons/nao-tem.svg', dir.path), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              PluginGlyph(icon: 'icons/logo.svg', dir: dir.path),
              const PluginGlyph(icon: 'bug'),
              const PluginGlyph(icon: 'nao-existe'),
            ],
          ),
        ),
      );
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.bug_report_outlined), findsOneWidget);
      expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
    });

    testWidgets('um aparelho de nome comprido não estoura o seletor', (tester) async {
      final store = AppStore();
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
      );
      final tab = store.openPluginView(
        plugin,
        'v',
        title: 'flutter',
        blocks: PluginView.blocksFrom([
          {
            'type': 'row',
            'children': [
              {
                'type': 'select',
                'id': 'cfg',
                'width': 280,
                'options': ['Debug'],
                'value': 'Debug',
              },
              {
                'type': 'select',
                'id': 'dev',
                'width': 220,
                'options': [
                  {
                    'value': 'x',
                    'label': 'sdk gphone64 arm64 · android-arm64 · um nome bem comprido mesmo',
                  },
                ],
                'value': 'x',
              },
              for (final i in ['continue', 'refresh'])
                {'type': 'button', 'style': 'icon', 'icon': i, 'action': i},
            ],
          },
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 300,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('o lugar das janelas na lateral', () {
    Widget host(AppStore store, Widget Function() child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 700,
          child: AnimatedBuilder(animation: store, builder: (context, _) => child()),
        ),
      ),
    );

    testWidgets('a janela de plugin mora na aba do plugin, não na lista das sessões', (
      tester,
    ) async {
      writePlugin(tmp.path, 'flutter', {
        'id': 'maestria.flutter',
        'name': 'Flutter',
        'version': '1',
        'icon': 'bug',
        'contributes': {
          'commands': [
            {'id': 'reload', 'title': 'flutter: hot reload', 'run': 'true'},
            {'id': 'outro', 'title': 'git: outro prefixo', 'run': 'true'},
          ],
        },
      });
      final store = AppStore();
      final plugins = Plugins(root: tmp.path)..scan();
      store.plugins.all.addAll(plugins.all);
      final folder = Folder(root: '/repo/maestria_v2', name: 'maestria_v2');
      store.folders.add(folder);
      final session = MxTab(
        id: 'tab1',
        folder: folder,
        kind: TabKind.shell,
        cwd: folder.root,
        branch: '',
        customLabel: 'Plugin',
      );
      store.tabs.add(session);
      store.panes = PaneLeaf(session.id);
      store.focusedPaneId = session.id;

      final flutter = store.plugins.byId('maestria.flutter')!;
      final view = store.openPluginView(
        flutter,
        'central-x',
        title: 'flutter · learning-app',
        blocks: const [],
      );
      expect(view.folder.isLoose, isTrue, reason: 'não herda a pasta do painel em foco');
      expect(store.tabsOf(folder).map((t) => t.id), ['tab1']);
      expect(store.tabsOf(store.loose), isEmpty, reason: 'nem aparece nos avulsos');
      expect(store.viewsOf(flutter).single, same(view));

      await tester.pumpWidget(host(store, () => Sidebar(store: store)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(find.text('Plugin'), findsOneWidget);
      expect(
        find.text('flutter · learning-app'),
        findsNothing,
        reason: 'fora da lista das sessões',
      );

      store.showSidebarView(flutter.id);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(find.text('Plugin'), findsNothing, reason: 'a aba troca a lateral inteira');
      expect(find.text('flutter · learning-app'), findsOneWidget);
      expect(find.text('hot reload'), findsOneWidget, reason: 'o prefixo do plugin sai');
      expect(find.text('git: outro prefixo'), findsOneWidget, reason: 'o de outro nome fica');
      store.dispose();
    });

    testWidgets('a faixa: quem ganha ícone, e o clique que troca ou esconde', (tester) async {
      writePlugin(tmp.path, 'a-ssh', {
        'id': 'ssh',
        'name': 'SSH',
        'version': '1',
        'icon': 'terminal',
        'contributes': {
          'commands': [
            {'id': 'hosts', 'title': 'ssh: hosts…', 'run': 'true', 'sidebar': true},
          ],
        },
      });
      // Sem desenho próprio: é um botão, não um lugar -- continua no rodapé.
      writePlugin(tmp.path, 'b-relatorio', {
        'id': 'relatorio',
        'version': '1',
        'contributes': {
          'commands': [
            {'id': 'dia', 'title': 'relatório', 'run': 'true', 'sidebar': true},
          ],
        },
      });
      final store = AppStore();
      store.plugins.all.addAll((Plugins(root: tmp.path)..scan()).all);

      expect(store.railPlugins.map((p) => p.id), ['ssh']);
      expect(store.footerCommands.map((c) => c.fullId), ['relatorio/dia']);
      expect(store.shownPlugin, isNull);

      await tester.pumpWidget(host(store, () => SidebarRail(store: store)));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(PluginGlyph).first);
      await tester.pump();
      expect(store.shownPlugin?.id, 'ssh');
      expect(store.sidebarHidden, isFalse);

      // O ícone da aba na tela esconde a lateral; qualquer um a traz de volta.
      await tester.tap(find.byType(PluginGlyph).first);
      await tester.pump();
      expect(store.sidebarHidden, isTrue);
      store.showSidebarView(null);
      expect(store.sidebarHidden, isFalse);
      expect(store.shownPlugin, isNull);

      // Um plugin que sai da faixa não deixa a lateral numa aba de ninguém.
      store.showSidebarView('ssh');
      store.plugins.byId('ssh')!.enabled = false;
      expect(store.shownPlugin, isNull);
      store.dispose();
    });

    testWidgets('sem plugin nenhum, a faixa fica, e o "+" do fim abre o instalar', (tester) async {
      final store = AppStore();
      expect(store.railPlugins, isEmpty);

      await tester.pumpWidget(host(store, () => SidebarRail(store: store)));
      expect(find.byIcon(Icons.space_dashboard_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('instalar plugin'), findsWidgets);
      store.dispose();
    });
  });

  group('a aba que o plugin desenha', () {
    test('contributes.sidebar: precisa de main, e é true ou false', () {
      final m = PluginManifest.parse({
        'id': 'x',
        'version': '1',
        'main': ['node', 'main.js'],
        'contributes': {'sidebar': true},
      });
      expect(m.sidebar, isTrue);
      expect(m.warnings, isEmpty, reason: 'é uma chave que esta versão conhece');
      expect(
        () => PluginManifest.parse({
          'id': 'x',
          'version': '1',
          'contributes': {'sidebar': true},
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PluginManifest.parse({
          'id': 'x',
          'version': '1',
          'main': ['node'],
          'contributes': {'sidebar': 'sim'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    testWidgets('sidebar.update desenha a aba com os blocos, e o selo vai pra faixa', (
      tester,
    ) async {
      final store = AppStore();
      final own = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(
          id: 'git',
          name: 'Git',
          version: '1',
          main: ['node'],
          sidebar: true,
        ),
      );
      final plain = MxPlugin(
        dir: '/q',
        manifest: const PluginManifest(id: 'q', name: 'Q', version: '1', main: ['node']),
      );
      store.plugins.all.addAll([own, plain]);
      final api = PluginApi(store);

      expect(store.railPlugins, [own], reason: 'quem desenha a aba ganha ícone');
      await expectLater(
        api.handle(plain, 'sidebar.update', {'blocks': []}),
        throwsA(isA<PluginRpcError>()),
        reason: 'sem declarar no manifesto',
      );
      await expectLater(
        api.handle(own, 'view.open', {'viewId': 'sidebar', 'blocks': []}),
        throwsA(isA<PluginRpcError>()),
        reason: '"sidebar" é reservado',
      );

      store.sidebarView = own.id;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 700,
              child: AnimatedBuilder(
                animation: store,
                builder: (context, _) => Sidebar(store: store),
              ),
            ),
          ),
        ),
      );
      expect(find.text('abrindo Git…'), findsOneWidget, reason: 'antes do primeiro update');

      final said = await api.handle(own, 'sidebar.update', {
        'badge': 3,
        'blocks': [
          {'type': 'section', 'text': 'mudanças', 'count': 1},
          {
            'type': 'list',
            'flat': true,
            'items': [
              {'title': 'lib/main.dart', 'action': 'abrir'},
            ],
          },
        ],
      });
      expect(said, {'shown': false}, reason: 'o teste não passou pelo clique da faixa');
      expect(store.sidebarBadges['git'], '3');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('mudanças'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);

      // Só o selo: os blocos ficam, e null tira o selo.
      await api.handle(own, 'sidebar.update', {'badge': null});
      await tester.pump();
      expect(store.sidebarBadges, isEmpty);
      expect(find.text('lib/main.dart'), findsOneWidget);
      store.dispose();
    });
  });

  group('o terminal que é do plugin', () {
    test('sai dos avulsos, mora no plugin, e só o dono fecha', () async {
      final store = AppStore();
      final ssh = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'ssh', name: 'SSH', version: '1', main: ['node']),
      );
      final other = MxPlugin(
        dir: '/q',
        manifest: const PluginManifest(id: 'q', name: 'Q', version: '1', main: ['node']),
      );
      store.plugins.all.addAll([ssh, other]);
      MxTab shell(String id) =>
          MxTab(id: id, folder: store.loose, kind: TabKind.shell, cwd: '/', branch: '');
      final mine = shell('t1')
        ..owner = 'ssh'
        ..ownerTag = 's:h1';
      final yours = shell('t2');
      store.tabs.addAll([mine, yours]);

      expect(store.tabsOf(store.loose), [yours], reason: 'o do plugin não é avulso');
      expect(store.ownedBy(ssh), [mine]);
      expect(store.railPlugins, [ssh], reason: 'o plugin com terminal ganha lugar na faixa');

      final api = PluginApi(store);
      final list = (await api.handle(ssh, 'sessions.list', {}) as List).cast<Map>();
      expect(list.first['owner'], 'ssh');
      expect(list.first['tag'], 's:h1');
      final seen = (await api.handle(other, 'sessions.list', {}) as List).cast<Map>();
      expect(seen.first.containsKey('tag'), isFalse, reason: 'o tag é conversa do dono');

      await expectLater(
        api.handle(ssh, 'session.close', {'tabId': 't2'}),
        throwsA(isA<PluginRpcError>()),
        reason: 'a sua sessão não é do plugin',
      );
      await expectLater(
        api.handle(other, 'session.close', {'tabId': 't1'}),
        throwsA(isA<PluginRpcError>()),
      );

      // O dono removido devolve o terminal aos avulsos em vez de sumir com ele.
      store.plugins.all.remove(ssh);
      expect(store.tabsOf(store.loose), [mine, yours]);
      store.dispose();
    });
  });

  group('as configurações de plugin', () {
    Map<String, dynamic> manifest() => {
      'id': 'cfg',
      'version': '1',
      'contributes': {
        'settings': [
          {
            'id': 'colors.app',
            'type': 'color',
            'default': '',
            'title': 'log do app',
            'group': 'cores',
          },
          {
            'id': 'colors.error',
            'type': 'color',
            'default': 'red',
            'title': 'erro',
            'group': 'cores',
          },
          {'id': 'max', 'type': 'number', 'default': 5000},
          {
            'id': 'modo',
            'type': 'select',
            'options': ['a', 'b'],
          },
          {'id': 'ligado', 'type': 'boolean'},
        ],
      },
    };

    test('lê os tipos, recusa o que não fecha, e resolve o padrão', () {
      final m = PluginManifest.parse(manifest());
      expect(m.settings.map((s) => s.type), [
        PluginSettingType.color,
        PluginSettingType.color,
        PluginSettingType.number,
        PluginSettingType.select,
        PluginSettingType.boolean,
      ]);
      final modo = m.settings[3];
      expect(modo.resolve(null), 'a', reason: 'sem padrão, a primeira opção');
      expect(modo.resolve('b'), 'b');
      expect(modo.resolve('z'), 'a', reason: 'um valor que não é opção cai no padrão');
      expect(m.settings[2].resolve('muito'), 5000, reason: 'tipo errado cai no padrão');
      expect(m.settings[4].resolve(null), false);
      expect(
        () => PluginManifest.parse({
          'id': 'x',
          'version': '1',
          'contributes': {
            'settings': [
              {'id': 's', 'type': 'select'},
            ],
          },
        }),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('options'))),
      );
    });

    test('só o que você mexeu vai pro config, e volta', () {
      writePlugin(tmp.path, 'cfg', manifest());
      final plugins = Plugins(root: tmp.path)..scan();
      final p = plugins.byId('cfg')!;
      expect(plugins.settingsOf(p)['colors.error'], 'red');
      expect(plugins.toJson(), isEmpty);

      plugins.setSetting(p, 'colors.app', '#4FC1FF');
      expect(plugins.settingsOf(p)['colors.app'], '#4FC1FF');
      expect(plugins.toJson(), {
        'settings': {
          'cfg': {'colors.app': '#4FC1FF'},
        },
      });

      final again = Plugins(root: tmp.path)
        ..load(plugins.toJson())
        ..scan();
      expect(again.settingsOf(again.byId('cfg')!)['colors.app'], '#4FC1FF');

      plugins.setSetting(p, 'colors.app', null);
      expect(plugins.settingsOf(p)['colors.app'], '');
      expect(plugins.toJson(), isEmpty, reason: 'voltar ao padrão tira do config');
    });

    test('a cor de um valor: hex, nome do tema ou vazio', () {
      expect(pluginColor('#4FC1FF'), const Color(0xFF4FC1FF));
      expect(pluginColor(''), Mx.fg);
      expect(pluginColor('red'), Mx.red);
      expect(pluginColor('azul'), isNull);
      expect(pluginColor('#12'), isNull);
    });

    testWidgets('o diálogo desenha do manifesto e guarda cada mudança', (tester) async {
      writePlugin(tmp.path, 'cfg', manifest());
      final store = AppStore();
      store.plugins.all.addAll((Plugins(root: tmp.path)..scan()).all);
      final p = store.plugins.byId('cfg')!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showPluginSettings(ctx, store, p),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('cores'), findsOneWidget);
      expect(find.text('log do app'), findsOneWidget);

      // Um preset, e o campo acompanha.
      await tester.tap(find.byTooltip('#4FC1FF').first);
      await tester.pumpAndSettle();
      expect(store.plugins.settingsOf(p)['colors.app'], '#4FC1FF');
      expect(find.text('#4FC1FF'), findsWidgets);

      // Um hex digitado que não é cor não é guardado.
      await tester.enterText(find.widgetWithText(TextField, 'red'), '#zz');
      await tester.pump();
      expect(store.plugins.settingsOf(p)['colors.error'], 'red');
      await tester.enterText(find.widgetWithText(TextField, '#zz'), '#FF0000');
      await tester.pump();
      expect(store.plugins.settingsOf(p)['colors.error'], '#FF0000');

      // E volta ao padrão.
      await tester.tap(find.byTooltip('voltar ao padrão').first);
      await tester.pumpAndSettle();
      expect(store.plugins.settingsOf(p)['colors.app'], '');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('o calendário', () {
    Future<List<(DateTime, DateTime)>> pump(
      WidgetTester tester, {
      bool range = true,
      DateTime? from,
      DateTime? to,
      DateTime? max,
    }) async {
      final picked = <(DateTime, DateTime)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PluginCalendar(
                range: range,
                from: from,
                to: to,
                max: max,
                onChanged: (f, t) => picked.add((f, t)),
              ),
            ),
          ),
        ),
      );
      return picked;
    }

    testWidgets('dois cliques fazem um período, em qualquer ordem', (tester) async {
      final picked = await pump(tester, to: DateTime(2026, 9, 23), max: DateTime(2026, 9, 23));
      expect(find.text('setembro de 2026'), findsOneWidget);
      await tester.tap(find.text('19'));
      await tester.pump();
      await tester.tap(find.text('15'));
      await tester.pump();
      expect(picked, [
        (DateTime(2026, 9, 19), DateTime(2026, 9, 19)),
        (DateTime(2026, 9, 15), DateTime(2026, 9, 19)),
      ]);
    });

    testWidgets('dia depois do máximo não responde, e o mês seguinte não abre', (tester) async {
      final picked = await pump(
        tester,
        range: false,
        to: DateTime(2026, 9, 23),
        max: DateTime(2026, 9, 23),
      );
      await tester.tap(find.text('28'));
      await tester.pump();
      expect(picked, isEmpty);
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();
      expect(find.text('setembro de 2026'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pump();
      expect(find.text('agosto de 2026'), findsOneWidget);
      await tester.tap(find.text('25'));
      expect(picked.single, (DateTime(2026, 8, 25), DateTime(2026, 8, 25)));
    });

    testWidgets('no painel, o período vai pro plugin como {from, to}', (tester) async {
      final store = AppStore();
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
      );
      final tab = store.openPluginView(
        plugin,
        'v',
        title: 'relatório',
        blocks: PluginView.blocksFrom([
          {
            'type': 'calendar',
            'id': 'periodo',
            'mode': 'range',
            'value': {'from': '2026-09-22', 'to': '2026-09-22'},
            'max': '2026-09-23',
          },
          {'type': 'button', 'action': 'ir', 'label': 'ir'},
        ]),
      );
      Map<String, dynamic>? sent;
      store.plugins.onCall = (p, m, params) async => null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 700,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('10'));
      await tester.pump();
      await tester.tap(find.text('18'));
      await tester.pump();
      // O plugin redesenha com o valor velho: a escolha não pode se perder.
      tab.view!.setBlocks(
        PluginView.blocksFrom([
          {
            'type': 'calendar',
            'id': 'periodo',
            'mode': 'range',
            'value': {'from': '2026-09-22', 'to': '2026-09-22'},
            'max': '2026-09-23',
          },
          {'type': 'button', 'action': 'ir', 'label': 'ir'},
        ]),
      );
      store.notifyListeners();
      await tester.pump();
      final state = tester.state(find.byType(PluginPane));
      sent = (state as dynamic).debugValues as Map<String, dynamic>;
      expect(sent['periodo'], {'from': '2026-09-10', 'to': '2026-09-18'});
    });
  });

  group('o seletor', () {
    Map<String, dynamic> device({required bool scanning, String value = 'emu'}) => {
      'type': 'select',
      'id': 'device',
      'width': 260,
      'value': value,
      'loading': scanning,
      'options': scanning
          ? [
              {'value': value, 'label': 'procurando aparelhos…'},
            ]
          : [
              {'value': '', 'label': 'aparelho automático'},
              {'value': 'emu', 'label': 'sdk gphone64 · android-arm64'},
            ],
    };

    testWidgets('procurando mostra o texto e o spinner, e depois acompanha a lista', (
      tester,
    ) async {
      final store = AppStore();
      final plugin = MxPlugin(
        dir: '/p',
        manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
      );
      final tab = store.openPluginView(
        plugin,
        'v',
        title: 'flutter',
        blocks: PluginView.blocksFrom([
          {
            'type': 'row',
            'children': [device(scanning: true)],
          },
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 300,
              child: AnimatedBuilder(
                animation: store,
                builder: (context, _) => PluginPane(store: store, tab: tab),
              ),
            ),
          ),
        ),
      );
      expect(find.text('procurando aparelhos…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // A lista chegou: o campo troca pro aparelho salvo, sem spinner.
      store.updatePluginView(
        plugin,
        'v',
        blocks: PluginView.blocksFrom([
          {
            'type': 'row',
            'children': [device(scanning: false)],
          },
        ]),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('sdk gphone64 · android-arm64'), findsOneWidget);

      // E a opção de valor vazio existe: é o "aparelho automático".
      store.updatePluginView(
        plugin,
        'v',
        blocks: PluginView.blocksFrom([
          {
            'type': 'row',
            'children': [device(scanning: false, value: '')],
          },
        ]),
      );
      await tester.pump();
      expect(find.text('aparelho automático'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('o comando declarativo', () {
    test('cada valor vai entre aspas num shell, e cru num texto', () {
      final values = {'cwd': "/repo/it's", 'title': r'x $(rm -rf ~)'};
      expect(
        AppStore.expandCommand(r'cd ${cwd} && echo ${title} ${nada}', values, quote: true),
        "cd '/repo/it'\\''s' && echo 'x \$(rm -rf ~)' \${nada}",
      );
      expect(AppStore.expandCommand(r'revise ${cwd}', values, quote: false), "revise /repo/it's");
    });
  });

  group('a janela do plugin', () {
    MxPlugin fake() => MxPlugin(
      dir: '/p',
      manifest: const PluginManifest(id: 'p', name: 'Plugin P', version: '1'),
    );

    test('uma por id: abrir de novo troca o conteúdo em vez de empilhar', () {
      final store = AppStore();
      final plugin = fake();
      final first = store.openPluginView(plugin, 'v', title: 'um', blocks: const []);
      final again = store.openPluginView(
        plugin,
        'v',
        title: 'dois',
        blocks: const [
          {'type': 'text', 'text': 'oi'},
        ],
      );
      expect(again, same(first));
      expect(store.tabs, hasLength(1));
      expect(first.title, 'dois');
      expect(first.subtitle, 'plugin · Plugin P');
      expect(first.isPassive, isTrue);
      expect(first.view!.revision, 1);
      expect(store.updatePluginView(plugin, 'outra', title: 'x'), isFalse);
      store.closePluginView(plugin, 'v');
      expect(store.tabs, isEmpty);
    });

    testWidgets('desenha todo tipo de bloco, e diz o que não conhece', (tester) async {
      final store = AppStore();
      final tab = MxTab(
        id: 'tab1',
        folder: Folder(root: '/repo', name: 'repo'),
        kind: TabKind.plugin,
        cwd: '/repo',
        branch: '',
        view: PluginView(
          pluginId: 'p',
          pluginName: 'P',
          id: 'v',
          title: 'janela',
          blocks: PluginView.blocksFrom([
            {'type': 'heading', 'text': 'Título'},
            {'type': 'text', 'text': 'corrido', 'style': 'dim'},
            {'type': 'markdown', 'text': '**negrito**'},
            {'type': 'code', 'text': 'x = 1'},
            {'type': 'divider'},
            {
              'type': 'kv',
              'items': [
                {'key': 'turnos', 'value': '3', 'tone': 'green'},
              ],
            },
            {'type': 'progress', 'value': 0.4, 'label': 'metade'},
            {
              'type': 'list',
              'items': [
                {
                  'title': 'item',
                  'subtitle': 'sub',
                  'icon': 'check',
                  'badge': 'novo',
                  'action': 'a',
                },
              ],
            },
            {'type': 'input', 'id': 'nome', 'label': 'nome', 'value': 'ana'},
            {'type': 'checkbox', 'id': 'ok', 'label': 'marcar', 'value': true},
            {
              'type': 'select',
              'id': 'cor',
              'options': [
                'azul',
                {'value': 'v', 'label': 'verde'},
              ],
              'value': 'v',
            },
            {
              'type': 'row',
              'children': [
                {'type': 'button', 'action': 'ir', 'label': 'ir', 'style': 'primary'},
                {'type': 'input', 'id': 'lado', 'placeholder': 'ao lado'},
              ],
            },
            {'type': 'carrossel'},
          ]),
        ),
      );
      store.tabs.add(tab);
      store.panes = PaneLeaf(tab.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 1400,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Título'), findsOneWidget);
      expect(find.text('ana'), findsOneWidget);
      expect(find.text('verde'), findsOneWidget);
      expect(find.text('bloco desconhecido: carrossel'), findsOneWidget);
      // Sem plugin instalado do outro lado, a faixa diz.
      expect(find.text('o plugin não está mais instalado'), findsOneWidget);

      // O plugin atualiza os blocos sem mexer no campo: o texto digitado fica.
      await tester.enterText(find.widgetWithText(TextField, 'ana'), 'bia');
      tab.view!.setBlocks([...tab.view!.blocks]);
      store.notifyListeners();
      await tester.pump();
      expect(find.text('bia'), findsOneWidget);
    });

    testWidgets('as ações de um item aparecem com o mouse em cima e mandam só a delas', (
      tester,
    ) async {
      final store = _ActionsStore();
      final tab = MxTab(
        id: 'tab1',
        folder: Folder(root: '/repo', name: 'repo'),
        kind: TabKind.plugin,
        cwd: '/repo',
        branch: '',
        view: PluginView(
          pluginId: 'p',
          pluginName: 'P',
          id: 'v',
          title: 'git',
          blocks: PluginView.blocksFrom([
            {
              'type': 'list',
              'items': [
                {
                  'title': 'main.dart',
                  'badge': 'M',
                  'action': 'diff',
                  'actions': [
                    {'action': 'descartar', 'icon': 'undo', 'tooltip': 'descartar'},
                    {'action': 'preparar', 'icon': 'add', 'tooltip': 'preparar'},
                    {'action': 'sem-icone'},
                  ],
                },
              ],
            },
          ]),
        ),
      );
      store.tabs.add(tab);
      store.panes = PaneLeaf(tab.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.add_rounded), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('main.dart')));
      await tester.pump();
      expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      // Sem ícone não vira botão.
      expect(find.byTooltip('descartar'), findsOneWidget);
      expect(find.byTooltip('preparar'), findsOneWidget);
      expect(find.byType(IconButton), findsNWidgets(3)); // os dois e o fechar do cabeçalho

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.tap(find.text('main.dart'));
      expect(store.actions, ['preparar', 'diff']);
      await mouse.removePointer();
    });

    testWidgets('o menu de um item abre no botão direito e manda a ação escolhida', (tester) async {
      final store = _ActionsStore();
      final tab = MxTab(
        id: 'tab1',
        folder: Folder(root: '/repo', name: 'repo'),
        kind: TabKind.plugin,
        cwd: '/repo',
        branch: '',
        view: PluginView(
          pluginId: 'p',
          pluginName: 'P',
          id: 'v',
          title: 'ssh',
          blocks: PluginView.blocksFrom([
            {
              'type': 'list',
              'flat': true,
              'items': [
                {
                  'title': 'LLM',
                  'action': 'conectar',
                  'menu': [
                    {'action': 'editar', 'label': 'editar…', 'icon': 'edit'},
                    {'type': 'divider'},
                    {'action': 'apagar', 'label': 'apagar', 'tone': 'red'},
                  ],
                },
              ],
            },
          ]),
        ),
      );
      store.tabs.add(tab);
      store.panes = PaneLeaf(tab.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 400,
              child: PluginPane(store: store, tab: tab, bare: true),
            ),
          ),
        ),
      );
      expect(find.text('editar…'), findsNothing, reason: 'o menu não ocupa a linha');
      await tester.tap(find.text('LLM'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('editar…'), findsOneWidget);
      expect(find.text('apagar'), findsOneWidget);
      await tester.tap(find.text('editar…'));
      await tester.pumpAndSettle();
      expect(store.actions, ['editar'], reason: 'o botão direito não é o clique da linha');
    });

    testWidgets('um console com follow false fica no topo quando as linhas chegam', (tester) async {
      final store = AppStore();
      final view = PluginView(
        pluginId: 'p',
        pluginName: 'P',
        id: 'v',
        title: 'diff',
        blocks: PluginView.blocksFrom([
          {
            'type': 'console',
            'id': 'd',
            'follow': false,
            'expand': true,
            'lines': ['linha 0'],
          },
        ]),
      );
      final tab = MxTab(
        id: 'tab1',
        folder: Folder(root: '/repo', name: 'repo'),
        kind: TabKind.plugin,
        cwd: '/repo',
        branch: '',
        view: view,
      );
      store.tabs.add(tab);
      store.panes = PaneLeaf(tab.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: PluginPane(store: store, tab: tab),
            ),
          ),
        ),
      );
      view.console('d').append([for (var i = 1; i < 300; i++) 'linha $i']);
      await tester.pumpAndSettle();
      expect(find.text('linha 0'), findsOneWidget);
      expect(find.text('linha 299'), findsNothing);
    });
  });
}

class _ActionsStore extends AppStore {
  final actions = <String>[];

  @override
  void pluginViewAction(MxTab tab, String action, Map<String, dynamic> values) =>
      actions.add(action);
}
