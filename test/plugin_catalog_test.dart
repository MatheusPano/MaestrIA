import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/plugin_catalog.dart';
import 'package:maestria/services/plugins.dart';
import 'package:maestria/theme.dart';

import 'plugins_test.dart' show writePlugin;

/// Um repositório de plugins de mentira: um servidor local que responde o
/// `catalog.json` e os `.zip`, como as releases do GitHub responderiam.
class FakeRepo {
  FakeRepo(this.dir);

  final String dir;
  late final HttpServer server;
  final List<Map<String, dynamic>> entries = [];

  String get catalogUrl => 'http://127.0.0.1:${server.port}/catalog.json';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final name = req.uri.pathSegments.last;
      if (name == 'catalog.json') {
        req.response.write(jsonEncode({'schema': 1, 'plugins': entries}));
      } else if (File('$dir/$name').existsSync()) {
        await req.response.addStream(File('$dir/$name').openRead());
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  /// Empacota um plugin como o workflow do `maestria-plugins` faz -- a pasta
  /// dentro do zip -- e o põe no catálogo no lugar da versão anterior.
  Future<void> publish(Map<String, dynamic> manifest, {String? sha}) async {
    final id = manifest['id'] as String, version = manifest['version'] as String;
    final src = Directory('$dir/src-$id-$version')..createSync(recursive: true);
    writePlugin(src.path, id, manifest);
    final zip = '$id-$version.zip';
    final r = await Process.run('zip', ['-qr', '$dir/$zip', id], workingDirectory: src.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final sum = await Process.run('shasum', ['-a', '256', '$dir/$zip']);
    entries
      ..removeWhere((e) => e['id'] == id)
      ..add({
        'id': id,
        'name': manifest['name'] ?? id,
        'version': version,
        'maestria': manifest['maestria'] ?? 1,
        'permissions': manifest['permissions'] ?? [],
        'url': 'http://127.0.0.1:${server.port}/$zip',
        'sha256': sha ?? (sum.stdout as String).split(' ').first,
      });
  }

  Future<void> close() => server.close(force: true);
}

Future<void> git(String dir, List<String> args) async {
  final r = await Process.run('git', [
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    ...args,
  ], workingDirectory: dir);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void main() {
  late Directory tmp;
  late FakeRepo repo;
  late Plugins plugins;
  late PluginUpdates updates;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('mx-catalog-');
    repo = FakeRepo(Directory('${tmp.path}/repo').path);
    Directory(repo.dir).createSync();
    await repo.start();
    plugins = Plugins(root: '${tmp.path}/plugins')..scan();
    updates = PluginUpdates(plugins, install: plugins.commit, catalogs: [repo.catalogUrl]);
  });

  tearDown(() async {
    await repo.close();
    updates.dispose();
    plugins.dispose();
    MxThemes.extra.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Instala pelo catálogo, como o botão do diálogo.
  Future<MxPlugin> installFromCatalog(String id) async {
    final catalog = await updates.load(repo.catalogUrl);
    return plugins.commit(await updates.stageEntry(catalog.byId(id)!, repo.catalogUrl));
  }

  group('o catálogo', () {
    test('lê as entradas e deixa de fora o .zip sem sha256', () {
      final c = PluginCatalog.parse(
        'u',
        jsonEncode({
          'plugins': [
            {'id': 'a', 'version': '1.0.0', 'url': 'http://x/a.zip', 'sha256': 'AB'},
            {'id': 'b', 'version': '1.0.0', 'url': 'http://x/b.zip'},
            {'id': 'c', 'version': '0.1.0', 'git': 'https://github.com/x/c', 'ref': 'main'},
            {'id': 'd', 'version': '2.0.0', 'git': 'https://x/d', 'maestria': 99},
          ],
        }),
      );
      expect(c.plugins.map((e) => e.id), ['a', 'c', 'd']);
      expect(c.byId('a')!.sha256, 'ab');
      expect(c.byId('c')!.git, 'https://github.com/x/c');
      expect(c.byId('c')!.url, isNull);
      expect(c.byId('d')!.fits, isFalse, reason: 'pede uma API que esta janela não tem');
      expect(() => PluginCatalog.parse('u', '[]'), throwsFormatException);
    });

    test('instala só o escolhido, e guarda de onde ele veio', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await repo.publish({'id': 'mx.ssh', 'version': '1.0.0'});
      final plugin = await installFromCatalog('mx.git');
      expect(plugin.manifest!.version, '1.0.0');
      expect(plugins.all.map((p) => p.id), ['mx.git'], reason: 'o outro nem chega ao disco');
      expect(plugins.origins['mx.git'], PluginOrigin.catalog(repo.catalogUrl));
      expect(
        plugin.log.last,
        contains('mx.git-1.0.0.zip'),
        reason: 'a nota é a URL, não o rascunho',
      );
      expect(Directory('${plugins.root}/.staging').listSync(), isEmpty);
    });

    test('recusa o pacote que não confere com o sha256', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'}, sha: '0' * 64);
      await expectLater(installFromCatalog('mx.git'), throwsA(isA<PluginInstallError>()));
      expect(plugins.all, isEmpty);
      expect(Directory('${plugins.root}/.staging').listSync(), isEmpty);
    });
  });

  group('a atualização', () {
    test('a versão nova do catálogo entra sozinha', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await installFromCatalog('mx.git');
      await repo.publish({'id': 'mx.git', 'version': '1.1.0'});

      await updates.check();
      expect(plugins.byId('mx.git')!.manifest!.version, '1.1.0');
      expect(updates.available, isEmpty);
      expect(plugins.origins['mx.git'], PluginOrigin.catalog(repo.catalogUrl));
    });

    test('com o interruptor desligado, ou o plugin de fora dele, só avisa', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await installFromCatalog('mx.git');
      await repo.publish({'id': 'mx.git', 'version': '1.1.0'});

      plugins.manualUpdate.add('mx.git');
      await updates.check();
      expect(plugins.byId('mx.git')!.manifest!.version, '1.0.0');
      expect(updates.available['mx.git']!.to, '1.1.0');

      plugins.manualUpdate.clear();
      plugins.autoUpdate = false;
      await updates.check();
      expect(plugins.byId('mx.git')!.manifest!.version, '1.0.0');

      // O "atualizar" da tela.
      final u = updates.available['mx.git']!;
      await updates.finish(await updates.prepare(u));
      expect(plugins.byId('mx.git')!.manifest!.version, '1.1.0');
      expect(updates.available, isEmpty);
    });

    test('a que pede permissão nova espera o seu "confio"', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await installFromCatalog('mx.git');
      await repo.publish({
        'id': 'mx.git',
        'version': '2.0.0',
        'permissions': ['hooks'],
      });

      await updates.check();
      expect(plugins.byId('mx.git')!.manifest!.version, '1.0.0');
      expect(updates.available['mx.git']!.asksMore, isTrue);
    });

