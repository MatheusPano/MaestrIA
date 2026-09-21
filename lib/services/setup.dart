import 'dart:io';

/// O que o Claude Code lê de uma pasta antes de começar a trabalhar nela, e
/// que até aqui só se editava por fora do maestria.
///
/// É um conjunto pequeno e conhecido de arquivos -- o `CLAUDE.md`, o
/// `.claude/settings.json`, as regras, as skills, os agentes -- mais o que o
/// time resolver guardar ao lado deles, que aqui são as decisões de
/// arquitetura em `docs/adr/`. Nenhum é difícil de escrever; o que era difícil
/// era lembrar que eles existem e o que cada um faz. Este arquivo é a lista, e
/// `ui/setup_pane.dart` é onde ela vira um painel.
///
/// Só disco: nada aqui sabe de store, de painel ou de widget. É o que deixa a
/// varredura e os modelos serem testados com uma pasta temporária.

/// Uma prateleira do painel: os arquivos que respondem à mesma pergunta.
enum SetupSection {
  /// O que o Claude lê em toda sessão: o `CLAUDE.md` e o irmão pessoal dele.
  memory,

  /// O que o harness lê, e não o modelo: permissões, hooks, variáveis, MCP.
  settings,

  /// Regras que só entram quando um arquivo que bate no glob é tocado.
  rules,

  /// Fluxos repetíveis, invocados com `/nome`.
  skills,

  /// Subagentes com prompt e ferramentas próprias.
  agents,

  /// As decisões de arquitetura, uma por arquivo. O Claude não as lê sozinho:
  /// é o `CLAUDE.md` que aponta pra elas.
  decisions;

  String get label => switch (this) {
    SetupSection.memory => 'memória',
    SetupSection.settings => 'configuração',
    SetupSection.rules => 'regras',
    SetupSection.skills => 'skills',
    SetupSection.agents => 'agentes',
    SetupSection.decisions => 'decisões (ADR)',
  };

  /// O que a prateleira é, dito uma vez, pra quem nunca viu uma. Aparece no
  /// painel quando a prateleira está vazia -- é o momento em que a pergunta
  /// "pra que serve isto?" é feita.
  String get about => switch (this) {
    SetupSection.memory =>
      'O que o Claude lê no começo de toda sessão nesta pasta. Curto e '
          'prescritivo rende mais que descritivo: comandos exatos, convenções '
          'que não se deduzem do código, armadilhas conhecidas.',
    SetupSection.settings =>
      'O que o harness lê, não o modelo: permissões pré-aprovadas, hooks que '
          'rodam antes ou depois de uma ação, variáveis de ambiente e '
          'servidores MCP.',
    SetupSection.rules =>
      'Regras que só carregam quando um arquivo que bate no glob delas é '
          'tocado. É o que mantém o CLAUDE.md enxuto: o que só importa em '
          '`test/` fica num arquivo que só entra lá.',
    SetupSection.skills =>
      'Fluxos repetíveis, invocados com /nome: gerar a release, subir o app '
          'na VM, fazer o DMG. Cada uma é uma pasta com um SKILL.md dentro.',
    SetupSection.agents =>
      'Subagentes com prompt e ferramentas próprias, pra revisão com um '
          'checklist fixo ou uma busca que não precisa do contexto inteiro.',
    SetupSection.decisions =>
      'Uma decisão de arquitetura por arquivo: contexto, decisão, '
          'consequências. Vale sobretudo pra decisão contra-intuitiva, a que o '
          'Claude tenderia a "corrigir" sem saber. Ele não lê esta pasta '
          'sozinho -- aponte pra ela no CLAUDE.md.',
  };

