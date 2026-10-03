# Workspaces manuais e feature/hotfix — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O workspace passa a ser criado e mantido pela lateral (com o `.code-workspace` opcional e o mesmo repo podendo estar em vários), e o antigo "projeto" vira feature ou hotfix.

**Architecture:** O `Project` é renomeado para `FeatureOrHotfix` e ganha um `kind`. O `Workspace` ganha identidade própria (`id`) e passa a ser dono da lista das pastas dele (`folderRoots`), e o `Folder` perde o carimbo `workspace`. A ordem da raiz da lateral sai da lista de pastas e vai para um `rootOrder` próprio. O arrasto de linhas passa a carregar de onde a linha saiu (`RowPlace`), e as regras de soltura moram no `AppStore`, onde são testadas sem widget.

**Tech Stack:** Flutter 3.47.4 (via fvm), Dart 3.13, `flutter_test`. Desktop macOS/Linux.

**Spec:** `docs/superpowers/specs/2026-10-01-manual-workspaces-design.md`

## Global Constraints

- Flutter 3.47.4: rode tudo com `fvm flutter …` (o `.fvmrc` fixa a versão). `make analyze` e `make test` usam o mesmo SDK.
- Tudo que o computador lê é em inglês: nomes de arquivo, identificadores, chaves do config, valores de menu. Tudo que uma pessoa lê é em português: textos da interface, comentários, mensagens de commit.
- Comentários novos em português, no tom dos que já existem: dizem *por que*, não *o que*.
- Nomes fixados pelo Renato: `Workspace` continua `Workspace` (código e interface). `Project` vira `FeatureOrHotfix`; `projectId` vira `featureOrHotfixId`; `projects` vira `featuresOrHotfixes`.
- Na interface: "workspace" para o grupo de cima; "feature" ou "hotfix" para o de dentro.
- O config grava só as chaves novas e lê as antigas (`projects`, `projectId`, `Folder.workspace`, `Workspace.path`).
- A API de plugins não quebra: `project` na sessão e `projects.list` continuam respondendo.
- Commits sem nenhuma atribuição de IA (sem "Co-Authored-By", sem "Generated with"), com a identidade git já configurada no repositório.
- Branch: `feature/TASK#79960` (já criada). Dois commits de entrega no fim: o rename (Tasks 1–2) e os workspaces (Tasks 3–8); os commits por tarefa podem ser feitos e depois agrupados, ou mantidos, como o Renato preferir na revisão.

## Review Focus

1. **Config real de 2.4.0 com pastas carimbadas e um workspace importado** — depois da migração, as mesmas pastas aparecem dentro da mesma seção, na mesma posição da lateral, e as features continuam penduradas nas pastas certas. (Teste na Task 3, `readSidebar` com a fixture.)
2. **Tirar a última pasta de um workspace criado na mão** — o workspace continua na lateral com "0 pastas"; não some. (Teste na Task 3.)
3. **Fechar um workspace que tem uma pasta espelhada em outro** — a pasta espelhada continua no outro workspace, com as sessões abertas. (Teste na Task 3.)
4. **Soltar uma pasta exatamente na borda do cabeçalho de um workspace** — reordena; não entra no workspace. (Teste na Task 5.)
5. **Grupo de painéis salvo antes do rename (`projectId` na receita)** — abrir o grupo devolve os painéis na feature certa. (Teste na Task 1, `featureOrHotfixIdIn`.)

---

## Mapa de arquivos

| Arquivo | Muda o quê |
|---|---|
| `lib/models.dart` | `Project` → `FeatureOrHotfix` + `FeatureOrHotfixKind`; `Workspace` novo formato; `Folder` sem `workspace`; `newWorkspaceId()` |
| `lib/services/store.dart` | renomes; `readSidebar`; `featureOrHotfixIdIn`; `rootOrder`; `RowPlace`; operações de workspace; `chosenTintOf` |
| `lib/ui/sidebar.dart` | renomes; `part 'sidebar_workspaces.dart'`; `_FolderGroup` com `within`; menus de pasta/avulsos/+; rodapé |
| `lib/ui/sidebar_workspaces.dart` (novo) | `_WorkspaceSection`, `_RowDrag`, `RowDragData`, menu do workspace |
| `lib/ui/dialogs.dart` | renomes; textos de feature/hotfix; `showNewWorkspace`; `confirmCloseWorkspace` |
| `lib/ui/keys.dart`, `lib/ui/flow.dart`, `lib/ui/terminal_pane.dart` | renomes |
| `lib/services/shortcuts.dart` | um texto |
| `lib/services/plugin_api.dart` | campos e métodos novos |
| `docs/plugins.md` | documentação da API |
| `test/projects_test.dart` → `test/features_or_hotfixes_test.dart` | renome + testes de `kind` |
| `test/workspace_test.dart`, `test/reorder_test.dart` | adaptados ao modelo novo + casos novos |
| `test/sidebar_workspaces_test.dart` (novo) | widget: espelho, dobra, arrasto, menus |
| `test/fixtures/config-2.4.0.json` (novo) | config de 2.4.0 para a migração |
| demais `test/*.dart` que usam `Project` | só renomes (feitos pelo script da Task 1) |

---

### Task 1: Renomear `Project` para `FeatureOrHotfix` (sem mudar comportamento)

**Files:**
- Modify: `lib/models.dart`, `lib/services/store.dart`, `lib/services/plugin_api.dart`, `lib/ui/dialogs.dart`, `lib/ui/flow.dart`, `lib/ui/keys.dart`, `lib/ui/sidebar.dart`, `lib/ui/terminal_pane.dart`
- Modify (renomes): `test/projects_test.dart` (→ `test/features_or_hotfixes_test.dart`), `test/session_done_test.dart`, `test/pane_header_test.dart`, `test/flow_test.dart`, `test/history_test.dart`, `test/search_test.dart` e qualquer outro que o analyzer apontar
- Test: `test/config_test.dart`

**Interfaces:**
- Produces: `class FeatureOrHotfix` (mesmos campos de `Project`); `MxTab.featureOrHotfixId`; no `AppStore`: `featuresOrHotfixes`, `featuresOrHotfixesOf(Folder)`, `featureOrHotfixById(String?)`, `featureOrHotfixOf(MxTab)`, `focusedFeatureOrHotfix`, `addFeatureOrHotfix(Folder, String, {String brief})`, `editFeatureOrHotfix`, `setFeatureOrHotfixTint`, `toggleFeatureOrHotfixCollapsed`, `completeFeatureOrHotfix`, `removeFeatureOrHotfix`, `filterFeaturesOrHotfixes`, `toggleFilterFeatureOrHotfix`; `assign`, `tabsIn`, `needingHumanIn` mantêm o nome. Parâmetros nomeados `project:` viram `featureOrHotfix:`. Na UI: `showNewFeatureOrHotfix`, `showFeatureOrHotfixBrief`, `showFeatureOrHotfixMenu`, `confirmCompleteFeatureOrHotfix`, `showMoveToFeatureOrHotfix`, `_FeatureOrHotfixGroup`, `_FeatureOrHotfixDrop`.
- Produces: `@visibleForTesting void readSidebar(Map<String, dynamic> j)` no `AppStore` (lê pastas, features/hotfixes e workspaces do json do config); top-level `String? featureOrHotfixIdIn(Map<String, dynamic> pane)` em `store.dart`.

- [ ] **Step 1: Escrever os testes que falham (config com chaves antigas)**

Acrescente ao fim do `main()` de `test/config_test.dart`:

```dart
  // O config que o 2.4.0 gravou chama de `projects` o que agora é
  // `featuresOrHotfixes`. Lido sem isto, a janela abriria com as pastas e sem
  // nenhuma das features.
  test('as features gravadas como `projects` voltam', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'folders': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
      'projects': [
        {'id': 'pj1', 'folderRoot': '/repo', 'name': 'permissão do google', 'brief': 'b'},
      ],
    });

    expect(store.featuresOrHotfixes.single.id, 'pj1');
    expect(store.featuresOrHotfixes.single.name, 'permissão do google');
  });

  test('e a chave nova vence a antiga quando as duas estão lá', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'folders': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
      'projects': [
        {'id': 'velho', 'folderRoot': '/repo', 'name': 'velho'},
      ],
      'featuresOrHotfixes': [
        {'id': 'novo', 'folderRoot': '/repo', 'name': 'novo'},
      ],
    });

    expect(store.featuresOrHotfixes.map((f) => f.id), ['novo']);
  });

  // Antes dos projetos existirem, `projects` era a lista de pastas.
  test('o config de antes dos projetos continua abrindo as pastas', () {
    final store = AppStore();
    addTearDown(store.dispose);

    store.readSidebar({
      'projects': [
        {'root': '/repo', 'name': 'meu-repo'},
      ],
    });

    expect(store.folders.single.root, '/repo');
    expect(store.featuresOrHotfixes, isEmpty);
  });

  // Um grupo de painéis salvo antes do rename guarda a receita com
  // `projectId`; o painel tem que voltar pra mesma feature.
  test('a receita de painel lê o id da feature pelo nome novo e pelo antigo', () {
    expect(featureOrHotfixIdIn({'featureOrHotfixId': 'a'}), 'a');
    expect(featureOrHotfixIdIn({'projectId': 'b'}), 'b');
    expect(featureOrHotfixIdIn({'featureOrHotfixId': 'a', 'projectId': 'b'}), 'a');
    expect(featureOrHotfixIdIn({}), isNull);
  });

  test('o config grava as features com a chave nova', () async {
    final store = AppStore();
    addTearDown(store.dispose);
    final folder = Folder(root: '/repo', name: 'meu-repo');
    store.folders.add(folder);
    final file = File(store.configPath);
    if (file.existsSync()) file.deleteSync();

    store.addFeatureOrHotfix(folder, 'permissão do google');
    final saved = await savedConfig(store);

    expect(saved.containsKey('projects'), isFalse);
    expect((saved['featuresOrHotfixes'] as List).single['name'], 'permissão do google');
  });
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/config_test.dart`
Expected: FAIL na compilação — `readSidebar`, `featuresOrHotfixes`, `featureOrHotfixIdIn` e `addFeatureOrHotfix` não existem.

- [ ] **Step 3: Rodar o script de renome**

Salve este script **fora do repositório** (no scratchpad da sessão) como `rename_project.pl`:

