# Workspaces manuais e feature/hotfix

## Objetivo

Hoje a lateral tem dois agrupamentos: o **workspace**, que junta pastas, mas só
nasce importando um `.code-workspace` do VS Code; e o **projeto**, um trabalho
com nome dentro de um repo. O Renato trabalha com vários repos por produto
(ATRIUM, UPLII, WIBOOR, LMS) e quer agrupá-los na mão, sem depender de um
arquivo do VS Code.

O resultado esperado:

- O workspace passa a ser o agrupamento de primeiro nível. Pode ser criado,
  renomeado, pintado e desfeito pela própria lateral, e o `.code-workspace`
  vira opcional.
- Um mesmo repo pode estar em mais de um workspace, como espelho: as sessões
  e as features dele aparecem em todos.
- O antigo "projeto" passa a se chamar **feature** ou **hotfix**, escolhido ao
  criar.

Critério de sucesso: com o config real do Renato, montar ATRIUM, UPLII, WIBOOR
e LMS pela lateral, com as sessões e as features que já existiam preservadas
depois da migração.

## Decisões tomadas

| Pergunta | Decisão |
|---|---|
| Agrupamento de cima | Generalizar o `Workspace` existente, não criar um conceito novo |
| `.code-workspace` | Opcional: é um campo do workspace, não a identidade dele |
| Feature e hotfix | Um tipo só, com `kind` escolhido ao criar; o comportamento é o mesmo |
| Nomes no código | `Workspace` continua; `Project` vira `FeatureOrHotfix` (`featureOrHotfixId`, `featuresOrHotfixes`…) |
| Nome na interface | "workspace" para o grupo de cima; "feature" ou "hotfix" para o de dentro |
| Repo em mais de um workspace | Sim, como espelho |
| Interações | Diálogo de criação, menus da pasta e do workspace, e arrasto |
| Config do app em dev | O mesmo `~/.maestria/`. O app instalado foi removido, então não há duas versões gravando o mesmo arquivo |

## 1. Modelo e config

### `Workspace` (`lib/models.dart`)

| Campo | Tipo | Observação |
|---|---|---|
| `id` | `String` | Estável. Passa a ser a identidade, no lugar do caminho do arquivo |
| `name` | `String` | Editável |
| `collapsed` | `bool` | Como hoje |
| `tint` | `MxTint?` | Novo. As pastas sem cor própria herdam |
| `codeWorkspacePath` | `String?` | Opcional. O `.code-workspace` associado |
| `folderRoots` | `List<String>` | A ordem das pastas dentro deste workspace |
| `collapsedFolders` | `Set<String>` | As pastas dobradas *nesta* aparição |

### `Folder`

- Perde o campo `workspace`. A pertença mora só no `Workspace.folderRoots`, para
  não existirem duas listas que possam discordar.
- `AppStore.workspacesOf(Folder)` responde em que workspaces a pasta está.
- `Folder.collapsed` continua valendo para a pasta desenhada solta na raiz.

### `Project` → `FeatureOrHotfix`

- Os mesmos campos de hoje (`id`, `folderRoot`, `name`, `brief`, `collapsed`,
  `tint`), mais `kind: FeatureOrHotfixKind { feature, hotfix }`.
- `MxTab.projectId` → `MxTab.featureOrHotfixId`.
- No `AppStore`: `projects` → `featuresOrHotfixes`, `projectsOf` →
  `featuresOrHotfixesOf`, `projectById` → `featureOrHotfixById`, `projectOf` →
  `featureOrHotfixOf`, `focusedProject` → `focusedFeatureOrHotfix`,
  `addProject` → `addFeatureOrHotfix` (com `kind`), `editProject` →
  `editFeatureOrHotfix`, `setProjectTint` → `setFeatureOrHotfixTint`,
  `toggleProjectCollapsed` → `toggleFeatureOrHotfixCollapsed`,
  `completeProject` → `completeFeatureOrHotfix`, `removeProject` →
  `removeFeatureOrHotfix`, `toggleFilterProject` →
  `toggleFilterFeatureOrHotfix`. `assign`, `tabsIn` e `needingHumanIn` mantêm
  o nome e passam a receber `FeatureOrHotfix`.
- Novo `setFeatureOrHotfixKind` para o "virar hotfix" / "virar feature".

### Ordem da lateral

- O `AppStore` passa a guardar `rootOrder: List<String>`, com entradas
  `workspace:<id>` ou `folder:<root>`. É a ordem que a raiz desenha.
- Uma pasta é desenhada solta na raiz quando não está em nenhum workspace.
- `sidebarRows` passa a ler o `rootOrder`. Uma entrada que não aponta para nada
  é descartada, e uma linha que falta no `rootOrder` vai para o fim. Isso é
  conferido ao carregar o config e a cada mudança, como o
  `reconcileWorkspaces` faz hoje.