  /// A explicação inteira, em markdown, pra quem clicou no `?`: o que a coisa
  /// é, quando usar, e um exemplo concreto. O [about] é o resumo de uma frase;
  /// isto é o que se lê quando a frase não bastou.
  String get help => switch (this) {
    SetupSection.memory =>
      '''
## O que é

O `CLAUDE.md` é o texto que o Claude Code lê **no começo de toda sessão** aberta nesta pasta, antes da sua primeira mensagem. É o jeito de dizer uma vez o que você repetiria em toda conversa.

Ele fica na raiz do repo e vai no git: é do time. O `CLAUDE.md` da sua pasta pessoal (`~/.claude/CLAUDE.md`) vale pra todos os projetos; este vale só aqui, e os dois são lidos juntos. Também dá pra ter um `CLAUDE.md` dentro de uma subpasta, que só entra quando o Claude mexe em arquivos de lá.

O `CLAUDE.local.md` é o irmão que **não vai no git**: caminho de máquina, preferência sua, anotação que não é do time. Acrescente-o ao `.gitignore`.

## O que colocar

Curto e prescritivo rende mais que descritivo. O que vale:

- **Comandos exatos** de build, teste e lint. "rode `flutter test`" evita que ele descubra sozinho a cada vez.
- **Convenções** que não se deduzem do código: padrão de commit, de branch, de nome.
- **Armadilhas**: "não rode X, use Y", "o módulo Z depende de W".
- **Um mapa curto** das pastas: cinco a dez linhas sobre onde mora o quê.
- **Um ponteiro** pras decisões em `docs/adr/`, se você as escreve.

O que não vale: despejar a arquitetura inteira. Passando de umas duzentas linhas o sinal se perde no ruído, e o que importa deixa de ser lido.

## Puxar outro arquivo: o `@`

Uma linha com `@caminho` dentro do `CLAUDE.md` traz o conteúdo daquele arquivo pro contexto, como se estivesse colado ali. É o jeito de o `CLAUDE.md` ficar curto e ainda assim carregar o que importa:

```markdown
Convenções de commit: @docs/commits.md
Decisões de arquitetura: @docs/adr/README.md
```

O caminho é relativo ao `CLAUDE.md`, e vale `~/` pra pasta pessoal. Importação dentro de importação também funciona, até uns cinco níveis.

## Exemplo

```markdown
# maestria

## Comandos
- testes: /caminho/do/fvm/flutter test
- analyze: /caminho/do/fvm/flutter analyze

## Convenções
- commit: `TASK#123 add ...`, uma linha, sem corpo

## Armadilhas
- `flutter` no PATH é alias do zsh; use o binário do fvm
```
''',
    SetupSection.settings =>
      '''
## O que é

O `.claude/settings.json` é lido pelo **harness** do Claude Code, não pelo modelo. Onde o `CLAUDE.md` é uma instrução que o Claude *pode* seguir, isto é uma regra que a ferramenta *faz cumprir*. Vai no git.

O `settings.local.json` é o mesmo formato, só desta máquina, e o Claude Code já o põe no `.gitignore`. É pra onde vão as permissões que você aprova clicando em "sempre permitir".

## O que dá pra configurar

- **Permissões**: `allow` e `deny` de comandos e ferramentas. `"Bash(flutter test:*)"` deixa rodar testes sem perguntar. `"Read(./.env)"` em `deny` impede de ler o arquivo.
- **Hooks**: scripts que rodam antes ou depois de uma ação, por exemplo `dart format` depois de toda edição, ou um lint que bloqueia o commit se falhar. Os eventos são `PreToolUse`, `PostToolUse`, `Stop`, `Notification` e outros.
- **Variáveis de ambiente** em `env`, pra toda sessão desta pasta.
- **Modelo padrão** e outras opções do harness.

## Exemplo

```json
{
  "permissions": {
    "allow": ["Bash(flutter test:*)", "Bash(flutter analyze:*)"],
    "deny": ["Read(./.env)"]
  },
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{ "type": "command", "command": "dart format \$CLAUDE_FILE_PATHS" }]
    }]
  }
}
```

## O .mcp.json: MCP

**MCP** é o *Model Context Protocol*: um padrão pra dar ao Claude ferramentas de fora, e contexto de fora. Um servidor MCP é um programa pequeno que expõe ferramentas (consultar um banco, abrir uma task no tracker, ler um Figma), e o Claude passa a poder chamá-las como chama `Read` ou `Bash`.

O `.mcp.json` na raiz lista os servidores **deste projeto**, e vai no git: quem clona ganha as mesmas ferramentas, e cada pessoa aprova na primeira sessão. Os seus servidores pessoais ficam em `~/.claude.json`, fora daqui.

```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/app"]
    },
    "wiboor": {
      "type": "http",
      "url": "https://api.wiboor.com/mcp",
      "headers": { "Authorization": "Bearer \${WIBOOR_TOKEN}" }
    }
  }
}
```

Um servidor pode ser um comando local (`command` + `args`) ou um endereço (`type: http` ou `sse`). `\${VAR}` puxa da variável de ambiente, pra o token não ir pro git.
''',
    SetupSection.rules =>
      '''
## O que é

Uma regra é um pedaço de `CLAUDE.md` que **só entra no contexto quando é preciso**. Cada `.md` em `.claude/rules/` pode dizer, no cabeçalho, a quais arquivos ele se aplica; quando o Claude lê ou edita um arquivo que bate no glob, a regra é carregada. Sem `paths`, ela entra sempre, como se fosse parte do `CLAUDE.md`.

É o que mantém o `CLAUDE.md` enxuto: o que só importa em `test/` fica num arquivo que só aparece quando se está em `test/`.

## O frontmatter

O bloco entre os dois `---` no topo do arquivo é o **frontmatter**: um cabeçalho em YAML com dados *sobre* o arquivo, que o Claude Code lê antes do texto. Aqui ele tem um campo só:

- `paths`: lista de globs. `test/**` é tudo dentro de `test/`; `lib/ui/*.dart` é só o primeiro nível de `lib/ui/`. A regra entra quando um arquivo que bate em algum deles é lido ou editado.

Sem frontmatter, a regra vale sempre.

## Quando usar

- Convenções de uma parte só do repo: como escrever um teste, como é um widget aqui, o que um migration precisa ter.
- Um `CLAUDE.md` que passou de duzentas linhas e quer ser repartido.
- Instruções que se organizam em subpastas, que o Claude Code lê do mesmo jeito.

## Exemplo

`.claude/rules/tests.md`:

```markdown
---
paths:
  - "test/**"
---

# Testes

- Um `group` por comportamento, nomes em português, na primeira pessoa do que o código faz.
- Nada de `pumpAndSettle` com animação infinita: use `pump` com duração.
- Store sob teste sempre com `addTearDown(store.dispose)`.
```
''',
    SetupSection.skills =>
      '''
## O que é

Uma skill é um **fluxo com nome**, que você invoca digitando `/nome` na sessão, ou que o Claude escolhe sozinho quando o seu pedido bate na descrição dela. Cada uma é uma pasta em `.claude/skills/` com um `SKILL.md` dentro; o cabeçalho diz o nome e quando ela vale, o corpo diz o passo a passo.

A diferença pra um parágrafo no `CLAUDE.md`: a skill só é lida quando chamada, então pode ser longa e detalhada sem custar contexto nas outras conversas. E pode levar arquivos junto na mesma pasta: um script, um modelo, uma referência.

## O frontmatter

O bloco entre os dois `---` no topo do `SKILL.md` é o **frontmatter**: um cabeçalho em YAML que o Claude Code lê pra saber o que a skill é *sem* ler o corpo dela. É por ele que a skill aparece no `/` e é escolhida sozinha.

- `name`: o nome depois da barra. Minúsculas e hífens.
- `description`: **quando** usar. É o texto que o Claude compara com o seu pedido pra decidir invocar a skill por conta própria; escreva os gatilhos ("use quando o pedido for fechar versão, gerar DMG ou publicar").
- `allowed-tools` (opcional): as ferramentas que a skill pode usar sem perguntar, como `Bash(git *)`.
- `disable-model-invocation` (opcional): `true` deixa a skill só pro `/nome` digitado, sem o Claude escolhê-la sozinho. Pra o que não pode rodar sem você pedir.

## Quando usar

Tudo que você faz repetidas vezes e sempre do mesmo jeito:

- gerar a release: bump de versão, changelog, tag, DMG;
- subir o app numa VM pra reproduzir um bug;
- fazer a revisão de um PR com o checklist do time;
- montar um relatório com formato fixo.

## Exemplo

`.claude/skills/release/SKILL.md`:

```markdown
---
name: release
description: Gera uma release do maestria. Use quando o pedido for fechar versão, gerar DMG ou publicar.
---

# Release

1. Confirme que `flutter analyze` e `flutter test` passam.
2. Suba a versão em `pubspec.yaml` e peça o número novo se não foi dito.
3. Rode `packaging/macos/make-dmg.sh`.
4. Commit em uma linha, no padrão do time, e tag `vX.Y.Z`.
```

Os `.md` soltos em `.claude/commands/` são o formato antigo da mesma ideia: o corpo é o prompt que `/nome` dispara. Ainda funcionam; skills fazem o mesmo com mais estrutura.
''',
    SetupSection.agents =>
      '''
## O que é

Um agente (ou **subagente**) é um segundo Claude que a sessão principal chama pra fazer uma tarefa e voltar com o resultado. Ele roda **com o próprio contexto**, o próprio prompt de sistema e a própria lista de ferramentas; a conversa principal não vê o que ele leu, só o que ele respondeu.

Isso serve pra duas coisas:

- **Não sujar o contexto.** Uma busca que abre trinta arquivos pra achar um deles enche a conversa principal de código que não vai ser usado. Feita por um agente, só a resposta volta.
- **Especializar.** Um revisor que só pode ler, com um checklist fixo, revisa melhor que a mesma sessão que acabou de escrever o código.

O Claude Code já vem com alguns (o explorador, o planejador). Os seus ficam em `.claude/agents/`, um `.md` por agente, e a sessão principal os usa quando o pedido bate na descrição, ou quando você pede pelo nome.

## O frontmatter

O bloco entre os dois `---` no topo é o **frontmatter**: o cabeçalho em YAML com os dados do agente, que a sessão principal lê pra decidir quando e como chamá-lo.

- `name`: como ele se chama.
- `description`: **quando** delegar pra ele. É o que a sessão principal lê pra decidir usá-lo; escreva como uma frase de gatilho.
- `tools`: o que ele pode usar. Um revisor sem `Edit` e sem `Write` não consegue "consertar" o que devia só apontar.
- `model`: `inherit` usa o da sessão; `haiku` deixa uma busca simples mais barata.

O corpo é o prompt de sistema dele.

## Exemplo

`.claude/agents/revisor.md`:

```markdown
---
name: revisor
description: Revisa um diff ou PR procurando bug, quebra de convenção e teste faltando. Use ao pedir revisão, code review ou "olha isso antes de eu commitar".
tools: Read, Grep, Glob, Bash
model: inherit
---

Você revisa código do maestria. Não edita nada: aponta.

Pra cada achado diga arquivo e linha, o problema em uma frase, e como reproduzir se for bug. Ordene do mais grave pro mais leve. Cheque: null safety, timers sem cancel, setState depois de dispose, e se toda mudança de comportamento tem teste.
```
''',
    SetupSection.decisions =>
      '''
## O que é

Um ADR (*Architecture Decision Record*) é **uma decisão de arquitetura por arquivo**: o contexto em que foi tomada, o que se decidiu, e o que isso custa. Fica em `docs/adr/`, numerado, e nunca é reescrito: uma decisão que muda vira um ADR novo que substitui o antigo.

Não é um formato do Claude Code, é um formato de time. Mas ajuda o Claude por um motivo específico: a decisão **contra-intuitiva**. "Por que o terminal tem um VT próprio em vez de usar a lib X?" é exatamente o tipo de coisa que uma sessão nova tenderia a "corrigir" sem saber. Com o ADR, ela lê o porquê antes.

## O detalhe que importa

O Claude **não lê esta pasta sozinho**. É o `CLAUDE.md` que tem de apontar pra ela: uma linha como "as decisões de arquitetura estão em `docs/adr/`; leia antes de mudar algo estrutural". Sem isso, os ADRs são documentação pra gente, e só.

## Exemplo

`docs/adr/0003-vt-proprio.md`:

```markdown
# ADR 0003: parser VT próprio em vez do do xterm

- **Status:** aceita
- **Data:** 2026-03-10

## Contexto
O xterm.dart perde a cor de fundo em sequências OSC compostas, e o
Claude Code as usa no cabeçalho.

## Decisão
Um parser próprio em `services/vt.dart`, só pro subconjunto que o
Claude Code emite.

## Consequências
Menos dependência, mais código nosso. Toda sequência nova precisa de
um teste em `vt_test.dart`.
```
''',
  };