    test('o catálogo que esconde a permissão não passa: o pacote é conferido', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await installFromCatalog('mx.git');
      await repo.publish({
        'id': 'mx.git',
        'version': '2.0.0',
        'permissions': ['terminal.write'],
      });
      repo.entries.single['permissions'] = [];

      await updates.check();
      expect(plugins.byId('mx.git')!.manifest!.version, '1.0.0');
      expect(updates.available['mx.git']!.asksMore, isTrue);
      expect(Directory('${plugins.root}/.staging').listSync(), isEmpty);
    });

    test('de um repositório de git, pelo commit novo', () async {
      final src = writePlugin(tmp.path, 'lucas.git', {'id': 'com.lucas.foo', 'version': '0.1.0'});
      await git(src.path, ['init', '-q', '-b', 'main']);
      await git(src.path, ['add', '.']);
      await git(src.path, ['commit', '-qm', 'um']);

      await plugins.commit(await plugins.stage(src.path));
      expect(plugins.origins['com.lucas.foo'], PluginOrigin.git(src.path));

      await updates.check();
      expect(updates.available, isEmpty, reason: 'nada mudou');

      File(
        '${src.path}/$mxManifestName',
      ).writeAsStringSync(jsonEncode({'id': 'com.lucas.foo', 'version': '0.2.0'}));
      await git(src.path, ['commit', '-qam', 'dois']);
      await updates.check();
      expect(plugins.byId('com.lucas.foo')!.manifest!.version, '0.2.0');
    });

    test('um plugin de git que entrou no catálogo é oferecido a ele', () async {
      final src = writePlugin(tmp.path, 'lucas.git', {'id': 'com.lucas.foo', 'version': '0.1.0'});
      await git(src.path, ['init', '-q', '-b', 'main']);
      await git(src.path, ['add', '.']);
      await git(src.path, ['commit', '-qm', 'um']);
      await plugins.commit(await plugins.stage(src.path));
      await repo.publish({'id': 'com.lucas.foo', 'version': '0.1.0'});

      await updates.check();
      final offer = updates.offers['com.lucas.foo']!;
      expect(offer.newer, isFalse);
      await updates.finish(await updates.prepare(offer));
      expect(plugins.origins['com.lucas.foo'], PluginOrigin.catalog(repo.catalogUrl));
      expect(updates.offers, isEmpty);
    });

    test('o de desenvolvimento nunca é tocado', () async {
      final dev = writePlugin(tmp.path, 'dev', {'id': 'mx.git', 'version': '0.0.1'});
      await plugins.link(dev.path);
      await repo.publish({'id': 'mx.git', 'version': '9.0.0'});
      await updates.check();
      expect(updates.available, isEmpty);
      expect(updates.offers, isEmpty);
    });
  });

  group('o config', () {
    test('guarda as origens e o interruptor, e esquece quem foi removido', () async {
      await repo.publish({'id': 'mx.git', 'version': '1.0.0'});
      await installFromCatalog('mx.git');
      plugins.autoUpdate = false;
      plugins.manualUpdate.add('mx.git');

      final json = jsonDecode(jsonEncode(plugins.toJson()));
      final again = Plugins(root: plugins.root)..load(json);
      expect(again.autoUpdate, isFalse);
      expect(again.manualUpdate, {'mx.git'});
      expect(again.origins['mx.git'], PluginOrigin.catalog(repo.catalogUrl));
      expect(Plugins(root: plugins.root)..load({}), predicate<Plugins>((p) => p.autoUpdate));

      // Trocar por uma pasta é deixar de receber do catálogo.
      final folder = writePlugin(tmp.path, 'pasta', {'id': 'mx.git', 'version': '1.0.1'});
      await plugins.commit(await plugins.stage(folder.path));
      expect(plugins.origins, isEmpty);

      await plugins.uninstall(plugins.byId('mx.git')!);
      expect(plugins.manualUpdate, isEmpty);
    });
  });
}