```perl
#!/usr/bin/perl -pi
# Troca os identificadores de Project pelos de FeatureOrHotfix.
#
# Fora de strings de aspas simples: assim 'projectId', 'projects',
# 'projects.list', 'project' (a API de plugins) e 'tint-project' ficam como
# estão, e são revistos à mão no passo seguinte. As linhas de comentário
# (`//` e `///`) só trocam as referências entre colchetes, como [Project.tint].
BEGIN {
  our %ids = (
    showMoveToProject      => 'showMoveToFeatureOrHotfix',
    confirmCompleteProject => 'confirmCompleteFeatureOrHotfix',
    showProjectMenu        => 'showFeatureOrHotfixMenu',
    showProjectBrief       => 'showFeatureOrHotfixBrief',
    showNewProject         => 'showNewFeatureOrHotfix',
    toggleFilterProject    => 'toggleFilterFeatureOrHotfix',
    toggleProjectCollapsed => 'toggleFeatureOrHotfixCollapsed',
    setProjectTint         => 'setFeatureOrHotfixTint',
    completeProject        => 'completeFeatureOrHotfix',
    removeProject          => 'removeFeatureOrHotfix',
    editProject            => 'editFeatureOrHotfix',
    addProject             => 'addFeatureOrHotfix',
    focusedProject         => 'focusedFeatureOrHotfix',
    projectById            => 'featureOrHotfixById',
    projectsOf             => 'featuresOrHotfixesOf',
    projectOf              => 'featureOrHotfixOf',
    filterProjects         => 'filterFeaturesOrHotfixes',
    projectId              => 'featureOrHotfixId',
    _ProjectGroup          => '_FeatureOrHotfixGroup',
    _ProjectDropState      => '_FeatureOrHotfixDropState',
    _ProjectDrop           => '_FeatureOrHotfixDrop',
    fromProject            => 'fromFeatureOrHotfix',
    Project                => 'FeatureOrHotfix',
    projects               => 'featuresOrHotfixes',
    project                => 'featureOrHotfix',
  );
  our $re = join '|', sort { length($b) <=> length($a) } keys %ids;
}
our (%ids, $re);
if (m{^\s*//}) {
  s{\[((?:AppStore\.)?)($re)(?=[\].])}{"[$1$ids{$2}"}ge;
  next;
}
s{('(?:[^'\\]|\\.)*')|\b($re)\b}{defined $1 ? $1 : $ids{$2}}ge;
# Interpolações dentro de strings: '${project.name}' e '$project'.
s{\$\{project\b}{\${featureOrHotfix}g;
s{\$project\b}{\$featureOrHotfix}g;
```

Run:

```bash
cd /Volumes/leal_storage/_development/marrow/MaestrIA
git ls-files 'lib/*.dart' 'test/*.dart' \
  | grep -v -e '^lib/services/setup.dart$' -e '^lib/services/history.dart$' \
  | xargs perl -pi <caminho-do-scratchpad>/rename_project.pl
git mv test/projects_test.dart test/features_or_hotfixes_test.dart
```

Expected: o `git diff --stat` mostra mudanças nos arquivos do mapa acima e nos testes que usavam `Project`.

- [ ] **Step 4: Ajustes à mão que o script deixa de propósito**

4a. Em `lib/services/store.dart`, no `MxTab.recipe`, a chave do json:

```dart
    if (featureOrHotfixId != null) 'featureOrHotfixId': featureOrHotfixId,
```

4b. Em `lib/services/store.dart`, logo antes da `class AppStore` (top-level), acrescente:

```dart
/// O id da feature/hotfix de uma receita de painel salva.
///
/// A receita gravada antes do rename chama o campo de `projectId`, e é isso
/// que os grupos de painéis salvos guardam até alguém salvá-los de novo. Ver
/// [MxTab.recipe].
@visibleForTesting
String? featureOrHotfixIdIn(Map<String, dynamic> pane) =>
    (pane['featureOrHotfixId'] ?? pane['projectId']) as String?;
```

e no `_openPane` troque a linha do id por:

```dart
    final featureOrHotfix = featureOrHotfixById(featureOrHotfixIdIn(pane));
```

4c. Em `lib/services/store.dart`, extraia a leitura das pastas do `_loadConfig` para um método testável. Substitua o trecho que vai de `// Before projects existed, folders were what` até `reconcileWorkspaces();` (inclusive) por `readSidebar(j);`, e acrescente o método na seção de persistência:

```dart
  /// Lê do config o que a lateral desenha: as pastas, as features/hotfixes e
  /// os workspaces.
  ///
  /// Separado do [_loadConfig] porque é aqui que moram as leituras de
  /// formatos antigos, e cada uma delas é um config de verdade que alguém tem
  /// no disco: testá-las sem montar o resto da janela é o que permite
  /// garantir que nenhuma se perca.
  @visibleForTesting
  void readSidebar(Map<String, dynamic> j) {
    // Before projects existed, folders were what `projects` meant. Reading
    // the old key keeps a config written by yesterday's build from opening
    // as an empty sidebar.
    final legacy = j['folders'] == null;
    for (final p in ((legacy ? j['projects'] : j['folders']) as List? ?? const [])) {
      folders.add(Folder.fromJson(p as Map<String, dynamic>));
    }
    if (!legacy) {
      // Até a 2.4.0 a chave era `projects`, e é o que está no disco de quem
      // atualizou.
      for (final p in ((j['featuresOrHotfixes'] ?? j['projects']) as List? ?? const [])) {
        featuresOrHotfixes.add(FeatureOrHotfix.fromJson(p as Map<String, dynamic>));
      }
    }
    for (final w in (j['workspaces'] as List? ?? const [])) {
      if (Workspace.fromJson(w) case final workspace?) workspaces.add(workspace);
    }
    reconcileWorkspaces();
  }
```

4d. Em `lib/services/store.dart`, no `_writeConfig`, a chave gravada:

```dart
          'featuresOrHotfixes': featuresOrHotfixes.map((p) => p.toJson()).toList(),
```

4e. Em `lib/services/plugin_api.dart`, confira que continuam assim (o script não toca strings): `case 'projects.list':` e `'project': store.featureOrHotfixOf(t)?.name,`. A lista do `projects.list` passa a iterar `store.featuresOrHotfixes`.

4f. Em `lib/models.dart`, troque o primeiro parágrafo do comentário da classe para dizer o que ela é agora:

```dart
/// Uma feature ou um hotfix dentro de uma pasta: "permissão do google", não
/// `learning-app-lms`. Até a 2.4.0 se chamava projeto.
```

- [ ] **Step 5: Analisar e corrigir o que sobrou**

Run: `fvm flutter analyze`
Expected: `No issues found!`. Se aparecer `Undefined name 'project'` ou parecido, é uma interpolação ou um identificador que o script não pegou: troque pelo nome novo da tabela do Step 3. Não mude textos entre aspas neste passo (eles são da Task 2).

- [ ] **Step 6: Rodar a suíte inteira**

Run: `fvm flutter test`
Expected: PASS, inclusive os 5 testes novos de `config_test.dart`. Os nomes dos testes em inglês que dizem "project" ficam como estão.

- [ ] **Step 7: Commit**

```bash
git add -A lib test
git commit -m "renomeia projeto para feature/hotfix no código, lendo as chaves antigas do config"
```

---

### Task 2: A natureza da feature/hotfix e os textos da interface

**Files:**
- Modify: `lib/models.dart`, `lib/services/store.dart`, `lib/ui/dialogs.dart`, `lib/ui/sidebar.dart`, `lib/services/shortcuts.dart`
- Test: `test/features_or_hotfixes_test.dart`

**Interfaces:**
- Consumes: tudo o que a Task 1 produz.
- Produces: `enum FeatureOrHotfixKind { feature, hotfix }` com os campos de texto abaixo e `byName(String?)`; `FeatureOrHotfix.kind`; `AppStore.addFeatureOrHotfix(Folder f, String name, {String brief = '', FeatureOrHotfixKind kind = FeatureOrHotfixKind.feature})`; `AppStore.setFeatureOrHotfixKind(FeatureOrHotfix x, FeatureOrHotfixKind kind)`; `showNewFeatureOrHotfix(BuildContext, AppStore, Folder, {FeatureOrHotfixKind kind = FeatureOrHotfixKind.feature})`.

- [ ] **Step 1: Escrever os testes que falham**

Acrescente ao `main()` de `test/features_or_hotfixes_test.dart` (o arquivo já tem `storeWithFolder`, `panel` e `pumpSidebar`):

```dart
  group('feature ou hotfix', () {
    test('a natureza sobrevive ao config, e o que não diz nada é feature', () {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      final made = store.addFeatureOrHotfix(
        store.folders.first,
        'login quebrado',
        kind: FeatureOrHotfixKind.hotfix,
      );

      expect(FeatureOrHotfix.fromJson(made.toJson()).kind, FeatureOrHotfixKind.hotfix);
      expect(made.toJson()['kind'], 'hotfix');
      // O que a 2.4.0 gravou não tem `kind`.
      expect(
        FeatureOrHotfix.fromJson({'id': 'a', 'folderRoot': '/repo', 'name': 'x'}).kind,
        FeatureOrHotfixKind.feature,
      );
    });

    test('dá pra virar hotfix depois de criado, e voltar', () {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      final made = store.addFeatureOrHotfix(store.folders.first, 'login quebrado');

      store.setFeatureOrHotfixKind(made, FeatureOrHotfixKind.hotfix);
      expect(made.kind, FeatureOrHotfixKind.hotfix);
      store.setFeatureOrHotfixKind(made, FeatureOrHotfixKind.feature);
      expect(made.kind, FeatureOrHotfixKind.feature);
    });

    testWidgets('o hotfix se diz na linha: raio e etiqueta', (tester) async {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      store.addFeatureOrHotfix(store.folders.first, 'login quebrado', kind: FeatureOrHotfixKind.hotfix);
      store.addFeatureOrHotfix(store.folders.first, 'permissão do google');

      await pumpSidebar(tester, store);

      expect(find.text('hotfix'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.byIcon(Icons.track_changes), findsOneWidget);
    });

    testWidgets('o menu da pasta oferece as duas', (tester) async {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('o que fazer com essa pasta'));
      await tester.pumpAndSettle();

      expect(find.text('nova feature…'), findsOneWidget);
      expect(find.text('novo hotfix…'), findsOneWidget);
      expect(find.text('novo projeto…'), findsNothing);
    });

    testWidgets('o menu de um hotfix fala de hotfix', (tester) async {
      final store = storeWithFolder();
      addTearDown(store.dispose);
      store.addFeatureOrHotfix(store.folders.first, 'login quebrado', kind: FeatureOrHotfixKind.hotfix);
      await pumpSidebar(tester, store);

      await tester.tap(find.byTooltip('o que fazer com esse hotfix'));
      await tester.pumpAndSettle();

      expect(find.text('concluir hotfix'), findsOneWidget);
      expect(find.text('dissolver hotfix'), findsOneWidget);
      expect(find.text('virar feature'), findsOneWidget);
    });
  });
```

Nos testes já existentes do arquivo, troque os textos que mudam de propósito:
- `find.byTooltip('o que fazer com esse projeto')` → `find.byTooltip('o que fazer com essa feature')`
- `find.text('nova task nesse projeto…')` → `find.text('nova task nessa feature…')`

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/features_or_hotfixes_test.dart`
Expected: FAIL na compilação — `FeatureOrHotfixKind` não existe.

- [ ] **Step 3: O enum e o campo, em `lib/models.dart`**

Acima da `class FeatureOrHotfix`:

```dart
/// O que uma [FeatureOrHotfix] é: trabalho novo ou correção urgente.
///
/// Só muda como ela se diz -- o nome nos menus e o glifo na linha. O briefing,
/// a cor e o ciclo de vida são os mesmos nos dois, e é por isso que é um campo
/// e não duas classes. Os textos moram aqui porque o português concorda em
/// gênero ("nessa feature", "nesse hotfix"), e cada menu que fala dela
/// escreveria a concordância de novo.
enum FeatureOrHotfixKind {
  feature(
    label: 'feature',
    newLabel: 'nova feature',
    the: 'a feature',
    inThis: 'nessa feature',
    thisOne: 'essa feature',
    ofThis: 'dessa feature',
    ofThe: 'da feature',
    dissolved: 'feature dissolvida',
    icon: Icons.track_changes,
  ),
  hotfix(
    label: 'hotfix',
    newLabel: 'novo hotfix',
    the: 'o hotfix',
    inThis: 'nesse hotfix',
    thisOne: 'esse hotfix',
    ofThis: 'desse hotfix',
    ofThe: 'do hotfix',
    dissolved: 'hotfix dissolvido',
    icon: Icons.bolt,
  );

  const FeatureOrHotfixKind({
    required this.label,
    required this.newLabel,
    required this.the,
    required this.inThis,
    required this.thisOne,
    required this.ofThis,
    required this.ofThe,
    required this.dissolved,
    required this.icon,
  });

  final String label;
  final String newLabel;
  final String the;
  final String inThis;
  final String thisOne;
  final String ofThis;
  final String ofThe;
  final String dissolved;
  final IconData icon;

  /// O outro: é o que o "virar…" do menu oferece.
  FeatureOrHotfixKind get other => this == feature ? hotfix : feature;

  /// Feature pro que não diz nada -- tudo que a 2.4.0 gravou.
  static FeatureOrHotfixKind byName(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => feature);
}
```

Na `class FeatureOrHotfix`: parâmetro `this.kind = FeatureOrHotfixKind.feature` no construtor, o campo `FeatureOrHotfixKind kind;`, `'kind': kind.name,` no `toJson` e `kind: FeatureOrHotfixKind.byName(j['kind'] as String?),` no `fromJson`.

- [ ] **Step 4: O store, em `lib/services/store.dart`**

`addFeatureOrHotfix` ganha o parâmetro `FeatureOrHotfixKind kind = FeatureOrHotfixKind.feature` e o repassa ao construtor. Logo depois de `setFeatureOrHotfixTint`, acrescente:

```dart
  /// Troca a natureza depois de criada: o "login quebrado" que parecia
  /// feature e era hotfix. Nada mais muda -- ver [FeatureOrHotfixKind].
  void setFeatureOrHotfixKind(FeatureOrHotfix featureOrHotfix, FeatureOrHotfixKind kind) {
    if (featureOrHotfix.kind == kind) return;
    featureOrHotfix.kind = kind;
    _save();
    notifyListeners();
  }
```

- [ ] **Step 5: Os textos e os glifos**

Em `lib/ui/dialogs.dart`:
- `showNewFeatureOrHotfix` ganha `{FeatureOrHotfixKind kind = FeatureOrHotfixKind.feature}`. Título: `'${kind.newLabel} em ${folder.name}'`. Dica do briefing: `'o que todo agente ${kind.ofThis} precisa saber antes de começar'`. No fim: `store.addFeatureOrHotfix(folder, label, brief: brief.text.trim(), kind: kind);`.
- Em `showFeatureOrHotfixMenu`, com `final kind = featureOrHotfix.kind;` no topo: `'nova task ${kind.inThis}…'`, `'concluir ${kind.label}'`, `'dissolver ${kind.label}'`, `title: 'renomear ${kind.label}'`, e o banner do dissolver: `'${kind.dissolved} — os painéis continuam abertos nos avulsos'` / `'${kind.dissolved} — os painéis continuam abertos na pasta'`. Antes do `mxDivider()` que precede "concluir", acrescente o item e o caso:

```dart
      mxItem(
        'kind',
        glyph: Icon(kind.other.icon, size: 14, color: Mx.fgDim),
        label: 'virar ${kind.other.label}',
      ),
```

```dart
    case 'kind':
      store.setFeatureOrHotfixKind(featureOrHotfix, kind.other);
```

- No menu do painel (linha ~333): `'cor: ${fromFeatureOrHotfix.label} — ${store.featureOrHotfixOf(tab)!.kind.ofThe}'`.
- Linha ~429: `'mover pra feature/hotfix…'`.
- No diálogo de concluir: `'não tem painel aberto ${featureOrHotfix.kind.inThis}'` e `'nada é mexido no repo: ${featureOrHotfix.kind.the} só existia aqui'`.
- Em `showMoveToFeatureOrHotfix`: `'os avulsos ainda não têm feature nem hotfix — crie pelo + da bandeja'` e `'essa pasta ainda não tem feature nem hotfix — crie pelo + da pasta'`. O glifo de cada linha da lista passa a ser `Icon(p.kind.icon, …)` no lugar de `Icons.track_changes`.
- No menu de filtros (linhas ~1581 e ~1608), o glifo de cada feature/hotfix também vira `p.kind.icon`.

Em `lib/ui/sidebar.dart`:
- `'filtrar por pasta, projeto ou estado'` → `'filtrar por pasta, feature/hotfix ou estado'`.
- No `_FeatureOrHotfixGroup`: o glifo `Icon(featureOrHotfix.kind.icon, size: 15, color: featureOrHotfix.tint?.color ?? Mx.purple)`; o tooltip do ⋯ `'o que fazer com ${featureOrHotfix.kind.thisOne}'`; e, logo depois do `Expanded` do nome, a etiqueta:

```dart
                    // A natureza só se escreve quando não é a de sempre: uma
                    // lista em que toda linha diz "feature" é uma lista em que
                    // a palavra não diz nada.
                    if (featureOrHotfix.kind == FeatureOrHotfixKind.hotfix)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          'hotfix',
                          style: TextStyle(fontSize: 10.5, color: Mx.fgFaint),
                        ),
                      ),
```

- No `_AddButton`, o tooltip com feature: `'abrir algo ${featureOrHotfix!.kind.inThis}'`.
- No `_showAddMenu`, o item `'projeto'` vira dois (e o caso trata os dois):

```dart
      if (featureOrHotfix == null) ...[
        mxDivider(),
        for (final kind in FeatureOrHotfixKind.values)
          mxItem(
            'new:${kind.name}',
            glyph: Icon(kind.icon, size: 14, color: Mx.purple),
            label: '${kind.label}…',
          ),
      ],
```

```dart
  if (choice.startsWith('new:')) {
    await showNewFeatureOrHotfix(
      context,
      store,
      folder,
      kind: FeatureOrHotfixKind.byName(choice.substring(4)),
    );
    return;
  }
```

- No `showFolderMenu` e no `_LooseMenu`, o item `'newproject'` vira os mesmos dois itens, com os rótulos `'${kind.newLabel}…'` ("nova feature…", "novo hotfix…"), e o caso `'newproject'` vira o mesmo `if (choice.startsWith('new:'))` acima (no `_LooseMenu`, com `store.loose`).

Em `lib/services/shortcuts.dart`: `'na pasta e no projeto do painel em foco'` → `'na pasta e na feature/hotfix do painel em foco'`.

Não mexa nos textos de `lib/services/setup.dart` nem no "servidor do projeto" de `lib/ui/settings.dart`: ali "projeto" é o repo para o Claude Code.

- [ ] **Step 6: Rodar os testes do arquivo**

Run: `fvm flutter test test/features_or_hotfixes_test.dart`
Expected: PASS.

- [ ] **Step 7: Conferir que nenhum texto de "projeto" sobrou por engano**

Run: `grep -rn "'[^']*projeto[^']*'" lib | grep -v -e 'lib/services/setup.dart' -e 'servidor do projeto'`
Expected: nenhuma linha.

- [ ] **Step 8: Analisar e rodar a suíte**

Run: `fvm flutter analyze && fvm flutter test`
Expected: `No issues found!` e PASS. Se algum teste antigo procurar por um texto que mudou ("novo projeto…", "o que fazer com esse projeto"), troque pelo texto novo.

- [ ] **Step 9: Commit**

```bash
git add -A lib test
git commit -m "distingue feature de hotfix ao criar e troca os textos de projeto na interface"
```

---

### Task 3: O workspace dono das pastas dele (modelo, store e migração)

**Files:**
- Modify: `lib/models.dart`, `lib/services/store.dart`, `lib/ui/dialogs.dart` (só `confirmCloseWorkspace`), `lib/ui/sidebar.dart` (só o que o analyzer exigir: `ValueKey(w.path)` → `ValueKey(w.id)`)
- Create: `test/fixtures/config-2.4.0.json`
- Test: `test/workspace_test.dart`

**Interfaces:**
- Consumes: `readSidebar` (Task 1).
- Produces em `lib/models.dart`: `String newWorkspaceId()`; `Workspace({required String id, required String name, bool collapsed, String? codeWorkspacePath, List<String>? folderRoots, Set<String>? collapsedFolders})` com `tint`; `Workspace.fromJson(Object?)` lendo o formato novo e o de 2.4.0. `Folder` sem o campo `workspace` (o construtor perde o parâmetro).
- Produces no `AppStore`: `List<Folder> foldersOf(Workspace)`, `List<Workspace> workspacesOf(Folder)`, `bool standsAlone(Folder)`, `Workspace? workspaceById(String?)`, `Workspace createWorkspace(String name, {List<Folder> folders = const [], String? codeWorkspacePath})`, `void addToWorkspace(Folder f, Workspace w, {Folder? before})`, `void removeFromWorkspace(Folder f, Workspace w, {SidebarRow? at})`, `void renameWorkspace(Workspace, String)`, `void setWorkspaceTint(Workspace, MxTint?)`, `void linkCodeWorkspace(Workspace, String?)`, `void dissolveWorkspace(Workspace)`, `List<Folder> closingWith(Workspace)`, `Future<void> closeWorkspace(Workspace)`, `bool isFolderCollapsed(Folder, {Workspace? within})`, `void toggleFolderCollapsed(Folder, {Workspace? within})`, `final List<String> rootOrder`, `String rowKey(SidebarRow)`. Remove: `workspaceOf`, `reconcileWorkspaces`.

- [ ] **Step 1: A fixture do config de 2.4.0**

Crie `test/fixtures/config-2.4.0.json`. É o formato que a 2.4.0 grava (pastas carimbadas com `workspace`, workspaces com `path`, features em `projects`):

```json
{
  "folders": [
    {"root": "/repos/atrium-backend", "name": "atrium-backend", "collapsed": false, "workspace": "/repos/atrium.code-workspace"},
    {"root": "/repos/atrium-frontend", "name": "atrium-frontend", "collapsed": true, "workspace": "/repos/atrium.code-workspace"},
    {"root": "/repos/solta", "name": "solta", "collapsed": false},
    {"root": "/repos/uplii-ai", "name": "uplii-ai", "collapsed": false, "workspace": "/repos/uplii.code-workspace"}
  ],
  "workspaces": [
    {"path": "/repos/atrium.code-workspace", "name": "atrium", "collapsed": true}
  ],
  "projects": [
    {"id": "pj1", "folderRoot": "/repos/atrium-backend", "name": "permissão do google", "brief": "", "collapsed": false}
  ]
}
```

(O `uplii` não está em `workspaces` de propósito: a 2.4.0 recriava a seção a partir do carimbo, e a migração tem que fazer o mesmo.)

- [ ] **Step 2: Escrever os testes que falham**

Em `test/workspace_test.dart`:

2a. Substitua os testes que dependem do carimbo `Folder.workspace` ou de `Workspace(path: …)`. Nos helpers `storeWith()` dos grupos `'a seção na lateral'` e `'fechar um workspace'`, monte assim:

```dart
    AppStore storeWith() {
      final store = AppStore();
      store.folders.addAll([
        Folder(root: '/repo/api', name: 'api')..isRepo = true,
        Folder(root: '/repo/solta', name: 'solta')..isRepo = true,
        Folder(root: '/repo/web', name: 'web')..isRepo = true,
      ]);
      store.workspaces.add(
        Workspace(
          id: 'ws1',
          name: 'cefis',
          codeWorkspacePath: '/repos/cefis.code-workspace',
          folderRoots: ['/repo/api', '/repo/web'],
        ),
      );
      return store;
    }
```

No grupo `'importar um workspace'`:
- `'adiciona todas as pastas de uma vez e carimba de onde vieram'`: troque `expect(store.folders.every((f) => f.workspace == path), isTrue);` por `expect(store.foldersOf(store.workspaces.single).map((f) => f.root), made);` e `expect(store.workspaces.single.codeWorkspacePath, path);`.
- `'o segundo workspace não rouba a pasta do primeiro'` vira:

```dart
    // Com o espelho, a pasta que os dois arquivos listam fica nos dois.
    test('a pasta que dois arquivos listam fica nos dois workspaces', () async {
      final (path, made) = await onDisk(['api']);
      final outro = File('${File(path).parent.path}/outro.code-workspace')
        ..writeAsStringSync('{"folders": [{"path": "${made.single}"}]}');
      final store = AppStore();
      addTearDown(store.dispose);

      await store.importWorkspace(path);
      await store.importWorkspace(outro.path);

      expect(store.folders.length, 1);
      expect(store.workspaces.length, 2);
      expect(store.workspacesOf(store.folders.single).length, 2);
    });
```

- `'o import cria a seção da lateral'`: `expect(store.workspaces.single.codeWorkspacePath, path);` no lugar de `.path`.
- `'o carimbo sobrevive à ida e volta do config'` e `'e a seção também, dobrada como estava'` viram:

```dart
    test('o workspace sobrevive à ida e volta do config', () {
      final ws = Workspace(
        id: 'ws1',
        name: 'atrium',
        collapsed: true,
        codeWorkspacePath: '/repos/atrium.code-workspace',
        folderRoots: ['/repos/a', '/repos/b'],
        collapsedFolders: {'/repos/b'},
      )..tint = MxTint.cyan;
      final back = Workspace.fromJson(ws.toJson())!;

      expect(back.id, 'ws1');
      expect(back.name, 'atrium');
      expect(back.collapsed, isTrue);
      expect(back.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(back.folderRoots, ['/repos/a', '/repos/b']);
      expect(back.collapsedFolders, {'/repos/b'});
      expect(back.tint, MxTint.cyan);
      // Sem arquivo é o caso comum agora, e o que não existe não vai pro json.
      final plain = Workspace(id: 'ws2', name: 'uplii').toJson();
      expect(plain.containsKey('codeWorkspacePath'), isFalse);
      expect(plain.containsKey('collapsed'), isFalse);
      // E o registro que não desenharia nada não volta.
      expect(Workspace.fromJson({'id': 'x'}), isNull);
      expect(Workspace.fromJson('nada'), isNull);
    });

    test('o workspace da 2.4.0 ganha id e guarda o arquivo de onde veio', () {
      final back = Workspace.fromJson({
        'path': '/repos/atrium.code-workspace',
        'name': 'atrium',
        'collapsed': true,
      })!;

      expect(back.id, isNotEmpty);
      expect(back.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(back.collapsed, isTrue);
      expect(back.folderRoots, isEmpty);
    });
```

- `'a ordem da lateral põe a seção onde a primeira pasta dela estava'`: continua igual (com o `storeWith()` novo e `rootOrder` vazio, a ordem é a derivada).
- `'tirar a última pasta desfaz a seção'` vira:

```dart
    // Um workspace criado na mão não some porque ficou vazio: seria perder o
    // ATRIUM ao tirar o último repo dele.
    test('tirar a última pasta deixa a seção vazia, e não a desfaz', () async {
      final store = storeWith();
      addTearDown(store.dispose);

      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'api'));
      await store.removeFolder(store.folders.firstWhere((f) => f.name == 'web'));

      expect(store.workspaces.single.folderRoots, isEmpty);
      expect(store.sidebarRows.whereType<Workspace>().single.name, 'cefis');
    });
```

- Os testes `'a pasta carimbada sem seção ganha uma'` e `'e a seção sem pasta nenhuma some'` são substituídos pelos de migração abaixo.

2b. Acrescente o grupo de migração e o de operações:

```dart
  group('migrar o config da 2.4.0', () {
    Map<String, dynamic> fixture() =>
        jsonDecode(File('test/fixtures/config-2.4.0.json').readAsStringSync())
            as Map<String, dynamic>;

    test('as pastas carimbadas entram no workspace do arquivo delas', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      final atrium = store.workspaces.firstWhere((w) => w.name == 'atrium');
      expect(atrium.codeWorkspacePath, '/repos/atrium.code-workspace');
      expect(atrium.folderRoots, ['/repos/atrium-backend', '/repos/atrium-frontend']);
      expect(atrium.collapsed, isTrue);
    });

    // A 2.4.0 recriava a seção a partir do carimbo quando a lista de
    // workspaces não a tinha. A migração faz o mesmo, com o nome do arquivo.
    test('o carimbo sem seção vira um workspace com o nome do arquivo', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      final uplii = store.workspaces.firstWhere((w) => w.name == 'uplii');
      expect(uplii.codeWorkspacePath, '/repos/uplii.code-workspace');
      expect(uplii.folderRoots, ['/repos/uplii-ai']);
    });

    test('a lateral fica na mesma ordem e as features nas mesmas pastas', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      expect(
        store.sidebarRows.map((r) => r is Workspace ? 'ws:${r.name}' : (r as Folder).name),
        ['ws:atrium', 'solta', 'ws:uplii'],
      );
      expect(store.featuresOrHotfixes.single.folderRoot, '/repos/atrium-backend');
    });

    test('a pasta dobrada solta continua dobrada', () {
      final store = AppStore();
      addTearDown(store.dispose);

      store.readSidebar(fixture());

      // O `collapsed` da 2.4.0 era um só por pasta; dentro de um workspace ele
      // passa a valer pra aparição naquele workspace.
      final atrium = store.workspaces.firstWhere((w) => w.name == 'atrium');
      final front = store.folders.firstWhere((f) => f.name == 'atrium-frontend');
      expect(store.isFolderCollapsed(front, within: atrium), isTrue);
    });
  });

  group('montar workspaces na mão', () {
    AppStore three() {
      final store = AppStore();
      for (final n in ['atrium-api', 'atrium-web', 'infra']) {
        store.folders.add(Folder(root: '/repos/$n', name: n));
      }
      return store;
    }

    Folder folder(AppStore s, String name) => s.folders.firstWhere((f) => f.name == name);

    test('criar com nome e pastas, sem arquivo nenhum', () {
      final store = three();
      addTearDown(store.dispose);

      final w = store.createWorkspace(
        ' ATRIUM ',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );

      expect(w.name, 'ATRIUM');
      expect(w.codeWorkspacePath, isNull);
      expect(store.foldersOf(w).map((f) => f.name), ['atrium-api', 'atrium-web']);
      expect(store.standsAlone(folder(store, 'infra')), isTrue);
      expect(store.standsAlone(folder(store, 'atrium-api')), isFalse);
    });

    test('a mesma pasta em dois workspaces aparece nos dois', () {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      final uplii = store.createWorkspace('UPLII');

      store.addToWorkspace(folder(store, 'infra'), uplii);

      expect(store.workspacesOf(folder(store, 'infra')), [atrium, uplii]);
      expect(store.foldersOf(uplii).single.name, 'infra');
    });

    test('adicionar duas vezes não repete', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('ATRIUM');

      store.addToWorkspace(folder(store, 'infra'), w);
      store.addToWorkspace(folder(store, 'infra'), w);

      expect(w.folderRoots, ['/repos/infra']);
    });

    test('entrar antes de uma pasta põe na vaga dela', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );

      store.addToWorkspace(folder(store, 'infra'), w, before: folder(store, 'atrium-web'));

      expect(store.foldersOf(w).map((f) => f.name), ['atrium-api', 'infra', 'atrium-web']);
    });

    test('tirar do último workspace devolve a pasta pra raiz, no lugar pedido', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('ATRIUM', folders: [folder(store, 'atrium-api')]);

      store.removeFromWorkspace(folder(store, 'atrium-api'), w, at: folder(store, 'infra'));

      expect(store.foldersOf(w), isEmpty);
      expect(
        store.sidebarRows.map((r) => r is Workspace ? 'ws:${r.name}' : (r as Folder).name),
        ['atrium-web', 'atrium-api', 'infra', 'ws:ATRIUM'],
      );
    });

    test('tirar de um de dois workspaces não a solta na raiz', () {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      store.removeFromWorkspace(folder(store, 'infra'), atrium);

      expect(store.standsAlone(folder(store, 'infra')), isFalse);
      expect(store.sidebarRows.whereType<Folder>().map((f) => f.name), ['atrium-api', 'atrium-web']);
    });

    test('desfazer devolve as pastas pra raiz no lugar da seção, sem fechar nada', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'atrium-web')],
      );
      store.tabs.add(
        MxTab(
          id: 't1',
          folder: folder(store, 'atrium-api'),
          kind: TabKind.shell,
          cwd: '/repos/atrium-api',
          branch: '',
        ),
      );

      store.dissolveWorkspace(w);

      expect(store.workspaces, isEmpty);
      expect(store.tabs.length, 1);
      expect(store.sidebarRows.map((r) => (r as Folder).name), ['infra', 'atrium-api', 'atrium-web']);
    });

    test('fechar leva as pastas só dele e deixa a espelhada no outro', () async {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace(
        'ATRIUM',
        folders: [folder(store, 'atrium-api'), folder(store, 'infra')],
      );
      final uplii = store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      expect(store.closingWith(atrium).map((f) => f.name), ['atrium-api']);
      await store.closeWorkspace(atrium);

      expect(store.folders.map((f) => f.name), ['atrium-web', 'infra']);
      expect(store.workspaces, [uplii]);
      expect(store.foldersOf(uplii).single.name, 'infra');
    });

    test('remover a pasta tira ela de todos os workspaces', () async {
      final store = three();
      addTearDown(store.dispose);
      final atrium = store.createWorkspace('ATRIUM', folders: [folder(store, 'infra')]);
      final uplii = store.createWorkspace('UPLII', folders: [folder(store, 'infra')]);

      await store.removeFolder(folder(store, 'infra'));

      expect(atrium.folderRoots, isEmpty);
      expect(uplii.folderRoots, isEmpty);
    });

    test('cada aparição dobra por conta própria', () {
      final store = three();
      addTearDown(store.dispose);
      final infra = folder(store, 'infra');
      final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
      final uplii = store.createWorkspace('UPLII', folders: [infra]);

      store.toggleFolderCollapsed(infra, within: atrium);

      expect(store.isFolderCollapsed(infra, within: atrium), isTrue);
      expect(store.isFolderCollapsed(infra, within: uplii), isFalse);
      expect(infra.collapsed, isFalse);
    });

    test('renomear, pintar e associar um arquivo', () {
      final store = three();
      addTearDown(store.dispose);
      final w = store.createWorkspace('atrium');

      store.renameWorkspace(w, '  ATRIUM ');
      store.setWorkspaceTint(w, MxTint.red);
      store.linkCodeWorkspace(w, '/repos/atrium.code-workspace');

      expect(w.name, 'ATRIUM');
      expect(w.tint, MxTint.red);
      expect(w.codeWorkspacePath, '/repos/atrium.code-workspace');

      store.linkCodeWorkspace(w, null);
      expect(w.codeWorkspacePath, isNull);
    });

    test('o painel sem cor pega a do primeiro workspace da pasta', () {
      final store = three();
      addTearDown(store.dispose);
      final infra = folder(store, 'infra');
      store.createWorkspace('ATRIUM', folders: [infra]).tint = MxTint.red;
      store.createWorkspace('UPLII', folders: [infra]).tint = MxTint.cyan;
      final tab = MxTab(id: 't1', folder: infra, kind: TabKind.shell, cwd: infra.root, branch: '');
      store.tabs.add(tab);

      expect(store.chosenTintOf(tab), MxTint.red);
      // E a cor da pasta, quando ela tem uma, vence a do workspace.
      store.setFolderTint(infra, MxTint.green);
      expect(store.chosenTintOf(tab), MxTint.green);
    });

    test('o config grava o workspace novo e a ordem da raiz', () async {
      final store = three();
      addTearDown(store.dispose);
      final file = File(store.configPath);
      if (file.existsSync()) file.deleteSync();

      store.createWorkspace('ATRIUM', folders: [folder(store, 'atrium-api')]);
      final saved = await savedConfig(store);

      final ws = (saved['workspaces'] as List).single as Map;
      expect(ws['name'], 'ATRIUM');
      expect(ws['folderRoots'], ['/repos/atrium-api']);
      expect(saved['rootOrder'], ['folder:/repos/atrium-web', 'folder:/repos/infra', 'workspace:${ws['id']}']);
      expect((saved['folders'] as List).every((f) => !(f as Map).containsKey('workspace')), isTrue);
    });
  });
