import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/setup.dart';
import 'package:maestria/services/store.dart';

/// Uma pasta de repo de mentira, apagada no fim de cada teste.
late Directory repo;

void main() {
  setUp(() => repo = Directory.systemTemp.createTempSync('maestria-setup-'));
  tearDown(() => repo.deleteSync(recursive: true));

  group('a varredura de uma pasta', () {
    test('lista os arquivos fixos mesmo quando nenhum existe', () {
      final slots = ClaudeSetup.scan(repo.path);
      final rels = slots.map((s) => s.rel).toList();
      expect(rels, contains('CLAUDE.md'));
      expect(rels, contains('.claude/settings.json'));
      expect(rels, contains('.mcp.json'));
      // Nenhum está lá: a lista é a oferta de criá-los.
      expect(slots.every((s) => !s.exists), isTrue);
      expect(slots.every((s) => s.fixed), isTrue);
    });

    test('vê o que existe e descobre regras, skills, agentes e ADRs', () {
      File('${repo.path}/CLAUDE.md').writeAsStringSync('# oi');
      File('${repo.path}/.claude/rules/tests.md').createSync(recursive: true);
      File('${repo.path}/.claude/skills/release/SKILL.md').createSync(recursive: true);
      // Uma pasta em skills sem SKILL.md não é uma skill.
      Directory('${repo.path}/.claude/skills/vazia').createSync(recursive: true);
      File('${repo.path}/.claude/agents/revisor.md').createSync(recursive: true);
      File('${repo.path}/docs/adr/0001-flutter.md').createSync(recursive: true);

      final slots = ClaudeSetup.scan(repo.path);
      final byRel = {for (final s in slots) s.rel: s};

      expect(byRel['CLAUDE.md']!.exists, isTrue);
      expect(byRel['CLAUDE.local.md']!.exists, isFalse);
      expect(byRel['.claude/rules/tests.md']!.section, SetupSection.rules);
      expect(byRel['.claude/skills/release/SKILL.md']!.label, 'release');
      expect(byRel.keys.where((r) => r.contains('vazia')), isEmpty);
      expect(byRel['.claude/agents/revisor.md']!.section, SetupSection.agents);
      expect(byRel['docs/adr/0001-flutter.md']!.section, SetupSection.decisions);
    });
  });

  group('arquivos novos', () {
    test('o nome vira slug, e o caminho depende da prateleira', () {
      expect(ClaudeSetup.slug('Gerar Release  do App!'), 'gerar-release-do-app');
      expect(ClaudeSetup.slug('Decisão sobre PTY'), 'decisao-sobre-pty');
      expect(ClaudeSetup.slug('***'), '');

      expect(
        ClaudeSetup.relFor(SetupSection.rules, 'testes', root: repo.path),
        '.claude/rules/testes.md',
      );
      expect(
        ClaudeSetup.relFor(SetupSection.skills, 'release', root: repo.path),
        '.claude/skills/release/SKILL.md',
      );
      expect(
        ClaudeSetup.relFor(SetupSection.agents, 'Revisor', root: repo.path),
        '.claude/agents/revisor.md',
      );
      // As prateleiras fechadas não criam arquivo novo.
      expect(ClaudeSetup.relFor(SetupSection.memory, 'x', root: repo.path), isNull);
      expect(ClaudeSetup.relFor(SetupSection.rules, '!!!', root: repo.path), isNull);
    });

    test('um ADR ganha o próximo número da sequência', () {
      expect(ClaudeSetup.nextAdr(repo.path), 1);
      File('${repo.path}/docs/adr/0001-a.md').createSync(recursive: true);
      File('${repo.path}/docs/adr/0007-b.md').createSync(recursive: true);
      File('${repo.path}/docs/adr/README.md').createSync(recursive: true);
      expect(ClaudeSetup.nextAdr(repo.path), 8);
      expect(
        ClaudeSetup.relFor(SetupSection.decisions, 'usar PTY próprio', root: repo.path),
        'docs/adr/0008-usar-pty-proprio.md',
      );
    });

    test('escrever cria as pastas do caminho, e apagar uma skill leva a pasta', () async {
      await ClaudeSetup.write(repo.path, '.claude/settings.json', '{}');
      expect(File('${repo.path}/.claude/settings.json').readAsStringSync(), '{}');

      await ClaudeSetup.write(repo.path, '.claude/skills/x/SKILL.md', '---\nname: x\n---');
      await ClaudeSetup.write(repo.path, '.claude/skills/x/extra.txt', 'y');
      await ClaudeSetup.remove(repo.path, '.claude/skills/x/SKILL.md');
      expect(Directory('${repo.path}/.claude/skills/x').existsSync(), isFalse);
    });

    test('toda prateleira explica o que é, com um exemplo', () {
      for (final section in SetupSection.values) {
        expect(section.about, isNotEmpty, reason: section.name);
        expect(section.help, contains('## O que é'), reason: section.name);
        // O exemplo é a metade que a frase de uma linha não dá.
        expect(section.help, contains('```'), reason: section.name);
      }
      // O agente foi a pergunta que fez o ? existir: tem que dizer o que um
      // subagente é e o que o cabeçalho dele leva.
      expect(SetupSection.agents.help, contains('subagente'));
      expect(SetupSection.agents.help, contains('`tools`'));
    });

    test('todo arquivo conhecido tem um modelo, e o de skill traz o nome dela', () {
      for (final slot in ClaudeSetup.scan(repo.path)) {
        expect(ClaudeSetup.template(slot.rel, folderName: 'meu-repo'), isNotEmpty, reason: slot.rel);
      }
      final skill = ClaudeSetup.template('.claude/skills/release/SKILL.md', folderName: 'r');
      expect(skill, contains('name: release'));
      final adr = ClaudeSetup.template('docs/adr/0003-pty.md', folderName: 'r', title: 'PTY próprio');
      expect(adr, contains('ADR 0003: PTY próprio'));
    });
  });

  group('o painel de configuração', () {
    /// Uma sessão do claude ocupando o único painel da tela.
    MxTab session(AppStore store, Folder folder) {
      final tab = MxTab(
        id: 'tab1',
        folder: folder,
        kind: TabKind.claude,
        cwd: folder.root,
        branch: '',
      );
      store.tabs.add(tab);
      store.panes = PaneLeaf(tab.id);
      store.focusedPaneId = tab.id;
      return tab;
    }

    test('abre ao lado da sessão em foco e é um só por raiz', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final folder = Folder(root: repo.path, name: 'meu-repo');
      store.folders.add(folder);
      session(store, folder);

      final first = store.showSetup(folder: folder);
      expect(first.isSetup, isTrue);
      expect(first.isPassive, isTrue);
      expect(first.title, 'claude · ${repo.path.split('/').last}');
      expect(Panes.order(store.panes).length, 2);
      expect(store.focusedPaneId, first.id);

      // Pedir de novo é a mesma: nada novo entra na lateral nem na tela.
      final again = store.showSetup(folder: folder);
      expect(again.id, first.id);
      expect(store.tabs.where((t) => t.isSetup).length, 1);

      // Outra raiz é outro lugar.
      final other = Directory.systemTemp.createTempSync('maestria-setup-b-');
      try {
        final second = store.showSetup(folder: folder, cwd: other.path);
        expect(second.id, isNot(first.id));
        expect(store.tabs.where((t) => t.isSetup).length, 2);
      } finally {
        other.deleteSync(recursive: true);
      }
    });

    test('a receita guarda a raiz e o arquivo aberto', () {
      final setup = MxSetup(root: '/repo', selected: 'CLAUDE.md');
      final back = MxSetup.fromJson(setup.toJson());
      expect(back!.root, '/repo');
      expect(back.selected, 'CLAUDE.md');
      expect(MxSetup.fromJson(const {}), isNull);
    });
  });
}