  /// Se a prateleira aceita arquivos novos com o nome que você der. As duas
  /// primeiras são um conjunto fechado de nomes que o Claude Code conhece; as
  /// outras são pastas onde cada arquivo é uma entrada.
  bool get open => switch (this) {
    SetupSection.memory || SetupSection.settings => false,
    _ => true,
  };

  /// A palavra pra "criar mais um aqui", no menu e no diálogo.
  String get noun => switch (this) {
    SetupSection.memory => 'arquivo',
    SetupSection.settings => 'arquivo',
    SetupSection.rules => 'regra',
    SetupSection.skills => 'skill',
    SetupSection.agents => 'agente',
    SetupSection.decisions => 'decisão',
  };
}

/// Um arquivo do painel: onde ele mora, o que ele é, e se está lá.
class SetupSlot {
  const SetupSlot({
    required this.section,
    required this.rel,
    required this.label,
    required this.about,
    required this.exists,
    this.fixed = false,
  });

  final SetupSection section;

  /// O caminho a partir da raiz da pasta. É a identidade: é o que o painel
  /// guarda como "o que está selecionado", e o que o config leva.
  final String rel;

  /// Como ele aparece na lista. O basename na maior parte dos casos; o nome
  /// da pasta pra uma skill, que é sempre `SKILL.md` por dentro.
  final String label;