```

No topo de `test/workspace_test.dart`, acrescente `import 'dart:convert';` e o helper `savedConfig` (o mesmo de `test/config_test.dart`):

```dart
/// O config que o store acabou de gravar. O save é debounced, então a leitura
/// espera o arquivo aparecer.
Future<Map<String, dynamic>> savedConfig(AppStore store) async {
  final file = File(store.configPath);
  for (var i = 0; i < 60 && !file.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `fvm flutter test test/workspace_test.dart`
Expected: FAIL na compilação — `Workspace(id: …)`, `createWorkspace`, `workspacesOf` etc. não existem.

- [ ] **Step 4: O modelo, em `lib/models.dart`**

4a. Na `class Folder`: apague o campo `workspace` e o comentário dele, o parâmetro `this.workspace` do construtor, o `workspace = null` do `Folder.loose`, a linha `if (workspace != null) 'workspace': workspace,` do `toJson` e o `workspace: j['workspace'] as String?,` do `fromJson`.

4b. Logo antes da `class Workspace`:

```dart
/// Um id novo de workspace. O contador vai junto do relógio porque a migração
/// de um config antigo cria vários no mesmo microssegundo.
String newWorkspaceId() =>
    'ws${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_workspaceSeq++).toRadixString(36)}';
int _workspaceSeq = 0;
```

4c. Substitua a `class Workspace` inteira por:

```dart
/// Um punhado de pastas que se trabalham juntas: os repos de um produto.
///
/// Não é dono das sessões, e é o que o separa de uma pasta: as pastas
/// continuam sendo pastas -- com as features, as worktrees e as sessões delas
/// --, e desfazer isto devolve todas pra raiz da lateral sem fechar um painel.
/// O que ele acrescenta é uma linha que dobra e um nome pro conjunto.
///
/// É dono, sim, da lista das pastas dele ([folderRoots]): uma pasta pode estar
/// em mais de um (o repo de infra de dois produtos), e cada um guarda a ordem
/// em que a desenha. A pergunta "em que workspaces está esta pasta" é
/// `AppStore.workspacesOf`.
///
/// O `.code-workspace` do VS Code é opcional ([codeWorkspacePath]): é de onde
/// um workspace pode ter vindo, e o que o "abrir no vscode" dele abre.
class Workspace with SidebarRow {
  Workspace({
    required this.id,
    required this.name,
    this.collapsed = false,
    this.codeWorkspacePath,
    List<String>? folderRoots,
    Set<String>? collapsedFolders,
  }) : folderRoots = folderRoots ?? [],
       collapsedFolders = collapsedFolders ?? {};

  /// Estável entre renomes e entre execuções: é o que o [AppStore.rootOrder]
  /// guarda.
  final String id;
  String name;
  bool collapsed;

  /// A cor do workspace, quando alguém escolheu uma. As pastas sem cor própria
  /// herdam esta -- ver `AppStore.chosenTintOf`.
  MxTint? tint;

  /// O `.code-workspace` associado, quando há um.
  String? codeWorkspacePath;

  /// As pastas deste workspace, pelo root, na ordem em que ele as desenha.
  final List<String> folderRoots;

  /// As pastas dobradas *aqui*. A mesma pasta em outro workspace dobra por
  /// conta própria; a pasta solta na raiz usa o [Folder.collapsed].
  final Set<String> collapsedFolders;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (collapsed) 'collapsed': true,
    if (tint != null) 'tint': tint!.name,
    if (codeWorkspacePath != null) 'codeWorkspacePath': codeWorkspacePath,
    'folderRoots': folderRoots,
    if (collapsedFolders.isNotEmpty) 'collapsedFolders': collapsedFolders.toList(),
  };

  /// Null pro registro que não desenharia nada: sem nome, ou sem id e sem
  /// arquivo.
  ///
  /// Lê também o formato da 2.4.0 (`{path, name, collapsed}`), em que o
  /// arquivo era a identidade: o `path` vira o [codeWorkspacePath] e o id
  /// nasce aqui. As pastas daquele formato chegam por
  /// `AppStore.readSidebar`, que lê o carimbo antigo delas.
  ///
  /// Nulo e não exceção pelo mesmo motivo de [PaneGroup.fromJson]: quem lê é o
  /// carregador do config inteiro, e um registro estragado não pode custar as
  /// pastas e o layout.
  static Workspace? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = ((j['name'] as String?) ?? '').trim();
    final id = ((j['id'] as String?) ?? '').trim();
    final legacyPath = ((j['path'] as String?) ?? '').trim();
    if (name.isEmpty || (id.isEmpty && legacyPath.isEmpty)) return null;
    return Workspace(
      id: id.isEmpty ? newWorkspaceId() : id,
      name: name,
      collapsed: (j['collapsed'] as bool?) ?? false,
      codeWorkspacePath:
          (j['codeWorkspacePath'] as String?) ?? (legacyPath.isEmpty ? null : legacyPath),
      folderRoots: [
        for (final r in j['folderRoots'] as List? ?? const [])
          if (r is String) r,
      ],
      collapsedFolders: {
        for (final r in j['collapsedFolders'] as List? ?? const [])
          if (r is String) r,
      },
    )..tint = MxTint.byName(j['tint'] as String?);
  }
}
```

- [ ] **Step 5: O store, em `lib/services/store.dart`**

5a. O comentário de `workspaces` passa a dizer que um workspace é dono das pastas dele e pode ficar vazio. Logo abaixo, o campo:

```dart
  /// A ordem da raiz da lateral: `workspace:<id>` e `folder:<root>`.
  ///
  /// Até a 2.4.0 a ordem saía da lista de pastas, com a seção no lugar da
  /// primeira pasta dela. Com a mesma pasta em dois workspaces, essa conta
  /// deixa de ter resposta. Vazio é o config de antes disto, e aí
  /// [sidebarRows] faz a conta antiga. Ver [rowKey].
  final List<String> rootOrder = [];
```

5b. No `readSidebar`, troque o `reconcileWorkspaces();` final por:

```dart
    // O carimbo da 2.4.0: a pasta dizia de que `.code-workspace` veio, e a
    // seção era o arquivo. Agora é o workspace que lista as pastas dele.
    for (final p in rawFolders) {
      final path = p['workspace'];
      if (path is! String || path.isEmpty) continue;
      var w = workspaces.firstWhereOrNull((w) => w.codeWorkspacePath == path);
      if (w == null) {
        w = Workspace(id: newWorkspaceId(), name: CodeWorkspace.nameOf(path), codeWorkspacePath: path);
        workspaces.add(w);
      }
      final root = p['root'] as String;
      if (!w.folderRoots.contains(root)) w.folderRoots.add(root);
      // O `collapsed` era um por pasta. Dentro de um workspace ele passa a ser
      // da aparição ali -- e é ali que a pasta carimbada aparecia.
      if (p['collapsed'] == true) w.collapsedFolders.add(root);
    }
    rootOrder
      ..clear()
      ..addAll([
        for (final k in j['rootOrder'] as List? ?? const [])
          if (k is String) k,
      ]);
```

e, no começo do método, guarde as pastas cruas numa lista antes do laço que cria os `Folder`:

```dart
    final rawFolders = ((legacy ? j['projects'] : j['folders']) as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    for (final p in rawFolders) {
      folders.add(Folder.fromJson(p));
    }
```

5c. No `_writeConfig`, a linha dos workspaces passa a gravar sempre e entra a ordem da raiz:

```dart
          if (workspaces.isNotEmpty) 'workspaces': workspaces.map((w) => w.toJson()).toList(),
          'rootOrder': [for (final r in sidebarRows) rowKey(r)],
```

5d. Substitua a seção `// --- workspaces ---` inteira (de `foldersOf` até o fim de `reconcileWorkspaces`, inclusive `sidebarRows`, `foldersOfRow`, `_laneOf`, `canMoveRow`, `moveRow`, `_slide`, `closeWorkspace`, `toggleWorkspaceCollapsed`) por:

```dart
  // --- workspaces ---------------------------------------------------------

  /// As pastas de um workspace, na ordem em que ele as desenha. Um root que
  /// não é mais pasta da lateral não aparece.
  List<Folder> foldersOf(Workspace w) => [
    for (final root in w.folderRoots)
      if (folders.firstWhereOrNull((f) => f.root == root) case final f?) f,
  ];

  /// Os workspaces em que a pasta está, na ordem da lista de workspaces.
  List<Workspace> workspacesOf(Folder f) =>
      workspaces.where((w) => w.folderRoots.contains(f.root)).toList();

  /// A pasta que não está em workspace nenhum: é ela que a raiz desenha.
  bool standsAlone(Folder f) => !workspaces.any((w) => w.folderRoots.contains(f.root));

  Workspace? workspaceById(String? id) =>
      id == null ? null : workspaces.firstWhereOrNull((w) => w.id == id);

  /// A chave de uma linha da raiz no [rootOrder].
  String rowKey(SidebarRow row) =>
      row is Workspace ? 'workspace:${row.id}' : 'folder:${(row as Folder).root}';

  SidebarRow? _rowOf(String key) {
    if (key.startsWith('workspace:')) return workspaceById(key.substring('workspace:'.length));
    if (key.startsWith('folder:')) {
      final f = folders.firstWhereOrNull((f) => f.root == key.substring('folder:'.length));
      return f != null && standsAlone(f) ? f : null;
    }
    return null;
  }

  /// O que a raiz da lateral desenha, de cima pra baixo: workspaces e pastas
  /// soltas.
  ///
  /// Primeiro o que o [rootOrder] conhece, na ordem dele. Depois o que ele
  /// ainda não conhece -- tudo, num config de antes dele; ou a pasta que
  /// acabou de entrar -- na conta antiga: a seção no lugar da primeira pasta
  /// dela. Uma chave que não aponta mais pra nada é pulada.
  List<SidebarRow> get sidebarRows {
    final rows = <SidebarRow>[];
    final seen = <String>{};
    void add(SidebarRow r) {
      if (seen.add(rowKey(r))) rows.add(r);
    }

    for (final key in rootOrder) {
      if (_rowOf(key) case final row?) add(row);
    }
    for (final f in folders) {
      final ws = workspacesOf(f);
      if (ws.isEmpty) {
        add(f);
      } else {
        ws.forEach(add);
      }
    }
    workspaces.forEach(add);
    return rows;
  }

  /// Grava no [rootOrder] a ordem que a lateral está desenhando agora. Toda
  /// mexida na raiz começa por aqui: é ela que transforma a conta derivada
  /// num config que já diz a ordem.
  void _pinRootOrder() {
    final keys = [for (final r in sidebarRows) rowKey(r)];
    rootOrder
      ..clear()
      ..addAll(keys);
  }

  Workspace createWorkspace(
    String name, {
    List<Folder> folders = const [],
    String? codeWorkspacePath,
  }) {
    _pinRootOrder();
    final w = Workspace(
      id: newWorkspaceId(),
      name: name.trim(),
      codeWorkspacePath: codeWorkspacePath,
    );
    workspaces.add(w);
    rootOrder.add(rowKey(w));
    for (final f in folders) {
      if (!w.folderRoots.contains(f.root)) w.folderRoots.add(f.root);
    }
    _save();
    notifyListeners();
    return w;
  }

  /// Põe [f] em [w], na vaga de [before] quando ela é dada, ou no fim.
  void addToWorkspace(Folder f, Workspace w, {Folder? before}) {
    if (w.folderRoots.contains(f.root)) return;
    _pinRootOrder();
    final at = before == null ? -1 : w.folderRoots.indexOf(before.root);
    at < 0 ? w.folderRoots.add(f.root) : w.folderRoots.insert(at, f.root);
    _save();
    notifyListeners();
  }

  /// Tira [f] de [w]. Se ela não estiver em mais nenhum, volta pra raiz: na
  /// vaga de [at], quando dada, ou logo depois do workspace de onde saiu.
  void removeFromWorkspace(Folder f, Workspace w, {SidebarRow? at}) {
    if (!w.folderRoots.contains(f.root)) return;
    _pinRootOrder();
    w.folderRoots.remove(f.root);
    w.collapsedFolders.remove(f.root);
    if (standsAlone(f)) {
      final target = at == null ? -1 : rootOrder.indexOf(rowKey(at));
      final after = rootOrder.indexOf(rowKey(w)) + 1;
      rootOrder.insert(target >= 0 ? target : after, rowKey(f));
    }
    _save();
    notifyListeners();
  }

  void renameWorkspace(Workspace w, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == w.name) return;
    w.name = trimmed;
    _save();
    notifyListeners();
  }

  /// A cor do workspace, ou null pra tirar. Ver [Workspace.tint].
  void setWorkspaceTint(Workspace w, MxTint? tint) {
    w.tint = tint;
    _save();
    notifyListeners();
  }

  /// Associa um `.code-workspace`, ou desassocia com null. Não lê o arquivo:
  /// ele diz o que o "abrir no vscode" abre, e não quais pastas entram.
  void linkCodeWorkspace(Workspace w, String? path) {
    final clean = path?.trim();
    w.codeWorkspacePath = (clean == null || clean.isEmpty) ? null : expandHome(clean);
    _save();
    notifyListeners();
  }

  /// Desfaz o workspace: as pastas que só estavam nele voltam pra raiz, no
  /// lugar da seção, e nenhuma sessão fecha.
  void dissolveWorkspace(Workspace w) {
    _pinRootOrder();
    final at = rootOrder.indexOf(rowKey(w));
    rootOrder.remove(rowKey(w));
    workspaces.remove(w);
    final freed = [
      for (final f in foldersOf(w))
        if (standsAlone(f)) rowKey(f),
    ];
    rootOrder.insertAll(at < 0 ? rootOrder.length : at, freed);
    _save();
    notifyListeners();
  }

  /// As pastas que saem da lateral ao fechar [w]: as que só estão nele. A
  /// espelhada em outro workspace continua lá, com as sessões dela.
  List<Folder> closingWith(Workspace w) =>
      foldersOf(w).where((f) => workspacesOf(f).length == 1).toList();

  /// Fecha um workspace: as pastas só dele saem da lateral com as sessões, e a
  /// seção sai junto. Nada toca o disco -- nem os repos, nem o
  /// `.code-workspace`.
  Future<void> closeWorkspace(Workspace w) async {
    final name = w.name;
    final going = closingWith(w);
    for (final f in going) {
      await removeFolder(f);
    }
    _pinRootOrder();
    rootOrder.remove(rowKey(w));
    workspaces.remove(w);
    _save();
    notifyListeners();
    showBanner(
      going.length == 1
          ? 'workspace "$name" fechado — 1 pasta saiu da lateral'
          : 'workspace "$name" fechado — ${going.length} pastas saíram da lateral',
    );
  }

  void toggleWorkspaceCollapsed(Workspace w) {
    w.collapsed = !w.collapsed;
    _save();
    notifyListeners();
  }

  /// Se a pasta está dobrada onde está sendo desenhada: dentro de [within], ou
  /// solta na raiz.
  bool isFolderCollapsed(Folder f, {Workspace? within}) =>
      within == null ? f.collapsed : within.collapsedFolders.contains(f.root);

  void toggleFolderCollapsed(Folder f, {Workspace? within}) {
    if (within == null) return toggleCollapsed(f);
    within.collapsedFolders.contains(f.root)
        ? within.collapsedFolders.remove(f.root)
        : within.collapsedFolders.add(f.root);
    _save();
    notifyListeners();
  }

  /// Se a busca achou alguma coisa nesta seção -- numa sessão de qualquer
  /// pasta dela.
  bool hasHitsInWorkspace(Workspace w) => foldersOf(w).any(hasHits);
```

(As regras de arrasto — `moveRootRow`, `moveInWorkspace`, `RowPlace`, `canDrop`, `drop` — entram na Task 4. Até lá, o `_RowDrag` da lateral fica sem compilar; o Step 6 trata disso.)

5e. `removeFolder`: troque `reconcileWorkspaces();` por:

```dart
    for (final w in workspaces) {
      w.folderRoots.remove(p.root);
      w.collapsedFolders.remove(p.root);
    }
```

5f. `importWorkspace`: apague `folder.workspace ??= ws.path;`, junte as pastas resolvidas numa lista e troque o bloco que cria a seção por:

```dart
    // As pastas que o arquivo lista e que existem, novas ou não. Com o
    // espelho, uma que já está em outro workspace passa a estar nos dois.
    final adopted = [...added, ...already];
    if (adopted.isNotEmpty) {
      var w = workspaces.firstWhereOrNull((w) => w.codeWorkspacePath == ws.path);
      if (w == null) {
        _pinRootOrder();
        w = Workspace(id: newWorkspaceId(), name: ws.name, codeWorkspacePath: ws.path);
        workspaces.add(w);
        rootOrder.add(rowKey(w));
      }
      for (final f in adopted) {
        if (!w.folderRoots.contains(f.root)) w.folderRoots.add(f.root);
      }
    }
```

5g. `chosenTintOf`:

```dart
  MxTint? chosenTintOf(MxTab tab) =>
      featureOrHotfixOf(tab)?.tint ??
      tab.tint ??
      tab.folder.tint ??
      // O fundo do fundo: a cor do primeiro workspace da pasta, na ordem da
      // lateral. Um painel existe uma vez só, então de dois workspaces
      // espelhando a pasta ele precisa escolher um -- e o de cima é o que se
      // vê primeiro.
      sidebarRows
          .whereType<Workspace>()
          .firstWhereOrNull((w) => w.folderRoots.contains(tab.folderRoot))
          ?.tint;
```

5h. Na seção `// --- workspaces ---` não sobra nenhuma referência a `Folder.workspace`, `workspaceOf` ou `reconcileWorkspaces`. Confira com: `grep -n "workspaceOf\|reconcileWorkspaces\|\.workspace\b" lib/services/store.dart` → nenhuma linha.

- [ ] **Step 6: Deixar a lateral compilando até a Task 4**

Em `lib/ui/sidebar.dart`:
- `ValueKey(w.path)` → `ValueKey(w.id)`.
- No `_RowDragState`, troque o corpo de `_orderOf` por `return widget.store.sidebarRows.indexOf(row);`, e as chamadas `widget.store.canMoveRow(d.data, widget.row)` / `widget.store.moveRow(d.data, widget.row)` por `false` / nada, com um comentário `// Task 4 devolve o arrasto.` — é só para o analyzer passar; a Task 4 reescreve o widget.

Em `lib/ui/dialogs.dart`, no `confirmCloseWorkspace`: `final folders = store.closingWith(workspace);`, e a linha que mostrava `workspace.path` passa a mostrar `workspace.codeWorkspacePath` só quando ele não é null (`if (workspace.codeWorkspacePath case final path?) …`).

Em `lib/services/plugin_api.dart` não há referência a `Folder.workspace`; se o analyzer apontar alguma, troque por `store.workspacesOf(f)`.

- [ ] **Step 7: Rodar os testes do arquivo**

Run: `fvm flutter test test/workspace_test.dart`
Expected: PASS.

- [ ] **Step 8: Analisar e rodar a suíte**

Run: `fvm flutter analyze && fvm flutter test`
Expected: `No issues found!`. Os testes de `test/reorder_test.dart` que usam `section(...)`, `f.workspace`, `moveRow` e `canMoveRow` falham ou não compilam: eles são reescritos na Task 4. Se não compilarem, comente o `group('reordenar pastas', …)` e o `group('arrastar uma pasta', …)` com um `// Task 4.` e siga; todo o resto passa.

- [ ] **Step 9: Commit**

```bash
git add -A lib test
git commit -m "faz o workspace dono das pastas dele, com o .code-workspace opcional e a migração do config"
```

---

### Task 4: As regras de soltura (ordem da raiz e de dentro de um workspace)

**Files:**
- Modify: `lib/services/store.dart`
- Test: `test/reorder_test.dart`

**Interfaces:**
- Consumes: `rootOrder`, `_pinRootOrder`, `rowKey`, `addToWorkspace`, `removeFromWorkspace`, `sidebarRows` (Task 3).
- Produces: `typedef RowPlace = ({SidebarRow row, Workspace? within});` (top-level em `store.dart`); no `AppStore`: `void moveRootRow(SidebarRow row, SidebarRow target)`, `void moveInWorkspace(Workspace w, Folder f, Folder target)`, `void moveFolder(Folder f, {Workspace? from, required Workspace to, Folder? before})`, `bool canDrop(RowPlace from, RowPlace onto, {bool into = false})`, `void drop(RowPlace from, RowPlace onto, {bool into = false})`.

- [ ] **Step 1: Reescrever os testes de reordenação de pastas**

Em `test/reorder_test.dart`, apague o helper `section(...)` e o `folderOrder(...)`, e troque por:

```dart
/// A raiz da lateral, por nome: `ws:<nome>` pros workspaces.
List<String> rowOrder(AppStore store) => [
  for (final r in store.sidebarRows) r is Workspace ? 'ws:${r.name}' : (r as Folder).name,
];

Folder named(AppStore store, String name) => store.folders.firstWhere((f) => f.name == name);

/// Um workspace com as pastas [names], criado como a lateral cria.
Workspace section(AppStore store, List<String> names, {String name = 'cefis'}) =>
    store.createWorkspace(name, folders: [for (final n in names) named(store, n)]);

RowPlace root(SidebarRow row) => (row: row, within: null);
RowPlace inside(Folder f, Workspace w) => (row: f, within: w);
```

Substitua o `group('reordenar pastas', …)` por:

```dart
  group('reordenar a raiz', () {
    test('uma pasta solta na vaga da linha em que foi solta', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.drop(root(named(store, 'quatro')), root(named(store, 'dois')));
      expect(rowOrder(store), ['um', 'quatro', 'dois', 'tres']);
    });

    test('e descendo, a mesma vaga', () {
      final store = storeWithFolders(['um', 'dois', 'tres', 'quatro']);
      store.drop(root(named(store, 'um')), root(named(store, 'tres')));
      expect(rowOrder(store), ['dois', 'tres', 'um', 'quatro']);
    });

    test('soltar uma pasta nela mesma não muda nada', () {
      final store = storeWithFolders(['um', 'dois']);
      expect(store.canDrop(root(named(store, 'dois')), root(named(store, 'dois'))), isFalse);
      store.drop(root(named(store, 'dois')), root(named(store, 'dois')));
      expect(rowOrder(store), ['um', 'dois']);
    });

    test('uma seção viaja inteira', () {
      final store = storeWithFolders(['um', 'api', 'web', 'dois']);
      final ws = section(store, ['api', 'web']);
      store.drop(root(ws), root(named(store, 'um')));
      expect(rowOrder(store), ['ws:cefis', 'um', 'dois']);
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'web']);
    });

    test('e uma pasta solta passa por cima da seção inteira', () {
      final store = storeWithFolders(['um', 'dois']);
      store.folders.addAll([Folder(root: '/repos/api', name: 'api')]);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'um')), root(ws));
      expect(rowOrder(store), ['dois', 'ws:cefis', 'um']);
    });

    test('uma seção não entra no meio de outra', () {
      final store = storeWithFolders(['api', 'web']);
      final a = section(store, ['api'], name: 'a');
      final b = section(store, ['web'], name: 'b');
      expect(store.canDrop(root(a), inside(named(store, 'web'), b)), isFalse);
      expect(store.canDrop(root(a), root(b), into: true), isFalse);
    });
  });

  group('dentro de um workspace', () {
    test('a pasta se arruma entre as irmãs', () {
      final store = storeWithFolders(['api', 'web', 'app']);
      final ws = section(store, ['api', 'web', 'app']);
      store.drop(inside(named(store, 'app'), ws), inside(named(store, 'api'), ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['app', 'api', 'web']);
    });

    test('solta numa linha da raiz, sai do workspace e fica naquela vaga', () {
      final store = storeWithFolders(['api', 'web', 'solta']);
      final ws = section(store, ['api', 'web']);
      store.drop(inside(named(store, 'api'), ws), root(named(store, 'solta')));
      expect(store.foldersOf(ws).map((f) => f.name), ['web']);
      // O workspace novo entrou no fim da raiz; a pasta que sai dele fica na
      // vaga da linha em que caiu, empurrando-a pra baixo.
      expect(rowOrder(store), ['api', 'solta', 'ws:cefis']);
    });

    test('uma pasta solta sobre uma pasta de dentro entra naquela vaga', () {
      final store = storeWithFolders(['api', 'web', 'solta']);
      final ws = section(store, ['api', 'web']);
      store.drop(root(named(store, 'solta')), inside(named(store, 'web'), ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta', 'web']);
      expect(rowOrder(store), ['ws:cefis']);
    });

    test('solta no meio do cabeçalho de outro workspace, muda de workspace', () {
      final store = storeWithFolders(['api', 'web']);
      final a = section(store, ['api'], name: 'a');
      final b = section(store, ['web'], name: 'b');
      store.drop(inside(named(store, 'api'), a), root(b), into: true);
      expect(store.foldersOf(a), isEmpty);
      expect(store.foldersOf(b).map((f) => f.name), ['web', 'api']);
    });

    test('uma pasta solta no meio do cabeçalho entra no workspace', () {
      final store = storeWithFolders(['api', 'solta']);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'solta')), root(ws), into: true);
      expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta']);
      expect(rowOrder(store), ['ws:cefis']);
    });

    test('no meio do cabeçalho do próprio workspace, nada acontece', () {
      final store = storeWithFolders(['api']);
      final ws = section(store, ['api']);
      expect(store.canDrop(inside(named(store, 'api'), ws), root(ws), into: true), isFalse);
    });

    // Review Focus 4: a borda do cabeçalho é reordenar, não entrar.
    test('na borda do cabeçalho, uma pasta solta só reordena', () {
      final store = storeWithFolders(['solta', 'api']);
      final ws = section(store, ['api']);
      store.drop(root(named(store, 'solta')), root(ws));
      expect(store.foldersOf(ws).map((f) => f.name), ['api']);
      expect(rowOrder(store), ['ws:cefis', 'solta']);
    });
  });
```

Substitua o `group('arrastar uma pasta', …)` pelo mesmo de antes trocando `folderOrder(store)` por `rowOrder(store)` e `store.folders[1].collapsed` por `named(store, 'beta').collapsed`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/reorder_test.dart`
Expected: FAIL na compilação — `RowPlace`, `drop` e `canDrop` não existem.

- [ ] **Step 3: Implementar em `lib/services/store.dart`**

Top-level, perto do `featureOrHotfixIdIn`:

```dart
/// Uma linha da lateral no lugar em que ela está desenhada.
///
/// A mesma pasta aparece uma vez em cada workspace dela, e um arrasto precisa
/// saber de qual das aparições ela saiu: é o [within] -- null na raiz.
typedef RowPlace = ({SidebarRow row, Workspace? within});
```

No `AppStore`, depois de `toggleFolderCollapsed`:

```dart
  /// Põe [row] na vaga de [target], na raiz.
  ///
  /// A vaga é a mesma de [moveTab]: o que veio de cima empurra o alvo pra cima
  /// e para embaixo dele; o que veio de baixo para em cima. Nos dois casos é a
  /// linha em que se soltou.
  void moveRootRow(SidebarRow row, SidebarRow target) {
    _pinRootOrder();
    if (!_slide(rootOrder, rootOrder.indexOf(rowKey(row)), rootOrder.indexOf(rowKey(target)))) {
      return;
    }
    _save();
    notifyListeners();
  }

  /// Reordena [f] entre as pastas de [w], na vaga de [target].
  void moveInWorkspace(Workspace w, Folder f, Folder target) {
    if (!_slide(w.folderRoots, w.folderRoots.indexOf(f.root), w.folderRoots.indexOf(target.root))) {
      return;
    }
    _save();
    notifyListeners();
  }

  /// Leva [f] pra [to], saindo de [from] quando ele é dado. Se a pasta já
  /// estava em [to] (espelhada), só sai de [from].
  void moveFolder(Folder f, {Workspace? from, required Workspace to, Folder? before}) {
    addToWorkspace(f, to, before: before);
    if (from != null && from != to) removeFromWorkspace(f, from);
  }

  /// Tira o item de [from] e o devolve na vaga de [to]. Falso quando não há o
  /// que mexer. Ver [moveTab], que é a mesma conta na lista de painéis.
  bool _slide<T>(List<T> list, int from, int to) {
    if (from < 0 || to < 0 || from == to) return false;
    list.insert(to, list.removeAt(from));
    return true;
  }

  /// Se soltar [from] sobre [onto] faz alguma coisa. [into] é soltar no meio
  /// do cabeçalho de um workspace -- entrar nele --, e não na borda de uma
  /// linha, que é reordenar.
  ///
  /// A regra é uma só: a linha em que se soltou diz em que faixa a linha
  /// arrastada vai morar. Solta numa linha da raiz, mora na raiz; solta numa
  /// pasta de dentro de um workspace, mora naquele workspace. Uma seção só
  /// mora na raiz.
  bool canDrop(RowPlace from, RowPlace onto, {bool into = false}) {
    if (into) {
      return from.row is Folder && onto.row is Workspace && from.within != onto.row;
    }
    if (identical(from.row, onto.row) && from.within == onto.within) return false;
    if (from.row is Workspace) return onto.within == null;
    return true;
  }

  /// Faz o que [canDrop] diz que dá pra fazer. Ver lá a regra.
  void drop(RowPlace from, RowPlace onto, {bool into = false}) {
    if (!canDrop(from, onto, into: into)) return;
    final row = from.row;
    if (into) {
      moveFolder(row as Folder, from: from.within, to: onto.row as Workspace);
      return;
    }
    if (row is Workspace) {
      moveRootRow(row, onto.row);
      return;
    }
    final f = row as Folder;
    final lane = onto.within;
    if (lane == null) {
      if (from.within == null) {
        moveRootRow(f, onto.row);
      } else {
        removeFromWorkspace(f, from.within!, at: onto.row);
      }
      return;
    }
    final target = onto.row as Folder;
    if (from.within == lane) {
      moveInWorkspace(lane, f, target);
    } else {
      moveFolder(f, from: from.within, to: lane, before: target);
    }
  }
```

Se o `_slide` antigo ainda existir em algum lugar do arquivo (ele foi apagado na Task 3, Step 5d), mantenha só este.

- [ ] **Step 4: Rodar os testes do arquivo**

Run: `fvm flutter test test/reorder_test.dart`
Expected: os grupos `'reordenar a raiz'` e `'dentro de um workspace'` PASSAM. O grupo `'arrastar uma pasta'` (widget) ainda falha: o `_RowDrag` é devolvido na Task 5.

- [ ] **Step 5: Commit**

```bash
git add lib/services/store.dart test/reorder_test.dart
git commit -m "põe as regras de soltar uma linha da lateral no store, com a ordem da raiz própria"
```

---

### Task 5: A lateral com espelho, dobra por aparição e arrasto com duas zonas

**Files:**
- Create: `lib/ui/sidebar_workspaces.dart`
- Modify: `lib/ui/sidebar.dart`
- Test: `test/sidebar_workspaces_test.dart` (novo), `test/reorder_test.dart` (o grupo de widget volta a passar)

**Interfaces:**
- Consumes: `RowPlace`, `canDrop`, `drop`, `isFolderCollapsed`, `toggleFolderCollapsed`, `foldersOf`, `sidebarRows` (Tasks 3–4).
- Produces: `class RowDragData { RowDragData(this.from); final RowPlace from; Offset grab = Offset.zero; double startY = 0; }` em `sidebar_workspaces.dart`; `_FolderGroup({required AppStore store, required Folder folder, Workspace? within})`; `_RowDrag({required AppStore store, required RowPlace place, bool acceptsInto = false, required Widget child})`; `showFolderMenu(…, {Workspace? within})` (o parâmetro entra aqui; os itens novos do menu são da Task 6).

- [ ] **Step 1: Escrever os testes que falham**

Crie `test/sidebar_workspaces_test.dart`:

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/sidebar.dart';

AppStore storeWith(List<String> names) {
  final store = AppStore();
  for (final n in names) {
    store.folders.add(Folder(root: '/repos/$n', name: n)..isRepo = true);
  }
  return store;
}

Folder named(AppStore s, String name) => s.folders.firstWhere((f) => f.name == name);

/// Como a janela monta a lateral: dentro de um [AnimatedBuilder] que escuta o
/// store, senão dobrar muda o estado e não redesenha nada.
Future<void> pumpSidebar(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 660,
        height: 900,
        child: AnimatedBuilder(animation: store, builder: (_, _) => Sidebar(store: store)),
      ),
    ),
  ),
);

/// O cabeçalho de um workspace na tela, pelo nome.
Rect header(WidgetTester tester, String name) => tester.getRect(
  find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first,
);

/// Pega [from] pelo meio e solta em [to], como um mouse faria.
Future<void> dragTo(WidgetTester tester, String from, Offset to) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(from).first),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('a pasta espelhada aparece completa nos dois workspaces', (tester) async {
    final store = storeWith(['atrium-api', 'infra']);
    addTearDown(store.dispose);
    store.createWorkspace('ATRIUM', folders: [named(store, 'atrium-api'), named(store, 'infra')]);
    store.createWorkspace('UPLII', folders: [named(store, 'infra')]);

    await pumpSidebar(tester, store);

    expect(find.text('ATRIUM'), findsOneWidget);
    expect(find.text('UPLII'), findsOneWidget);
    expect(find.text('infra'), findsNWidgets(2));
    expect(find.text('2 pastas'), findsOneWidget);
    expect(find.text('1 pasta'), findsOneWidget);
  });

  testWidgets('dobrar a pasta num workspace não dobra no outro', (tester) async {
    final store = storeWith(['infra']);
    addTearDown(store.dispose);
    final infra = named(store, 'infra');
    final atrium = store.createWorkspace('ATRIUM', folders: [infra]);
    store.createWorkspace('UPLII', folders: [infra]);
    store.tabs.add(
      MxTab(id: 't1', folder: infra, kind: TabKind.shell, cwd: infra.root, branch: '', customLabel: 'servidor'),
    );
    await pumpSidebar(tester, store);
    expect(find.text('servidor'), findsNWidgets(2));

    await tester.tap(find.text('infra').first);
    await tester.pump();

    expect(store.isFolderCollapsed(infra, within: atrium), isTrue);
    expect(find.text('servidor'), findsOneWidget);
  });

  testWidgets('o workspace vazio continua na lateral', (tester) async {
    final store = storeWith(['solta']);
    addTearDown(store.dispose);
    store.createWorkspace('ATRIUM');

    await pumpSidebar(tester, store);

    expect(find.text('ATRIUM'), findsOneWidget);
    expect(find.text('0 pastas'), findsOneWidget);
    expect(find.text('arraste uma pasta pra cá'), findsOneWidget);
  });

  testWidgets('a pasta sem cor pega a do workspace na linha dela', (tester) async {
    final store = storeWith(['infra']);
    addTearDown(store.dispose);
    store.setWorkspaceTint(store.createWorkspace('ATRIUM', folders: [named(store, 'infra')]), MxTint.red);

    await pumpSidebar(tester, store);

    final glyph = tester.widget<RepoGlyph>(find.byType(RepoGlyph));
    expect(glyph.color, MxTint.red.color);
  });

  testWidgets('solta no meio do cabeçalho, a pasta entra no workspace', (tester) async {
    final store = storeWith(['solta', 'api']);
    addTearDown(store.dispose);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await dragTo(tester, 'solta', header(tester, 'ATRIUM').center);

    expect(store.foldersOf(ws).map((f) => f.name), ['api', 'solta']);
  });

  // Review Focus 4.
  testWidgets('solta na borda do cabeçalho, a pasta só reordena', (tester) async {
    final store = storeWith(['solta', 'api']);
    addTearDown(store.dispose);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    final h = header(tester, 'ATRIUM');
    await dragTo(tester, 'solta', Offset(h.center.dx, h.bottom - 2));

    expect(store.foldersOf(ws).map((f) => f.name), ['api']);
    expect(store.sidebarRows.first, ws);
  });

  testWidgets('arrastada pra uma linha da raiz, a pasta sai do workspace', (tester) async {
    final store = storeWith(['api', 'solta']);
    addTearDown(store.dispose);
    final ws = store.createWorkspace('ATRIUM', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await dragTo(tester, 'api', tester.getCenter(find.text('solta')));

    expect(store.foldersOf(ws), isEmpty);
    expect(store.standsAlone(named(store, 'api')), isTrue);
  });
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/sidebar_workspaces_test.dart`
Expected: FAIL — o `_WorkspaceSection` atual não desenha "0 pastas" com a dica, a pasta não pega a cor do workspace, e o arrasto não faz nada (desligado na Task 3).

- [ ] **Step 3: Criar `lib/ui/sidebar_workspaces.dart` e ligá-lo à lateral**

No topo de `lib/ui/sidebar.dart`, depois dos imports: `part 'sidebar_workspaces.dart';`. Mova a classe `_WorkspaceSection`, a `_RowDrag` (com o `_RowDragState`) e a função `showWorkspaceMenu` de `sidebar.dart` para o arquivo novo, que começa com `part of 'sidebar.dart';`, e reescreva-as assim:

```dart
part of 'sidebar.dart';

/// As pastas de um workspace, juntas e sob uma linha que dobra.
///
/// A linha junta, dobra, pinta e recebe pastas arrastadas. O que se abre, se
/// renomeia e se remove continua sendo da pasta, cada uma com o menu que ela
/// sempre teve. Ver [Workspace].
class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({super.key, required this.store, required this.workspace});

  final AppStore store;
  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    // Com uma busca em curso, só as pastas que ela achou -- e a seção dobrada
    // abre, como a pasta e a feature fazem.
    final folders = store
        .foldersOf(workspace)
        .where((f) => !store.filtering || store.hasHits(f))
        .toList();
    final collapsed = workspace.collapsed && !store.filtering;
    final count = store.foldersOf(workspace).length;
    final alerts = folders.fold<int>(0, (a, f) => a + store.needingHuman(f));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A seção inteira se arrasta por este cabeçalho, e é nele que uma
        // pasta solta entra no workspace -- no meio dele. Ver [_RowDrag].
        _RowDrag(
          store: store,
          place: (row: workspace, within: null),
          acceptsInto: true,
          child: InkWell(
            onTap: () => store.toggleWorkspaceCollapsed(workspace),
            onSecondaryTapDown: (d) =>
                showWorkspaceMenu(context, store, workspace, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 8, 8),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                    color: Mx.fgDim,
                  ),
                  const SizedBox(width: 3),
                  // Nem o glifo de repo nem o da feature: um workspace não é um
                  // checkout e não é um trabalho com nome.
                  Icon(Icons.hexagon_outlined, size: 15, color: workspace.tint?.color ?? Mx.accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      workspace.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                  ),
                  // Fechada, a seção é a única linha que sobra de tudo que está
                  // lá dentro: o aviso de uma sessão parada tem que atravessar.
                  if (collapsed && alerts > 0) _Badge(count: alerts),
                  Text(
                    count == 1 ? '1 pasta' : '$count pastas',
                    style: TextStyle(color: Mx.fgFaint, fontSize: 11.5),
                  ),
                  _RowButton(
                    tooltip: 'o que fazer com esse workspace',
                    icon: Icons.more_horiz,
                    onTap: (anchor) => showWorkspaceMenu(context, store, workspace, anchor),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          _Nest(
            color: workspace.tint?.color,
            children: [
              for (final f in folders)
                _FolderGroup(
                  key: ValueKey('${workspace.id}/${f.root}'),
                  store: store,
                  folder: f,
                  within: workspace,
                ),
              // Vazio é um estado de verdade agora -- o workspace criado antes
              // dos repos, ou o que perdeu o último --, e a linha diz como sair
              // dele em vez de deixar um cabeçalho sobre nada.
              if (count == 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                  child: Text(
                    'arraste uma pasta pra cá',
                    style: TextStyle(color: Mx.fgFaint, fontSize: 11.5),
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
      ],
    );
  }
}

/// O que voa num arrasto de linha: de onde ela saiu, onde o ponteiro a pegou
/// e a altura em que o arrasto começou.
///
/// O ponto da pegada é o que deixa o cabeçalho de um workspace saber onde
/// está o ponteiro: o Flutter entrega ao alvo o canto do cartão no ar, e o
/// ponteiro é esse canto mais a pegada. A altura do começo diz de que lado a
/// linha veio, pra listra ficar do lado em que ela vai parar.
class RowDragData {
  RowDragData(this.from);
  final RowPlace from;
  Offset grab = Offset.zero;
  double startY = 0;
}

/// Arrasta uma linha da lateral -- pasta ou seção -- pra outro lugar.
///
/// É [_PanelDrag] um degrau acima: pega-se pelo cabeçalho, solta-se sobre
/// outra linha, e a linha em que se soltou é a vaga. O cabeçalho de um
/// workspace ([acceptsInto]) tem duas zonas: o meio é "entrar", e as bordas
/// são "ficar aqui do lado". Quem decide se pode é [AppStore.canDrop].
class _RowDrag extends StatefulWidget {
  const _RowDrag({
    required this.store,
    required this.place,
    this.acceptsInto = false,
    required this.child,
  });

  final AppStore store;
  final RowPlace place;
  final bool acceptsInto;
  final Widget child;

  @override
  State<_RowDrag> createState() => _RowDragState();
}

class _RowDragState extends State<_RowDrag> {
  /// O arrasto pairando sobre esta linha, quando é um que ela aceitaria.
  RowDragData? _incoming;

  /// Se o que paira vai entrar no workspace (meio do cabeçalho) em vez de
  /// ficar do lado.
  bool _into = false;

  bool _same(RowDragData d) =>
      identical(d.from.row, widget.place.row) && d.from.within == widget.place.within;

  /// O meio do cabeçalho: a metade de dentro da altura dele.
  bool _overMiddle(Offset pointer) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final y = box.globalToLocal(pointer).dy;
    return y > box.size.height * 0.25 && y < box.size.height * 0.75;
  }

  /// A listra embaixo quando a linha veio de cima e vai ficar na mesma faixa
  /// -- é onde [AppStore.moveRootRow] a põe. Vinda de outra faixa ela entra na
  /// vaga do alvo, e a listra fica em cima.
  bool get _stripeBelow {
    final d = _incoming!;
    if (d.from.within != widget.place.within) return false;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    return d.startY < box.localToGlobal(box.size.center(Offset.zero)).dy;
  }

  void _hover(RowDragData d, Offset feedbackTopLeft) {
    if (_same(d)) return;
    final into = widget.acceptsInto && _overMiddle(feedbackTopLeft + d.grab);
    final ok = widget.store.canDrop(d.from, widget.place, into: into);
    setState(() {
      _incoming = ok ? d : null;
      _into = ok && into;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = RowDragData(widget.place);
    return LayoutBuilder(
      builder: (context, box) => DragTarget<RowDragData>(
        onWillAcceptWithDetails: (d) =>
            _same(d.data) ||
            widget.store.canDrop(d.data.from, widget.place) ||
            (widget.acceptsInto && widget.store.canDrop(d.data.from, widget.place, into: true)),
        onMove: (d) => _hover(d.data, d.offset),
        onLeave: (_) {
          if (_incoming != null || _into) {
            setState(() {
              _incoming = null;
              _into = false;
            });
          }
        },
        onAcceptWithDetails: (d) {
          final into = _into;
          final accepted = _incoming;
          setState(() {
            _incoming = null;
            _into = false;
          });
          // Solta de volta em cima de si: um clique cujo ponteiro escorregou.
          if (_same(d.data)) return _toggle();
          if (accepted == null) return;
          widget.store.drop(d.data.from, widget.place, into: into);
        },
        builder: (context, _, _) => Stack(
          children: [
            Draggable<RowDragData>(
              data: data,
              dragAnchorStrategy: (draggable, context, position) {
                final anchor = childDragAnchorStrategy(draggable, context, position);
                data
                  ..grab = anchor
                  ..startY = position.dy;
                return anchor;
              },
              feedback: _lifted(widget.child, box.maxWidth),
              childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
              child: widget.child,
            ),
            if (_into)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Mx.accent.withValues(alpha: 0.12),
                      border: Border.all(color: Mx.accent, width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              )
            else if (_incoming != null)
              Positioned(
                left: 7,
                right: 7,
                top: _stripeBelow ? null : 0,
                bottom: _stripeBelow ? 0 : null,
                child: Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: Mx.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// O clique que o arrasto engoliu: dobrar a linha, que é o que o cabeçalho
  /// faz quando se clica nele.
  void _toggle() {
    final place = widget.place;
    if (place.row case final Folder f) widget.store.toggleFolderCollapsed(f, within: place.within);
    if (place.row case final Workspace w) widget.store.toggleWorkspaceCollapsed(w);
  }
}
```

(O `showWorkspaceMenu` é movido sem mudança nesta tarefa; os itens novos são da Task 6.)

- [ ] **Step 4: O `_FolderGroup` sabe onde está desenhado**

Em `lib/ui/sidebar.dart`:
- No `Sidebar.build`, o `_WorkspaceSection` passa a usar `key: ValueKey(w.id)`.
- `_FolderGroup` ganha `this.within` no construtor e `final Workspace? within;`, com o comentário `/// O workspace em que esta aparição está desenhada; null na raiz. A mesma pasta aparece uma vez em cada workspace dela.`
- Dentro do `build`: `final collapsed = store.isFolderCollapsed(folder, within: within) && !store.filtering;` e `final tint = folder.tint?.color ?? within?.tint?.color;`.
- O `_RowDrag` da pasta: `place: (row: folder, within: within)`.
- `onTap: () => store.toggleFolderCollapsed(folder, within: within)`.
- `RepoGlyph(isRepo: folder.isRepo, color: tint)` e `_Nest(color: tint, …)`.
- `showFolderMenu(context, store, folder, worktrees, d.globalPosition, within: within)` e o mesmo no `_FolderMenu` (que ganha `this.within`).
- `showFolderMenu` ganha o parâmetro nomeado `{Workspace? within}` (os itens que o usam vêm na Task 6).

- [ ] **Step 5: Rodar os testes da lateral**

Run: `fvm flutter test test/sidebar_workspaces_test.dart test/reorder_test.dart test/workspace_test.dart`
Expected: PASS. Se o teste da borda entrar no workspace em vez de reordenar, confira que o `_overMiddle` recebe `feedbackTopLeft + d.grab` (o ponteiro), e não só o `d.offset`.

- [ ] **Step 6: Analisar e rodar a suíte**

Run: `fvm flutter analyze && fvm flutter test`
Expected: `No issues found!` e PASS.

- [ ] **Step 7: Commit**

```bash
git add -A lib test
git commit -m "desenha a pasta espelhada em cada workspace e aceita soltar no meio do cabeçalho pra entrar"
```

---

### Task 6: Criar e manter workspaces pelos menus

**Files:**
- Modify: `lib/ui/sidebar.dart` (rodapé, menu da pasta), `lib/ui/sidebar_workspaces.dart` (menu do workspace), `lib/ui/dialogs.dart` (`showNewWorkspace`)
- Test: `test/sidebar_workspaces_test.dart`, e os testes que tocam no botão de adicionar pasta do rodapé (`test/workspace_test.dart`)

**Interfaces:**
- Consumes: `createWorkspace`, `addToWorkspace`, `removeFromWorkspace`, `renameWorkspace`, `setWorkspaceTint`, `linkCodeWorkspace`, `dissolveWorkspace`, `workspacesOf`, `openInEditor`, `importWorkspace` (Tasks 3–4); `tintItem`, `isTintChoice`, `tintPicked`, `promptText`, `mxMenu`, `mxItem`, `mxDivider`, `MxSubmenuItem`, `MxSubItem`, `Notifier.chooseWorkspace()` (já existem).
- Produces: `Future<Workspace?> showNewWorkspace(BuildContext context, AppStore store, {Folder? preselect})` em `dialogs.dart`.

- [ ] **Step 1: Escrever os testes que falham**

Acrescente a `test/sidebar_workspaces_test.dart`:

```dart
  testWidgets('o + do rodapé oferece pasta, import e workspace', (tester) async {
    final store = storeWith([]);
    addTearDown(store.dispose);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('adicionar uma pasta ao cockpit'));
    await tester.pumpAndSettle();

    expect(find.text('adicionar pasta…'), findsOneWidget);
    expect(find.text('importar .code-workspace…'), findsOneWidget);
    expect(find.text('novo workspace…'), findsOneWidget);
  });

  testWidgets('o diálogo cria o workspace com o nome e as pastas marcadas', (tester) async {
    final store = storeWith(['atrium-api', 'atrium-web', 'infra']);
    addTearDown(store.dispose);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('adicionar uma pasta ao cockpit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('novo workspace…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ATRIUM');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'atrium-api'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'atrium-web'));
    await tester.tap(find.text('criar'));
    await tester.pumpAndSettle();

    final ws = store.workspaces.single;
    expect(ws.name, 'ATRIUM');
    expect(store.foldersOf(ws).map((f) => f.name), ['atrium-api', 'atrium-web']);
  });

  testWidgets('o menu da pasta põe e tira de um workspace', (tester) async {
    final store = storeWith(['infra']);
    addTearDown(store.dispose);
    final ws = store.createWorkspace('ATRIUM');
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('o que fazer com essa pasta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('adicionar a workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ATRIUM').last);
    await tester.pumpAndSettle();
    expect(store.foldersOf(ws).single.name, 'infra');

    // Agora desenhada dentro do ATRIUM, o menu dela oferece sair.
    await tester.tap(find.byTooltip('o que fazer com essa pasta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tirar deste workspace'));
    await tester.pumpAndSettle();
    expect(store.foldersOf(ws), isEmpty);
  });

  testWidgets('o menu do workspace renomeia e desfaz', (tester) async {
    final store = storeWith(['api']);
    addTearDown(store.dispose);
    store.createWorkspace('atrium', folders: [named(store, 'api')]);
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('o que fazer com esse workspace'));
    await tester.pumpAndSettle();
    expect(find.text('associar .code-workspace…'), findsOneWidget);
    expect(find.text('abrir no vscode'), findsNothing);
    await tester.tap(find.text('renomear…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ATRIUM');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.workspaces.single.name, 'ATRIUM');

    await tester.tap(find.byTooltip('o que fazer com esse workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('desfazer workspace'));
    await tester.pumpAndSettle();
    expect(store.workspaces, isEmpty);
    expect(store.folders.single.name, 'api');
  });

  testWidgets('com arquivo associado, o menu oferece abrir no vscode e desassociar', (tester) async {
    final store = storeWith(['api']);
    addTearDown(store.dispose);
    store.createWorkspace('ATRIUM', codeWorkspacePath: '/repos/atrium.code-workspace');
    await pumpSidebar(tester, store);

    await tester.tap(find.byTooltip('o que fazer com esse workspace'));
    await tester.pumpAndSettle();

    expect(find.text('abrir no vscode'), findsOneWidget);
    expect(find.text('desassociar .code-workspace'), findsOneWidget);
  });
```

Antes de escrever o Step 4, confira como o `promptText` confirma (enter no campo ou um botão). Se for por botão, troque o `receiveAction(TextInputAction.done)` pelo `tap` no botão dele.

Em `test/workspace_test.dart`, nos testes que tocam em `find.byTooltip('adicionar uma pasta ao cockpit')` para abrir o diálogo de pasta, acrescente logo depois do `pumpAndSettle`:

```dart
      await tester.tap(find.text('adicionar pasta…'));
      await tester.pumpAndSettle();
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/sidebar_workspaces_test.dart`
Expected: FAIL — os itens novos não existem.

- [ ] **Step 3: O diálogo de criar, em `lib/ui/dialogs.dart`**

Perto do `confirmCloseWorkspace`:

```dart
/// Um workspace novo: o nome e as pastas da lateral que entram nele.
///
/// As pastas são as que já estão na lateral: é o caso de quem montou o
/// cockpit repo por repo e agora quer juntar os do mesmo produto. Pasta nova
/// entra pelo "adicionar pasta…" de sempre, e depois pelo menu dela.
Future<Workspace?> showNewWorkspace(
  BuildContext context,
  AppStore store, {
  Folder? preselect,
}) async {
  final name = TextEditingController();
  final picked = <String>{if (preselect != null) preselect.root};

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: const Text('novo workspace', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: _field('nome', 'ATRIUM'),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 12),
              if (store.folders.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final f in store.folders)
                        CheckboxListTile(
                          dense: true,
                          value: picked.contains(f.root),
                          title: Text(f.name, style: const TextStyle(fontSize: 13)),
                          onChanged: (on) => setState(
                            () => on == true ? picked.add(f.root) : picked.remove(f.root),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('criar')),
        ],
      ),
    ),
  );

  if (go != true) return null;
  final label = name.text.trim();
  if (label.isEmpty) return null;
  return store.createWorkspace(
    label,
    folders: [
      for (final f in store.folders)
        if (picked.contains(f.root)) f,
    ],
  );
}
```

- [ ] **Step 4: O + do rodapé vira menu, em `lib/ui/sidebar.dart`**

No `_Footer`, o primeiro `_StripIcon` passa a abrir um menu ancorado nele (mesmo tooltip, para não mexer no que se procura por ele):

```dart
          Builder(
            builder: (context) => _StripIcon(
              icon: Icons.create_new_folder_outlined,
              tooltip: 'adicionar uma pasta ao cockpit',
              onPressed: () {
                final box = context.findRenderObject() as RenderBox;
                _showFooterAdd(context, store, box.localToGlobal(Offset.zero));
              },
            ),
          ),
```

E a função, perto do `_showAddMenu`:

```dart
/// O que o + do rodapé põe na lateral: uma pasta, as pastas de um
/// `.code-workspace` ou um workspace novo.
Future<void> _showFooterAdd(BuildContext context, AppStore store, Offset anchor) async {
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      mxItem(
        'folder',
        glyph: Icon(Icons.create_new_folder_outlined, size: 14, color: Mx.fgDim),
        label: 'adicionar pasta…',
      ),
      mxItem(
        'import',
        glyph: Icon(Icons.file_open_outlined, size: 14, color: Mx.fgDim),
        label: 'importar .code-workspace…',
      ),
      mxDivider(),
      mxItem(
        'workspace',
        glyph: Icon(Icons.hexagon_outlined, size: 14, color: Mx.accent),
        label: 'novo workspace…',
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'folder':
      await showAddFolder(context, store);
    case 'import':
      final picked = await Notifier.chooseWorkspace();
      if (picked.path case final path?) await store.importWorkspace(path);
      if (!picked.available) store.showBanner('não consegui abrir o seletor de arquivos', sticky: true);
    case 'workspace':
      await showNewWorkspace(context, store);
  }
}
```

(Se `Notifier` não estiver importado em `sidebar.dart`, acrescente `import '../services/notify.dart';`.)

- [ ] **Step 5: O menu da pasta**

Em `showFolderMenu`, no bloco "dar nome às coisas", depois de `tintItem(folder.tint)`:

```dart
      // Em que workspaces a pasta está: marcar e desmarcar é como ela fica em
      // vários -- o repo de infra de dois produtos.
      MxSubmenuItem(
        label: 'adicionar a workspace',
        glyph: Icon(Icons.hexagon_outlined, size: 14, color: Mx.fgDim),
        items: () => [
          for (final w in store.workspaces)
            MxSubItem(
              value: 'ws:${w.id}',
              label: w.name,
              glyph: Icon(
                w.folderRoots.contains(folder.root) ? Icons.check_box : Icons.check_box_outline_blank,
                size: 13,
                color: Mx.fgDim,
              ),
            ),
          MxSubItem(
            value: 'ws:new',
            label: 'novo workspace…',
            glyph: Icon(Icons.add, size: 13, color: Mx.fgDim),
            divided: store.workspaces.isNotEmpty,
          ),
        ],
      ),
      if (within != null)
        mxItem(
          'leave',
          glyph: Icon(Icons.logout, size: 14, color: Mx.fgDim),
          label: 'tirar deste workspace',
        ),
```

E os casos no `switch`:

```dart
    case 'ws:new':
      await showNewWorkspace(context, store, preselect: folder);
    case final pick when pick.startsWith('ws:'):
      if (store.workspaceById(pick.substring(3)) case final w?) {
        w.folderRoots.contains(folder.root)
            ? store.removeFromWorkspace(folder, w)
            : store.addToWorkspace(folder, w);
      }
    case 'leave':
      store.removeFromWorkspace(folder, within!);
```

(O `case 'ws:new'` vem antes do `case final pick when pick.startsWith('ws:')`.)

- [ ] **Step 6: O menu do workspace, em `lib/ui/sidebar_workspaces.dart`**

Substitua o `showWorkspaceMenu`:

```dart
/// O que dá pra fazer com um workspace. As pastas continuam com o menu delas;
/// este é o do conjunto.
Future<void> showWorkspaceMenu(
  BuildContext context,
  AppStore store,
  Workspace workspace,
  Offset anchor,
) async {
  final file = workspace.codeWorkspacePath;
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'renomear…',
      ),
      tintItem(workspace.tint),
      mxDivider(),
      if (file == null)
        mxItem(
          'link',
          glyph: Icon(Icons.link, size: 14, color: Mx.fgDim),
          label: 'associar .code-workspace…',
        )
      else ...[
        mxItem(
          'vscode',
          glyph: Icon(Icons.open_in_new, size: 14, color: Mx.fgDim),
          label: 'abrir no vscode',
        ),
        mxItem(
          'unlink',
          glyph: Icon(Icons.link_off, size: 14, color: Mx.fgDim),
          label: 'desassociar .code-workspace',
        ),
      ],
      mxDivider(),
      // Desfazer não fecha nada: as pastas voltam pra raiz. Fechar leva as
      // pastas só deste workspace e as sessões delas, e por isso pergunta.
      mxItem(
        'dissolve',
        glyph: Icon(Icons.hexagon_outlined, size: 14, color: Mx.fgDim),
        label: 'desfazer workspace',
      ),
      mxItem(
        'close',
        glyph: Icon(Icons.folder_off_outlined, size: 14, color: Mx.red),
        label: 'fechar workspace…',
        color: Mx.red,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'rename':
      final name = await promptText(
        context,
        title: 'renomear workspace',
        initial: workspace.name,
        label: 'nome',
      );
      if (name != null) store.renameWorkspace(workspace, name);
    case final pick when isTintChoice(pick):
      store.setWorkspaceTint(workspace, tintPicked(pick));
    case 'link':
      final picked = await Notifier.chooseWorkspace();
      if (picked.path case final path?) store.linkCodeWorkspace(workspace, path);
      if (!picked.available) store.showBanner('não consegui abrir o seletor de arquivos', sticky: true);
    case 'vscode':
      await store.openInEditor(file!);
    case 'unlink':
      store.linkCodeWorkspace(workspace, null);
    case 'dissolve':
      final name = workspace.name;
      store.dissolveWorkspace(workspace);
      store.showBanner('workspace "$name" desfeito — as pastas continuam na lateral');
    case 'close':
      await confirmCloseWorkspace(context, store, workspace);
  }
}
```

- [ ] **Step 7: Rodar os testes**

Run: `fvm flutter test test/sidebar_workspaces_test.dart test/workspace_test.dart`
Expected: PASS.

- [ ] **Step 8: Analisar e rodar a suíte**

Run: `fvm flutter analyze && fvm flutter test`
Expected: `No issues found!` e PASS.

- [ ] **Step 9: Commit**

```bash
git add -A lib test
git commit -m "cria, renomeia, pinta e desfaz workspaces pelos menus da lateral"
```

---

### Task 7: A API de plugins e a documentação

**Files:**
- Modify: `lib/services/plugin_api.dart`, `docs/plugins.md`
- Test: `test/plugins_test.dart`

**Interfaces:**
- Consumes: `featuresOrHotfixes`, `featureOrHotfixOf`, `workspaces`, `workspacesOf`, `foldersOf` (Tasks 1–3).
- Produces: métodos RPC `featuresOrHotfixes.list`, `workspaces.list`; campos novos em `projects.list`, `folders.list` e na sessão.

- [ ] **Step 1: Escrever o teste que falha**

Acrescente ao `main()` de `test/plugins_test.dart`:

```dart
  group('workspaces e feature/hotfix na API', () {
    MxPlugin plugin() => MxPlugin(
      dir: '/p',
      manifest: const PluginManifest(id: 'p', name: 'P', version: '1'),
    );

    test('os métodos novos respondem, e os antigos continuam', () async {
      final store = AppStore();
      addTearDown(store.dispose);
      final infra = Folder(root: '/repos/infra', name: 'infra');
      store.folders.add(infra);
      final ws = store.createWorkspace('ATRIUM', folders: [infra]);
      final fix = store.addFeatureOrHotfix(infra, 'login quebrado', kind: FeatureOrHotfixKind.hotfix);
      final tab = MxTab(id: 't1', folder: infra, kind: TabKind.shell, cwd: infra.root, branch: '');
      tab.featureOrHotfixId = fix.id;
      store.tabs.add(tab);
      final api = PluginApi(store);

      expect(await api.handle(plugin(), 'workspaces.list', {}), [
        {'id': ws.id, 'name': 'ATRIUM', 'folders': ['/repos/infra']},
      ]);
      final both = await api.handle(plugin(), 'featuresOrHotfixes.list', {}) as List;
      expect((both.single as Map)['kind'], 'hotfix');
      // O de antes, com o `kind` a mais.
      final old = await api.handle(plugin(), 'projects.list', {}) as List;
      expect((old.single as Map)['name'], 'login quebrado');
      expect((old.single as Map)['kind'], 'hotfix');

      final folders = await api.handle(plugin(), 'folders.list', {}) as List;
      expect((folders.single as Map)['workspaces'], ['ATRIUM']);

      final session = PluginApi.sessionJson(store, tab);
      expect(session['project'], 'login quebrado');
      expect(session['featureOrHotfix'], 'login quebrado');
      expect(session['featureOrHotfixKind'], 'hotfix');
      expect(session['workspaces'], ['ATRIUM']);
    });
  });
```

Antes de rodar, confira a assinatura de `sessionJson` em `lib/services/plugin_api.dart` (o teste supõe `static Map<String, Object?> sessionJson(AppStore store, MxTab t, {MxPlugin? plugin})`). Se for um método de instância, troque a chamada por `api.sessionJson(tab)`; se for outra coisa, peça a sessão por `await api.handle(plugin(), 'sessions.list', {})` e pegue o primeiro item.

- [ ] **Step 2: Rodar e ver falhar**

Run: `fvm flutter test test/plugins_test.dart --plain-name 'workspaces e feature/hotfix na API'`
Expected: FAIL — `workspaces.list` responde erro de método desconhecido.

- [ ] **Step 3: Implementar em `lib/services/plugin_api.dart`**

No `folders.list`, em cada pasta: `'workspaces': [for (final w in store.workspacesOf(f)) w.name],`.

Troque o `case 'projects.list':` por:

```dart
      // `projects.list` é o nome de antes do rename, e plugins já instalados
      // chamam por ele. Os dois respondem a mesma lista.
      case 'featuresOrHotfixes.list':
      case 'projects.list':
        return [
          for (final pr in store.featuresOrHotfixes)
            {
              'id': pr.id,
              'name': pr.name,
              'kind': pr.kind.name,
              'folder': pr.folderRoot,
              'brief': pr.brief,
            },
        ];
      case 'workspaces.list':
        return [
          for (final w in store.workspaces)
            {
              'id': w.id,
              'name': w.name,
              'folders': [for (final f in store.foldersOf(w)) f.root],
              if (w.codeWorkspacePath != null) 'codeWorkspacePath': w.codeWorkspacePath,
            },
        ];
```

Na sessão, logo depois de `'project': …`:

```dart
    // `project` é o nome de antes do rename; fica pelos plugins que já o leem.
    'featureOrHotfix': store.featureOrHotfixOf(t)?.name,
    'featureOrHotfixKind': store.featureOrHotfixOf(t)?.kind.name,
    'workspaces': [for (final w in store.workspacesOf(t.folder)) w.name],
```

- [ ] **Step 4: Documentar em `docs/plugins.md`**

Na tabela de métodos:
- `folders.list`: acrescente `, workspaces: [nome]` ao fim da descrição dos campos.
- Troque a linha de `projects.list` por estas três:

```markdown
| `featuresOrHotfixes.list` | — | `[{ id, name, kind, folder, brief }]` — `kind` é `feature` ou `hotfix` |
| `projects.list` | — | o mesmo de `featuresOrHotfixes.list`. Obsoleto: é o nome de quando feature/hotfix se chamava projeto |
| `workspaces.list` | — | `[{ id, name, folders: [root], codeWorkspacePath? }]` — os workspaces da lateral, com as pastas na ordem em que aparecem |
```

No json de exemplo da sessão, depois de `"project": "permissão do google",` acrescente `"featureOrHotfix": "permissão do google", "featureOrHotfixKind": "feature", "workspaces": ["ATRIUM"],`, e logo abaixo do bloco explique em uma linha: `` `project` é o nome antigo de `featureOrHotfix` e continua vindo, por compatibilidade. ``

- [ ] **Step 5: Rodar os testes e a suíte**

Run: `fvm flutter analyze && fvm flutter test`
Expected: `No issues found!` e PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/services/plugin_api.dart docs/plugins.md test/plugins_test.dart
git commit -m "expõe workspaces e feature/hotfix na API de plugins sem quebrar os nomes antigos"
```

---

### Task 8: Verificação final com o config real

**Files:**
- Nenhum arquivo do repositório muda nesta tarefa, a não ser que a verificação encontre um defeito (aí ele é corrigido com teste, na tarefa a que pertence).

- [ ] **Step 1: Análise e suíte inteira**

Run: `make analyze && make test`
Expected: `No issues found!` e `All tests passed!`.

- [ ] **Step 2: Cópia do config real**

```bash
cp ~/.maestria/config.json ~/.maestria/config.json.bak-2.4.0
ls -la ~/.maestria/config.json.bak-2.4.0
```

Expected: o arquivo existe, com o mesmo tamanho do `config.json`.

- [ ] **Step 3: Abrir o app em dev com o config real**

Run: `fvm flutter run -d macos`
Conferir na janela, nesta ordem, e anotar o que não bater:
1. Todas as pastas que estavam na lateral continuam lá, na mesma ordem.
2. Todas as features que existiam continuam nas mesmas pastas, com "feature" implícito (sem etiqueta).
3. Pelo + do rodapé, "novo workspace…" cria ATRIUM com os repos `atrium-*`; repetir para UPLII, WIBOOR e LMS.
4. Arrastar um repo solto para o meio do cabeçalho de um workspace o põe dentro; para a borda, só reordena.
5. Pôr um mesmo repo em dois workspaces pelo menu da pasta; dobrar numa aparição não dobra na outra.
6. Criar um hotfix numa pasta: aparece com o raio e a etiqueta "hotfix".
7. Fechar e reabrir o app (⌘Q e `fvm flutter run -d macos` de novo): os workspaces, a ordem e as dobras voltam como estavam.

- [ ] **Step 4: Conferir o config gravado**

```bash
python3 -c "import json;j=json.load(open('$HOME/.maestria/config.json'));print(sorted(j.keys()));print([w['name'] for w in j.get('workspaces',[])]);print('projects' in j, any('workspace' in f for f in j['folders']))"
```

Expected: as chaves incluem `featuresOrHotfixes`, `rootOrder` e `workspaces`; os nomes dos quatro workspaces aparecem; a última linha imprime `False False` (nenhuma chave antiga gravada).

- [ ] **Step 5: Relatar**

Relate ao Renato o resultado de cada item do Step 3, com o que não bateu (se algo não bateu, é um defeito: volte à tarefa dona, escreva o teste que o reproduz e corrija antes de seguir).