### Config

Grava só as chaves novas: `workspaces` (no formato acima), `featuresOrHotfixes`
e `rootOrder`, e, nos painéis salvos, `featureOrHotfixId`.

A leitura aceita as chaves antigas, uma vez, no primeiro boot da versão nova:

| Antiga | Vira |
|---|---|
| `projects` (com `folders` presente) | `featuresOrHotfixes`, com `kind: feature` |
| `projects` (sem `folders`) | pastas, como hoje (formato de antes dos projetos) |
| `projectId` num painel salvo | `featureOrHotfixId` |
| `Folder.workspace` (um caminho) | o workspace com aquele `codeWorkspacePath` ganha a pasta em `folderRoots`; se não houver workspace com esse caminho, nasce um, com o nome do arquivo |
| `Workspace` sem `id` | ganha um `id` novo e guarda o `path` antigo em `codeWorkspacePath` |
| sem `rootOrder` | derivado da ordem de `folders`, como a lateral faz hoje |

Antes de abrir a versão nova pela primeira vez com o config real, uma cópia
vai para `~/.maestria/config.json.bak-2.4.0`.

## 2. Lateral e interações

### Desenho

- A raiz segue o `rootOrder`. O workspace é uma seção que dobra, com nome, cor,
  a conta de pastas ("4 pastas"), o aviso de sessões esperando por você quando
  dobrada (como hoje) e `⋯`.
- Um workspace sem pastas continua na lateral, com "0 pastas", até alguém
  desfazê-lo ou fechá-lo. Hoje a seção some com a última pasta; com workspace
  criado na mão, sumir sozinho seria perder o ATRIUM ao tirar o último repo.
- Dentro da seção, as pastas seguem o `folderRoots`. Cada pasta mostra o mesmo
  de hoje: features e hotfixes, sessões, worktrees.
- Uma pasta em dois workspaces aparece completa nos dois, e cada aparição dobra
  por conta própria (`Workspace.collapsedFolders`).
- A bandeja dos avulsos e a dos grupos de painéis não mudam.

### Criar

- O botão de adicionar do rodapé passa a abrir um menu com "adicionar pasta…",
  "importar .code-workspace…" e "novo workspace…".
- "Novo workspace…" abre um diálogo com o nome e a lista de repos da lateral,
  com checkboxes.

### Arrastar

- O arrasto de linha passa a levar a pasta e a origem dela: de qual workspace
  saiu, ou se saiu da raiz.
- No cabeçalho de um workspace, a pasta solta **no meio** entra no workspace
  (o cabeçalho inteiro acende). Solta **nas bordas** de cima ou de baixo, só
  reordena, com a listra de hoje.
- Uma pasta arrastada de um workspace para o cabeçalho de outro *muda* de
  workspace: sai do de origem e entra no de destino. Para estar nos dois, o
  caminho é o menu.
- Dentro de um workspace, arrastar entre as pastas dele reordena o
  `folderRoots`.
- Uma pasta de um workspace solta numa linha da raiz sai do workspace de origem
  e fica solta na vaga em que caiu (se ela ainda estiver em outro workspace,
  só sai do de origem).
- Uma pasta solta sobre uma pasta *dentro* de um workspace entra nesse
  workspace, na vaga em que caiu. Vale a mesma regra da raiz: a linha em que se
  soltou diz em que faixa a pasta vai morar.
- Um workspace arrastado na raiz reordena o `rootOrder`, como hoje.

### Menus

- **Pasta:** "adicionar a workspace ▸" (marca e desmarca cada workspace; no fim,
  "novo workspace…"). Quando desenhada dentro de um workspace, também "tirar
  deste workspace".
- **Workspace:** "renomear…", "cor ▸", "associar .code-workspace…" ou
  "desassociar .code-workspace", "abrir no vscode" (só com arquivo associado),
  "desfazer workspace" (as pastas voltam para a raiz e nada fecha) e "fechar
  workspace…" (como hoje: tira as pastas da lateral e fecha as sessões delas;
  uma pasta que também está em outro workspace só sai deste, e as sessões dela
  continuam abertas).
- Importar um `.code-workspace` põe as pastas dele no workspace associado a
  esse arquivo (criando um, se não houver), mesmo que alguma já esteja em outro
  workspace: com o espelho, a pasta passa a estar nos dois. Hoje o import não
  "rouba" a pasta do primeiro workspace.
- "Remover" uma pasta pelo menu dela tira o repo de todos os workspaces e fecha
  as sessões dele, como hoje.

### Cor