  /// Uma frase sobre o que este arquivo faz. Aparece em cima do editor.
  final String about;

  final bool exists;

  /// Um dos nomes que o Claude Code conhece de antemão: aparece na lista
  /// mesmo sem existir, porque a oferta de criá-lo é metade do painel. Os
  /// descobertos só aparecem existindo.
  final bool fixed;

  /// Se é json e não markdown -- muda a fonte do editor e o modelo.
  bool get isJson => rel.endsWith('.json');
}

/// O que um painel de configuração mostra: a pasta, e o arquivo dela que está
/// aberto no editor.
///
/// Mutável pelo mesmo motivo de [MxDoc]: um painel é um lugar.
class MxSetup {
  MxSetup({required this.root, this.selected});

  /// A raiz onde os arquivos moram. A da pasta, ou o checkout de uma
  /// worktree -- que é outra raiz, com o mesmo `CLAUDE.md` versionado e um
  /// `settings.local.json` só dele.
  String root;

  /// O [SetupSlot.rel] aberto no editor, ou null com nada escolhido.
  String? selected;

  String get name => root.split('/').last;

  void become(MxSetup other) {
    root = other.root;
    selected = other.selected;
  }

  Map<String, dynamic> toJson() => {
    'root': root,
    if (selected != null) 'selected': selected,
  };

  static MxSetup? fromJson(Map<String, dynamic> j) {
    final root = (j['root'] as String?)?.trim();
    // Sem raiz não há o que varrer -- melhor não voltar.
    if (root == null || root.isEmpty) return null;
    return MxSetup(root: root, selected: j['selected'] as String?);
  }
}

/// A varredura e a escrita. Tudo estático e tudo sobre uma raiz dada.
abstract final class ClaudeSetup {
  /// Os arquivos de nome fixo, na ordem em que a lista os mostra.
  static const _fixed = <(SetupSection, String, String)>[
    (
      SetupSection.memory,
      'CLAUDE.md',
      'Carregado em toda sessão e versionado com o repo. Comandos de build e '
          'teste, convenções, armadilhas, um mapa curto das pastas.',
    ),
    (
      SetupSection.memory,
      'CLAUDE.local.md',
      'O mesmo, só seu: não vai no git. Pra caminho de máquina, preferência '
          'pessoal e anotação que não é do time.',
    ),
    (
      SetupSection.settings,
      '.claude/settings.json',
      'Permissões, hooks e variáveis de ambiente do projeto, versionados. É '
          'o que o time inteiro compartilha.',
    ),
    (
      SetupSection.settings,
      '.claude/settings.local.json',
      'O mesmo, só desta máquina: não vai no git. Onde as permissões que '
          'você aprovou vão parar.',
    ),
    (
      SetupSection.settings,
      '.mcp.json',
      'Os servidores MCP do projeto, versionados -- as ferramentas de fora '
          'que toda sessão aqui ganha.',
    ),
  ];

  /// O caminho absoluto de um [SetupSlot.rel].
  static String pathOf(String root, String rel) => '$root/$rel';