- Na lateral, a pasta sem cor própria herda a cor do workspace em que está
  desenhada.
- Nos painéis, a precedência passa a ser: feature/hotfix → painel → pasta →
  primeiro workspace da pasta na ordem da lateral → grupo de painéis.

### Contadores

- O contador do cabeçalho de um workspace conta as sessões das pastas dele. Uma
  sessão de um repo espelhado conta em cada workspace em que ele está.
- O sino e o badge da dock contam cada sessão uma vez.

### Busca e filtro

- Uma pasta com resultado aparece em todos os workspaces dela. Um workspace sem
  nenhum resultado some enquanto a busca durar, como hoje.

### Código

- A seção de workspace e o arrasto de linhas saem de `lib/ui/sidebar.dart`
  (2.900 linhas) para `lib/ui/sidebar_workspaces.dart`. O resto do arquivo
  fica como está.

## 3. Feature e hotfix

- Os textos que hoje dizem "projeto" no sentido de trabalho dentro do repo
  passam a usar a palavra do tipo de cada um: "concluir feature", "renomear
  hotfix". Quando valem para os dois, "feature/hotfix": "mover pra
  feature/hotfix…", "essa pasta ainda não tem feature nem hotfix".
- Ficam como estão os textos em que "projeto" é o repo para o Claude Code (os
  de `lib/services/setup.dart`, o de `lib/ui/settings.dart` sobre `npm run
  dev`).
- O "novo projeto…" vira "nova feature…" e "novo hotfix…" nos menus da pasta e
  da bandeja dos avulsos. O diálogo é o de hoje (nome e brief), com o título
  "nova feature em <pasta>" ou "novo hotfix em <pasta>".
- O menu da linha ganha "virar hotfix" ou "virar feature".
- Feature mantém o glifo de hoje (`Icons.track_changes`). Hotfix usa
  `Icons.bolt`, que o Material já tem (o projeto só recorre a svg em
  `assets/icons/` quando o Material não tem o desenho), e uma etiqueta discreta
  "hotfix" ao lado do nome. Não há cor automática.
- Não muda: brief como `--append-system-prompt`, cor herdada pelos painéis,
  concluir com confete, dissolver e mover.

## 4. API de plugins

Contrato público, documentado em `docs/plugins.md`. Nada do que existe deixa de
funcionar.

- Sessão: `project` continua com o nome da feature/hotfix (obsoleto na
  documentação) e ganha `featureOrHotfix`, `featureOrHotfixKind` e
  `workspaces` (os nomes dos workspaces da pasta).
- `projects.list` continua respondendo como hoje, com `kind` a mais. Ganha o
  equivalente `featuresOrHotfixes.list`.
- Novo `workspaces.list`: `[{ id, name, folders, codeWorkspacePath? }]`.
- `folders.list` ganha `workspaces` em cada pasta.

## 5. Testes

Escritos antes do código (TDD), nos padrões de `test/`.

- **Modelo e config:** round-trip de `Workspace` com e sem `.code-workspace`, e
  de `FeatureOrHotfix` com `kind`. Migração a partir de um config no formato
  2.4.0, gravado como fixture em `test/fixtures/`.
- **Store:** criar e desfazer workspace; adicionar e tirar pasta; a mesma pasta
  em dois workspaces; trocar de workspace; `rootOrder` e a reconciliação dele;
  remover pasta tira de todos; precedência de cor; contadores.
- **Widget:** a pasta espelhada desenhada nos dois lugares e dobrando em cada
  um; arrasto no meio e na borda do cabeçalho; menus novos; glifo e etiqueta de
  hotfix.
- **Testes atuais** que usam `Project` e `projectId` (`projects_test`,
  `workspace_test`, `reorder_test`, `search_test` e outros) passam para os
  nomes novos, sem perder caso nenhum.
- No fim, `make analyze` e `make test` passando, e o app rodando em dev com o
  config real, com os quatro workspaces montados.

## 6. Entrega

Um PR, com dois commits em sequência:

1. O rename de `Project` para `FeatureOrHotfix`, com `kind` e os textos novos,
   sem mudar comportamento.
2. Os workspaces manuais com espelho.

## Riscos

- **Migração do config real:** coberta pelo teste com fixture e pela cópia
  `config.json.bak-2.4.0` antes do primeiro boot.
- **Arrasto com duas intenções no mesmo cabeçalho:** é o ponto com mais chance
  de ficar desconfortável na mão. As zonas (meio e bordas) são ajustadas depois
  do primeiro teste do Renato.
- **Tamanho do rename:** ~190 ocorrências em 15 arquivos. Fica isolado no
  primeiro commit para a revisão não se misturar com a lógica nova.