  /// Tudo que o painel lista nesta raiz: os fixos, existam ou não, e os
  /// descobertos nas pastas abertas.
  static List<SetupSlot> scan(String root) {
    final out = <SetupSlot>[];
    for (final (section, rel, about) in _fixed) {
      out.add(
        SetupSlot(
          section: section,
          rel: rel,
          label: rel.split('/').last,
          about: about,
          exists: File(pathOf(root, rel)).existsSync(),
          fixed: true,
        ),
      );
    }
    out.addAll(_files(root, SetupSection.rules, '.claude/rules', about: _ruleAbout));
    out.addAll(_skills(root));
    // Os comandos são as skills de antes: um `.md` solto em `.claude/commands/`
    // ainda vira `/nome`. Na mesma prateleira, porque respondem à mesma
    // pergunta.
    out.addAll(_files(root, SetupSection.skills, '.claude/commands', about: _commandAbout));
    out.addAll(_files(root, SetupSection.agents, '.claude/agents', about: _agentAbout));
    out.addAll(_files(root, SetupSection.decisions, 'docs/adr', about: _adrAbout));
    return out;
  }

  static const _ruleAbout =
      'Entra no contexto quando um arquivo que bate no `paths` do cabeçalho é '
      'lido ou editado. Sem `paths`, entra sempre.';
  static const _commandAbout =
      'Um comando de barra do jeito antigo: o corpo é o prompt que /nome '
      'dispara. Skills fazem o mesmo com mais estrutura.';
  static const _agentAbout =
      'Um subagente: o cabeçalho diz nome, quando usá-lo e com que '
      'ferramentas; o corpo é o prompt de sistema dele.';
  static const _adrAbout =
      'Uma decisão: o contexto em que foi tomada, o que se decidiu e o que '
      'isso custa. Curta, e nunca reescrita -- uma decisão nova é outro ADR.';

  /// Os `.md` de uma pasta, em ordem de nome. Recursivo, porque regras podem
  /// se organizar em subpastas e o Claude Code as lê do mesmo jeito.
  static List<SetupSlot> _files(
    String root,
    SetupSection section,
    String dir, {
    required String about,
  }) {
    final at = Directory(pathOf(root, dir));
    if (!at.existsSync()) return const [];
    final files =
        at
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final f in files)
        SetupSlot(
          section: section,
          rel: _relOf(root, f.path),
          label: _relOf(pathOf(root, dir), f.path),
          about: about,
          exists: true,
        ),
    ];
  }

  /// Uma skill é uma pasta com `SKILL.md` dentro. A lista mostra o nome da
  /// pasta, que é o nome com que ela se invoca.
  static List<SetupSlot> _skills(String root) {
    final at = Directory(pathOf(root, '.claude/skills'));
    if (!at.existsSync()) return const [];
    final dirs = at.listSync(followLinks: false).whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final d in dirs)
        if (File('${d.path}/SKILL.md').existsSync())
          SetupSlot(
            section: SetupSection.skills,
            rel: _relOf(root, '${d.path}/SKILL.md'),
            label: d.path.split('/').last,
            about:
                'Um fluxo com nome: o cabeçalho diz quando ele vale, o corpo '
                'diz o passo a passo. Invocado com /${d.path.split('/').last}.',
            exists: true,
          ),
    ];
  }

  static String _relOf(String root, String path) {
    final base = root.endsWith('/') ? root : '$root/';
    return path.startsWith(base) ? path.substring(base.length) : path;
  }

  // --- escrita -------------------------------------------------------------

  /// Lê o arquivo, ou vazio se ele não está lá.
  static Future<String> read(String root, String rel) async {
    final file = File(pathOf(root, rel));
    if (!file.existsSync()) return '';
    try {
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// Escreve, criando as pastas do caminho. Um `settings.json` novo precisa
  /// de um `.claude/` que quase nunca existe ainda.
  static Future<void> write(String root, String rel, String text) async {
    final file = File(pathOf(root, rel));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  /// Apaga o arquivo -- e a pasta da skill, que sem o `SKILL.md` não é nada.
  static Future<void> remove(String root, String rel) async {
    final file = File(pathOf(root, rel));
    if (rel.startsWith('.claude/skills/') && rel.endsWith('/SKILL.md')) {
      final dir = file.parent;
      if (dir.existsSync()) await dir.delete(recursive: true);
      return;
    }
    if (file.existsSync()) await file.delete();
  }

  // --- arquivos novos ------------------------------------------------------

  /// O nome como vai pro disco: minúsculas, hífens, sem acento e sem espaço.
  /// É o que um `/nome` de skill aceita e o que um caminho não briga com.
  static String slug(String name) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    final buf = StringBuffer();
    for (final ch in name.trim().toLowerCase().runes) {
      final s = String.fromCharCode(ch);
      final i = from.indexOf(s);
      buf.write(i >= 0 ? to[i] : s);
    }
    return buf
        .toString()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// O próximo número de ADR: o maior `NNNN-` que já existe, mais um.
  static int nextAdr(String root) {
    final at = Directory(pathOf(root, 'docs/adr'));
    if (!at.existsSync()) return 1;
    var max = 0;
    for (final f in at.listSync().whereType<File>()) {
      final m = RegExp(r'^(\d{1,5})[-_]').firstMatch(f.path.split('/').last);
      if (m == null) continue;
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > max) max = n;
    }
    return max + 1;
  }

  /// Onde um arquivo novo de [section] com este nome mora. Null quando o
  /// nome não sobra nada depois de virar slug.
  static String? relFor(SetupSection section, String name, {required String root}) {
    final s = slug(name);
    if (s.isEmpty) return null;
    return switch (section) {
      SetupSection.rules => '.claude/rules/$s.md',
      SetupSection.skills => '.claude/skills/$s/SKILL.md',
      SetupSection.agents => '.claude/agents/$s.md',
      SetupSection.decisions => 'docs/adr/${nextAdr(root).toString().padLeft(4, '0')}-$s.md',
      SetupSection.memory || SetupSection.settings => null,
    };
  }

  /// O que um arquivo novo traz escrito. Um esqueleto, não um exemplo: o que
  /// está aqui é o que o Claude Code espera encontrar no lugar certo -- o
  /// cabeçalho da skill, as chaves do settings --, e o resto é seu.
  static String template(String rel, {required String folderName, String title = ''}) {
    final name = title.isEmpty ? rel.split('/').last.replaceAll('.md', '') : title;
    if (rel == 'CLAUDE.md') {
      return '# $folderName\n\n'
          '## Comandos\n\n'
          '- build: \n- testes: \n- lint: \n\n'
          '## Convenções\n\n'
          '- \n\n'
          '## Armadilhas\n\n'
          '- \n\n'
          '## Mapa\n\n'
          '- `lib/` — \n\n'
          '## Decisões\n\n'
          'As decisões de arquitetura estão em `docs/adr/`. Leia antes de mudar algo estrutural.\n';
    }
    if (rel == 'CLAUDE.local.md') {
      return '# $folderName — só nesta máquina\n\n'
          'Não vai no git: acrescente `CLAUDE.local.md` ao `.gitignore`.\n\n'
          '- \n';
    }
    if (rel == '.claude/settings.json' || rel == '.claude/settings.local.json') {
      return '{\n'
          '  "permissions": {\n'
          '    "allow": [],\n'
          '    "deny": []\n'
          '  },\n'
          '  "env": {},\n'
          '  "hooks": {}\n'
          '}\n';
    }
    if (rel == '.mcp.json') {
      return '{\n  "mcpServers": {}\n}\n';
    }
    if (rel.startsWith('.claude/rules/')) {
      return '---\n'
          'paths:\n'
          '  - "**/*"\n'
          '---\n\n'
          '# $name\n\n'
          '- \n';
    }
    if (rel.startsWith('.claude/skills/')) {
      final skill = rel.split('/')[2];
      return '---\n'
          'name: $skill\n'
          'description: Quando usar esta skill, em uma frase que o Claude consiga reconhecer no pedido.\n'
          '---\n\n'
          '# $skill\n\n'
          '## Passos\n\n'
          '1. \n';
    }
    if (rel.startsWith('.claude/commands/')) {
      return '# $name\n\n';
    }
    if (rel.startsWith('.claude/agents/')) {
      return '---\n'
          'name: $name\n'
          'description: Quando delegar pra este agente.\n'
          'tools: Read, Grep, Glob, Bash\n'
          'model: inherit\n'
          '---\n\n'
          'Você é \n';
    }
    if (rel.startsWith('docs/adr/')) {
      final today = DateTime.now();
      final date =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final n = RegExp(r'^(\d+)').firstMatch(rel.split('/').last)?.group(1);
      return '# ${n == null ? '' : 'ADR $n: '}$name\n\n'
          '- **Status:** proposta\n'
          '- **Data:** $date\n\n'
          '## Contexto\n\n\n'
          '## Decisão\n\n\n'
          '## Consequências\n\n';
    }
    return '';
  }
}
