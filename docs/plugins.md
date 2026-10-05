# Plugins da Maestria

> Primeira vez? Comece pelo passo a passo em [`criando-um-plugin.md`](criando-um-plugin.md).
> Este arquivo é a referência: todos os campos, métodos e blocos.

Um plugin é uma pasta com um `maestria-plugin.json`. Ele pode trazer:

- **temas**, em json;
- **comandos** que rodam um shell ou mandam um texto pra sessão, sem nenhum código;
- **um processo** próprio, em qualquer linguagem, que conversa com a janela por
  JSON-RPC 2.0 no stdin/stdout. É com ele que o plugin recebe os eventos das
  sessões, atende comandos e desenha janelas.

Por que processo e não código carregado no app: a Maestria é Flutter compilado
AOT, e um binário assim não carrega Dart em tempo de execução. É o mesmo arranjo
do extension host do VS Code, do LSP e do MCP por stdio.

Os plugins de verdade (o relatório do dia e a central de debug do Flutter)
moram fora deste repositório, em `maestria-plugins`. Há dois exemplos pequenos
em `examples/plugins/`:

| pasta | o que mostra |
|---|---|
| `tema-e-atalhos` | só declarações: um tema, dois comandos de shell (um com tecla), um texto pra sessão |
| `exemplo-completo` | processo node: comandos, hooks, notificação, janela com lista, campos e botões |

## Instalar

Configurações → **plugins**:

- **instalar…**: aceita uma URL de git (`git clone --depth 1`), um `.zip` ou uma
  pasta. Antes de instalar, a tela mostra o que o plugin roda e as permissões
  que ele pede. Instalar de novo um id que já existe atualiza o plugin.
- **carregar pasta de desenvolvimento…** (o link discreto no fim da seção):
  cria um link simbólico em vez de copiar. Depois de editar, aperte **reiniciar** na linha do plugin: a pasta é
  relida e o processo sobe de novo.

Os plugins ficam em `~/.maestria/plugins/<id>/`, e o que cada um guarda fica em
`~/.maestria/plugin-data/<id>/`. Quem você desliga é lembrado no config da
janela, então atualizar um plugin não o liga de volta.

## O manifesto

```json
{
  "id": "voce.meu-plugin",
  "name": "Meu plugin",
  "version": "1.0.0",
  "description": "Uma frase.",
  "author": "você",
  "maestria": 1,
  "main": ["node", "main.js"],
  "activationEvents": ["onCommand:painel", "onHook:Stop"],
  "permissions": ["hooks", "terminal.write"],
  "contributes": {
    "themes": [{ "path": "themes/meu.json" }],
    "commands": [
      { "id": "painel", "title": "abrir o painel", "key": "meta+alt+e" },
      { "id": "status", "title": "git status", "run": "git status -sb", "in": "background" },
      { "id": "log", "title": "git log", "run": "git log --oneline -20; exec $SHELL -l" },
      { "id": "revisar", "title": "pedir revisão", "send": "revise o diff em ${cwd}" }
    ]
  }
}
```

| campo | |
|---|---|
| `id` | obrigatório. Minúsculas, dígitos, `.`, `-` e `_`. Vira o nome da pasta. |
| `version` | obrigatório. |
| `maestria` | a versão da API que o plugin espera (hoje `1`). Um número maior que o da janela é recusado. |
| `main` | o processo: `["executável", "arg", …]`, rodado na pasta do plugin. Um nome solto é procurado no PATH (o mesmo com fallbacks que o app usa pra achar o `claude`, incluindo `/opt/homebrew/bin`). Um caminho relativo é resolvido a partir da pasta do plugin. |
| `icon` | o desenho do plugin, no cabeçalho e na linha da lateral das janelas dele e no cartão dele em Configurações → plugins (verde enquanto roda, cinza parado): um nome da tabela de ícones ou um `.svg` da pasta do plugin (`"icons/logo.svg"`), pintado de uma cor só como os outros glifos. |
| `activationEvents` | quando o processo sobe (veja abaixo). |
| `permissions` | veja abaixo. Permissão desconhecida faz o manifesto ser recusado. |

### Comandos

Cada comando vira uma linha no submenu **plugins** do menu de um painel (botão
direito na linha da lateral ou no cabeçalho), e ganha uma tecla quando tem `key`.
Com `"sidebar": true` ele ganha também um botão no rodapé da lateral, ao lado do
histórico, com o desenho de `icon` (um nome da tabela de ícones, mais abaixo, ou
um `.svg` da pasta do plugin).
Cabem três desses no total, na ordem dos plugins. Enquanto o plugin diz que o
comando está rodando (`command.busy`), o botão vira um spinner.

| forma | o que acontece |
|---|---|
| sem `run` nem `send` | o processo recebe um `command.invoke` (exige `main`) |
| `run` (com `"in": "terminal"`, o padrão) | abre um terminal novo rodando o comando, na pasta do painel |
| `run` com `"in": "background"` | roda num shell sem painel; a última linha da saída vira recado |
| `send` | cola o texto na sessão do claude em foco e aperta enter |

Em `run` e `send` valem as trocas `${cwd}`, `${folder}`, `${sessionId}`,
`${title}` e `${pluginDir}`. Em `run`, cada valor entra entre aspas simples.

`key` usa o formato dos atalhos do app: modificadores `ctrl`, `alt`, `shift`,
`meta` (⌘) e a tecla, separados por `+`: `meta+alt+g`, `meta+shift+f5`. Uma
tecla que o app já usa **não** é tomada: o comando fica sem tecla, e o "configurar" do
plugin (no ⋮ do cartão, que fica amarelo) diz qual é. As teclas reservadas pelo sistema (⌘Q, ⌘W…) e as que são ⌃ mais
uma letra são recusadas, e o motivo aparece no log do plugin.

No Linux, `meta` vira Ctrl+Shift — é onde os atalhos de terminal moram lá, e o
Super é do desktop. `meta+alt+g` responde a Ctrl+Shift+Alt+G.

### Configurações

O plugin declara o que dá pra configurar, e a Maestria desenha o formulário
(Configurações → plugins → ícone de ajuste, ou o mesmo ícone no cabeçalho de uma
janela do plugin), guarda o valor no config dela e avisa o plugin. É o
`contributes.configuration` do VS Code.

```json
"contributes": {
  "settings": [
    { "id": "colors.error", "group": "cores do console", "type": "color", "default": "red",
      "title": "erro", "description": "stderr e exceções" },
    { "id": "max", "type": "number", "default": 5000, "title": "linhas guardadas" },
    { "id": "modo", "type": "select", "options": ["rápido", { "value": "full", "label": "completo" }] },
    { "id": "ligado", "type": "boolean", "default": true }
  ]
}
```

| `type` | campo | valor |
|---|---|---|
| `string` | texto | texto |
| `number` | texto que só aceita número | número |
| `boolean` | interruptor | `true`/`false` |
| `select` | lista de `options` | o `value` escolhido |
| `color` | amostra, cores prontas e hex | `#RRGGBB`, um nome do tema (`red`, `green`, `yellow`, `accent`, `purple`, `dim`, `faint`) ou vazio pra cor do texto |

`group` põe um título em cima das configurações seguidas com o mesmo grupo. Só o
que você mexeu vai pro config: um padrão que muda numa versão nova do plugin
chega em quem nunca mexeu. Os valores chegam no `initialize` (`settings`), em
`settings.get`, e a cada mudança numa notificação `settings.changed`.

### Temas

Um json com as cores da janela e do terminal, `#RRGGBB` ou `#AARRGGBB`:

```json
{
  "id": "meu-tema", "label": "Meu tema", "dark": true,
  "canvas": "#0B1016", "bg": "#121A22", "bgSidebar": "#16202A",
  "bgHover": "#1F2B37", "bgActive": "#283746", "border": "#223040",
  "fg": "#D8E3EC", "fgDim": "#9DB0C0", "fgFaint": "#5F7385",
  "accent": "#5EE3C1", "green": "#8BD88B", "yellow": "#F2CD73",
  "red": "#F07A83", "purple": "#B69CF5",
  "ansi": {
    "black": "#283746", "red": "#F07A83", "green": "#8BD88B", "yellow": "#F2CD73",
    "blue": "#72B6F2", "magenta": "#B69CF5", "cyan": "#5EE3C1", "white": "#D8E3EC",
    "brightBlack": "#5F7385"
  }
}
```

Todas as cores são obrigatórias, menos os oito `bright*`, que caem na cor
normal. O `id` não pode repetir o de um tema embutido. O tema aparece em
Aparência, no bloco "de plugins".

### Permissões

O processo de um plugin roda com as suas permissões de usuário: ele pode fazer
no disco tudo o que você pode. As permissões não mudam isso. Elas controlam o
que a **janela** aceita fazer a pedido dele:

| permissão | libera |
|---|---|
| `hooks` | receber os eventos de hook das sessões do claude (têm o prompt e os argumentos das ferramentas) |
| `terminal.write` | `terminal.sendText` |
| `sessions.create` | `session.openClaude`, `session.openShell` |
| `notifications` | `window.notify` |

Um pedido sem a permissão declarada volta com erro `-32001`.

### Quando o processo sobe

| evento | |
|---|---|
| `onStartup` ou `*` | com o app |
| `onCommand:<id>` | na primeira vez que o comando roda |
| `onHook:<Nome>` / `onHook:*` | no primeiro hook com esse nome (`Stop`, `PreToolUse`, …). Exige `hooks`. |
| `onSession` | quando um painel abre, fecha ou muda de status |

Um plugin com `main` e sem `activationEvents` sobe com o app. Um processo que
cai fica como "parou" e **não** é ressuscitado por eventos, pra não entrar num
ciclo de subir e cair a cada hook. Rodar um comando dele ou apertar
**reiniciar** sobe de novo.

## O protocolo

JSON-RPC 2.0, **uma mensagem json por linha**, UTF-8. A janela escreve no stdin
do plugin, e o plugin escreve no stdout. Não use o stdout pra mais nada:
`console.log` quebra o protocolo. O stderr vai pro log do plugin (Configurações →
plugins → log), e o método `log` também. Uma linha do stdout que não é json vai
pro log em vez de derrubar a conversa.

O arquivo `examples/plugins/exemplo-completo/maestria.js` é um cliente completo
em ~100 linhas, sem dependências, pronto pra copiar.

### Da janela pro plugin

| mensagem | tipo | params |
|---|---|---|
| `initialize` | pedido (10s pra responder) | `apiVersion`, `blocks`, `pluginId`, `pluginDir`, `dataDir`, `permissions`, `settings` |
| `command.invoke` | pedido (30s) | `command`, `context: { cwd, folder, sessionId, title, pluginDir, tabId? }` |
| `event` | notificação | `type` e o resto, abaixo |
| `view.action` | notificação | `viewId`, `action`, `values` (os campos da janela) |
| `settings.changed` | notificação | `settings`: todas as configurações, como valem agora |
| `shutdown` | notificação | depois dela o stdin fecha; o processo tem 0,8s pra sair antes do SIGTERM |

`blocks` diz até onde vão os blocos que esta janela desenha: `2` é a que tem a lista do
OrbStack (`avatar`, `expanded`, `header`, `card`, `tabs`, `columns`), o terminal embutido e o
console em pedaços. Sem o campo é uma Maestria de antes (`1`) — um plugin que usa os novos
pode avisar que o app precisa ser atualizado, em vez de desenhar "bloco desconhecido".

Os `event`:

| `type` | campos |
|---|---|
| `hook` | `tabId`, `name`, `payload` (o json cru que o Claude Code mandou). Exige `hooks`. |
| `session.opened` | `tabId`, `kind`, `cwd`, `folder` |
| `session.closed` | `tabId` |
| `session.exited` | `tabId`, `code` — o processo do painel saiu e o painel ficou (o ssh que caiu) |
| `session.status` | `tabId`, `status`, `previous` |
| `sidebar.shown` | — a aba do plugin na lateral entrou na tela (ou foi clicada de novo). Só pra quem declara `contributes.sidebar`; sobe o processo se ele não estiver de pé. |
| `sidebar.hidden` | — a aba saiu da tela: outra aba, ou a lateral escondida |

Os eventos só chegam depois de o `initialize` voltar.

### Do plugin pra janela

| método | params | devolve |
|---|---|---|
| `log` | `message` | — (vale também como notificação) |
| `window.showBanner` | `text`, `sticky?` | — |
| `window.notify` | `title?`, `body` | — · `notifications` |
| `window.openUrl` | `url` (só http/https) | — |
| `window.pick` | `title?`, `placeholder?`, `items: [{ value, label?, detail? }]` | o `value` escolhido, ou `null` — o quick pick do VS Code: campo que filtra, setas e enter |
| `settings.get` | — | as configurações do plugin, como valem agora |
| `clipboard.write` | `text` | — |
| `sessions.list` | — | lista de sessões (abaixo) |
| `sessions.focused` | — | a sessão em foco, ou `null` |
| `session.focus` | `tabId?` | — põe o painel na tela |
| `folders.list` | — | as pastas da lateral: `name`, `root`, `isRepo`, `branch`, `worktrees: [{ path, branch, isMain, label, prunable }]`, `workspaces: [nome]` |
| `featuresOrHotfixes.list` | — | `[{ id, name, kind, folder, brief }]` — `kind` é `feature` ou `hotfix` |
| `projects.list` | — | o mesmo de `featuresOrHotfixes.list`. Obsoleto: é o nome de quando feature/hotfix se chamava projeto |
| `workspaces.list` | — | `[{ id, name, folders: [root], codeWorkspacePath? }]` — os workspaces da lateral, com as pastas na ordem em que aparecem |
| `chats.list` | `day` (`AAAA-MM-DD`) | as conversas arquivadas do Claude Code naquele dia: `[{ sessionId, title, cwd, folder, at, size }]` · `hooks` |
| `editor.open` | `path`, `line?` | — abre no VS Code (`code -g` com linha) |
| `command.busy` | `command`, `busy` | — o botão do comando na lateral vira spinner enquanto `busy` |
| `terminal.sendText` | `text`, `submit?`, `tabId?` | — · `terminal.write`. Sem `tabId`, usa o painel em foco ou, se ele não tiver processo (a própria janela do plugin, por exemplo), a primeira sessão na tela. |
| `session.openClaude` | `cwd?`, `prompt?`, `label?` | `{ tabId }` · `sessions.create` |
| `session.openShell` | `cwd?`, `command?`, `label?`, `owned?`, `tag?`, `embedded?` | `{ tabId }` · `sessions.create`. Com `owned: true` o terminal é do plugin: sai dos avulsos e mora na aba dele (a aba genérica o lista; quem desenha a própria aba o desenha), e não volta quando o app reabre. `tag` é um texto seu que volta no `sessions.list` desse terminal — o id do host, por exemplo. Com `embedded: true` (que já é `owned`) o terminal não vira painel: ele mora dentro de uma janela do plugin, desenhado por um bloco `terminal` com esse `tabId` — a aba Terminal de um container. Fechar a janela o encerra junto. |
| `session.close` | `tabId` | — fecha um terminal que o plugin abriu com `owned` (só esses) |
| `pane.openMarkdown` | `markdown`, `title?` | `{ tabId }`, no painel de leitura |
| `view.open` | `viewId`, `title?`, `blocks` (ou `rfw` e `data`) | `{ tabId }` — com `rfw` a janela é a interface que o plugin monta (veja "A interface em widgets") |
| `view.update` | `viewId`, `title?`, `blocks?`, `rfw?`, `data?` | `{ open }`: `false` quando você fechou a janela. `data` junta: cada chave de cima troca a que havia. Mandar `blocks` volta pros blocos. |
| `view.appendLines` | `viewId`, `id`, `lines` | `{ open }`: junta linhas a um bloco `console` sem redesenhar a janela |
| `view.clearLines` | `viewId`, `id` | — |
| `view.close` | `viewId` | — |
| `sidebar.update` | `blocks?`, `rfw?`, `data?`, `badge?` | `{ shown }`: se a aba está na tela. Exige `contributes.sidebar`. `badge` é o selo do ícone na faixa (texto curto; `null` ou `""` tira). |
| `float.show` | `id`, `width?`, `height?`, `corner?`, `rfw?`, `data?`, `blocks?` | `{ shown }` — o painel pequeno por cima da janela (veja "O flutuante") |
| `float.update` | `id`, `width?`, `height?`, `rfw?`, `data?`, `blocks?` | `{ shown }`: `false` quando ele não está na tela |
| `float.hide` | `id` | — |

Uma sessão é:

```json
{
  "id": "tab3", "kind": "claude", "title": "TASK#47730", "cwd": "/repo/wt", "folder": "/repo",
  "branch": "feature/TASK#47730", "status": "waitingPermission", "statusLabel": "Permissão",
  "needsYou": true, "sessionId": "…", "done": false, "hibernated": false, "exited": false,
  "onScreen": true, "focused": false, "startedAt": "2026-09-23T09:12:00.000",
  "project": "permissão do google", "featureOrHotfix": "permissão do google", "featureOrHotfixKind": "feature", "workspaces": ["ATRIUM"],
  "launcher": null,
  "activity": { "prompts": 4, "tools": 31, "touched": ["lib/x.dart"], "lastPrompt": "…", "lastMessage": "…" }
}
```

`project` é o nome antigo de `featureOrHotfix` e continua vindo, por compatibilidade.

`embedded` diz se é um terminal embutido (ver `session.openShell`).

`activity` só vem pra quem declarou `hooks`: é o mesmo conteúdo dos eventos.
`owner` é o id do plugin dono do terminal (ou `null`), e `tag` só vem pro
próprio dono.

`kind` é `claude`, `shell`, `reader`, `setup` ou `plugin`. O conteúdo do
terminal não é exposto. Pra saber o que uma sessão está fazendo, use os hooks.

Erros: `-32601` método desconhecido, `-32602` parâmetro inválido, `-32001` sem
permissão, `-32002` indisponível.

## A interface em widgets

Os blocos são peças prontas: a Maestria sabe desenhar uma lista, um botão, um
console, e o plugin escolhe entre elas. Quando o plugin quer uma cara que as
peças não têm, ele monta a interface ele mesmo, com os widgets do Flutter, e a
Maestria só desenha — com o Flutter de verdade, o mesmo tema e os mesmos atalhos.
É o formato do [Remote Flutter Widgets](https://pub.dev/packages/rfw) (`rfw`), do
time do Flutter. Um visual novo num plugin não pede nada do app.

```js
mx.request('sidebar.update', {
  rfw: { library: fs.readFileSync('ui/sidebar.rfwtxt', 'utf8'), root: 'root' },
  data: { rows: [{ title: 'api', action: 'abrir:1' }] },
});
```

```
import core.widgets;
import maestria;

widget root = Column(children: [
  ...for row in data.rows:
    Pressable(
      radius: 8.0,
      hoverColor: data.theme.hover,
      onTap: event "act" { a: row.action },
      child: Text(text: row.title, style: { color: data.theme.fg, fontSize: 13.0 }),
    ),
]);
```

- **O texto (`rfw.library`)** é lido só quando muda: mande uma vez e depois só os
  dados. `rfw.root` é o widget de cima (`root`, se não vier). Um erro no texto
  aparece na própria janela, em vermelho, com a linha.
- **Os dados (`data`)** trocam sem reler nada: cada chave de cima substitui a que
  havia. Números que são tamanhos (`13.0`, `[8.0, 0.0]`) ficam no texto: pelo json
  um `13.0` chega como inteiro, e o rfw lê tamanho como double. Nos dados vão
  textos, listas, booleanos e cores.
- **O tema:** a janela põe `data.theme` com as cores em vigor, como inteiros
  `0xAARRGGBB` (`canvas`, `bg`, `sidebar`, `hover`, `active`, `border`, `fg`, `dim`,
  `faint`, `accent`, `onAccent`, `green`, `yellow`, `red`, `purple`, `blue`, `cyan`,
  `magenta`, e `dark` e `mono`), e troca quando você troca de tema.
- **Os eventos:** `event "x" { … }` volta como `view.action` com `action: "x"` e os
  argumentos em `values`.
- **As bibliotecas:** `core.widgets` (`Row`, `Column`, `Container`, `Padding`,
  `Text`, `Stack`, `Positioned`, `ListView`, `Expanded`, `SizedBox`, `Opacity`,
  `Rotation`, `ClipRRect`, `GestureDetector`, …), `core.material` e `maestria`, com o
  que as primitivas não fazem:

| widget | argumentos |
|---|---|
| `Svg` | `svg` (o desenho inteiro, com as cores dele), `width`, `height` |
| `Glyph` | `icon` (um nome da tabela de ícones ou um `.svg` da pasta do plugin), `size`, `color` |
| `IconButton` | `icon`, `tooltip`, `onPressed`, `color`, `size`, `extent`, `disabled` |
| `Tooltip` | `message`, `child` |
| `Pressable` | `child`, `onTap`, `onDoubleTap`, `color`, `hoverColor`, `radius`, `padding`, `menu`, `onMenu` — uma área que acende com o mouse em cima, clica e abre o menu de botão direito. `menu: [{ label, icon?, action, red?, disabled?, children? } \| { divider: true }]`; a escolha vai no `onMenu` com `action` a mais nos argumentos. Um item com `children: [{ label, action, color? }]` abre um submenu ao lado, cada linha com a bolinha na `color` dela (`0xAARRGGBB`; `0` é só o contorno) — a paleta de cores do docker. |
| `MenuButton` | `icon`, `tooltip`, `color`, `menu`, `onMenu` — o botão de ícone que abre o menu embaixo dele (o "…" de um topo) |
| `Draggable` | `payload`, `targets`, `width`, `child`, `feedback?`, `disabled?` — o que dá pra arrastar: o cartão de um quadro. `payload` é o texto que viaja (o id do cartão); `targets`, os `id` dos `DropTarget` que o aceitam (sem ele, todos). Enquanto voa, o que se move é o `feedback` (ou o próprio `child`), um pouco inclinado e com sombra, na largura `width`; o lugar de onde saiu fica apagado. |
| `DropTarget` | `id`, `onDrop`, `child`, `hint?`, `color?`, `hoverColor?`, `radius?` — onde soltar: a coluna. Com algo no ar que ele aceita, a borda acende de leve; com o cursor em cima, acende de vez e mostra o `hint` embaixo ("solte pra iniciar"). O que cai vai no `onDrop` com `payload` e `to` (o `id` do alvo) a mais nos argumentos; quem decide o que isso quer dizer é o plugin. |

O `initialize` diz `rfw: 1` numa Maestria que desenha widgets, e `rfw: 2` numa que tem
também o `Draggable` e o `DropTarget`; sem ele, desenhe blocos.

## O flutuante

Um painel pequeno que não entra na grade: ele fica por cima da lateral e dos painéis,
e você o arrasta pra onde quiser — o pomodoro, um cronômetro, um "gravando". Perto de
uma borda ele gruda nela (num canto, nas duas), e o lugar fica guardado no config,
preso ao canto mais perto: quando a janela muda de tamanho, ele continua no mesmo
canto em vez de sair da tela.

```js
await mx.request('float.show', {
  id: 'timer', width: 212, height: 64, corner: 'bottomRight',
  rfw: { library: fs.readFileSync('ui/float.rfwtxt', 'utf8') },
  data: { clock: '25:00' },
});
await mx.request('float.update', { id: 'timer', data: { clock: '24:59' } });
```

- **O conteúdo** é o de uma janela: `rfw` e `data` (o jeito certo pra um painel
  desse tamanho), ou `blocks`. Os eventos voltam como `view.action` com
  `viewId` igual ao `id` do flutuante — use um que nenhuma janela sua usa.
- **O tamanho** é do plugin: `width` de 80 a 480, `height` de 32 a 320 (200×64 se
  não vier). Pode trocar num `float.update`.
- **O lugar** é da janela: `corner` (`topLeft`, `topRight`, `bottomLeft`,
  `bottomRight`, o padrão) só vale até você arrastar. Um toque parado continua
  sendo dos botões de dentro; arrastar é segurar e mexer.
- Mandar só `data` num `float.update` repinta só o flutuante, não o app — um
  relógio pode atualizar uma vez por segundo.
- Ele sai com o plugin desligado, desinstalado ou caído; quando o processo sobe
  de novo, mande o `float.show` outra vez. Não volta sozinho quando o app reabre.

O `initialize` diz `floats: 1` numa Maestria que tem o flutuante; sem ele, abra
uma janela (`view.open`).

## A aba da lateral

A lateral tem uma faixa de ícones à esquerda, como a barra de atividades do VS
Code: as sessões e um ícone por plugin. Clicar num ícone troca a lateral inteira
pela aba daquele plugin.

Sem nada declarado, a Maestria monta a aba sozinha: as janelas abertas do plugin
e a lista de comandos dele. Pra desenhar a aba você mesmo, declare:

```json
"contributes": { "sidebar": true }
```

(exige `main`). A aba passa a ser os blocos que o plugin mandar por
`sidebar.update`, os mesmos das janelas (abaixo), numa letra um passo menor. As
janelas abertas do plugin continuam listadas em cima pela Maestria, porque achar
e fechar um painel é coisa da janela.

O ciclo:

1. Você clica no ícone. A janela sobe o processo, se preciso, e manda o evento
   `sidebar.shown` (de novo a cada clique, que é a deixa pra reler o estado).
2. O plugin responde com `sidebar.update({ blocks })`. Até o primeiro, a aba diz
   "abrindo…".
3. Os cliques e campos da aba chegam como `view.action` com `viewId: "sidebar"`.
   Um bloco `console` da aba recebe linhas por `view.appendLines` com o mesmo
   `viewId`.
4. Quando a aba sai da tela chega `sidebar.hidden`, e é a hora de parar de
   vigiar o que ninguém está vendo. Mandar `sidebar.update` com a aba escondida
   vale, e ela aparece pronta na próxima vez.

`sidebar.update({ badge: "3" })` põe um selo no ícone da faixa mesmo com a aba
fechada: as mudanças do git, o app rodando. `"sidebar"` é reservado e não serve
de `viewId` em `view.open`.

Dois blocos existem pensando na lateral: `section` (a régua das seções da
lateral) e `list` com `flat: true` (linhas sem moldura, como as das sessões).

## Janelas (blocos)

Uma janela de plugin é um painel como os outros (arrastável, com moldura e
cabeçalho) que a Maestria desenha com o tema da vez a partir de uma lista de
blocos. Existe uma janela por `viewId`: chamar `view.open` de novo troca o
conteúdo da que já existe e a traz pra tela. Janelas não voltam quando o app
reabre.

| `type` | campos |
|---|---|
| `heading` | `text` |
| `text` | `text`, `style?`: `dim`, `faint`, `mono`, `error`, `success`, `warning` |
| `markdown` | `text` (GFM; links abrem como no leitor) |
| `code` | `text` |
| `divider` | — |
| `section` | `text`, `count?`, `collapsed?`, `action?` — a régua das seções da lateral: a palavra, um traço e o número. Com `collapsed` (`true`/`false`) ela ganha a seta ▸/▾ dos workspaces, e o clique manda a `action`. Quem esconde o que vem embaixo é o plugin: fechada, não mande os blocos da seção. |
| `kv` | `items: [{ key, value, tone? }]` |
| `progress` | `value` (0–1, ou ausente pra indeterminado), `label?`, `detail?` (o número à direita do rótulo: "12% de 300%"), `tone?` (a cor da barra) |
| `list` | `items: [{ title, subtitle?, icon?, tone?, badge?, action?, actions? }]`, `empty?`. `actions: [{ action, icon, tooltip?, tone? }]` são botões de ícone que aparecem do lado do item com o mouse em cima — o preparar/descartar do controle de código do VS Code. Clicar num deles manda só a ação dele, não a do item. `flat: true` tira a moldura e os traços, pra aba da lateral. `menu: [{ action, label, icon?, tone?, disabled?, children? } | { type: "divider" }]` abre no botão direito do item (um item com `children: [{ action, label, tone? }]` abre um submenu, cada linha com a bolinha na cor do `tone`): deixe no hover uma ou duas ações e mande o resto pra cá, senão a linha fica sem lugar onde clicar. Os campos da lista do OrbStack estão logo abaixo. |
| `button` | `action`, `label`, `style?`: `primary`, `danger`, `icon`; `icon?`, `tone?`, `tooltip?`, `disabled?`. Com `icon` e sem `label` (ou `style: "icon"`) vira um botão só de ícone — a barra de debug do VS Code. Com `menu` (o mesmo formato do de um item de lista) o botão abre o menu embaixo dele em vez de mandar uma ação — o "…" de um cabeçalho. |
| `header` | `title`, `subtitle?`, `tone?` (a cor do subtítulo), `avatar?`, `status?`, `dim?`, `actions?: [botão]` — o cabeçalho de uma lista ou janela: o avatar, o título grande e os botões de ícone à direita (cada um vira `style: "icon"`, e aceita `menu`). |
| `card` | `children`, `padding?` — uma caixa arredondada um passo acima do fundo, com blocos dentro. Uma lista `flat` dentro de um cartão é a lista de containers do OrbStack. |
| `tabs` | `items: [{ label, action, active?, count?, icon? }]`, `align?: "center"` — abas num controle segmentado. Quem diz qual está ativa é o plugin (`active`); o clique manda a `action`. |
| `columns` | `children` — blocos lado a lado, todos da mesma largura: três cartões de CPU, memória e rede. |
| `terminal` | `tabId`, `expand?`, `height?` (360), `autofocus?`, `empty?` — um terminal de verdade dentro da janela: a sessão que o plugin abriu com `session.openShell({ embedded: true })`. Só as do próprio plugin; um `tabId` que não é dele (ou que já fechou) mostra o `empty`. Com `expand` ele fica com a altura que sobra, como o `console`. O clique nele dá o teclado a ele. |
| `input` | `id`, `label?`, `placeholder?`, `value?`, `multiline?`, `submit?` (ação no enter), `icon?` (o desenho na frente: `search` pra um campo de busca) |
| `checkbox` | `id`, `label`, `value?`, `action?` (dispara ao marcar) |
| `select` | `id`, `options: ["a", { value, label }]` (valor vazio vale), `value?`, `label?`, `placeholder?`, `loading?` (spinner no campo, travado — enquanto a lista não chega), `action?` |
| `console` | `id`, `lines?`, `max?` (5000), `expand?`, `height?` (320), `empty?`, `follow?`. Com `follow: false` ele não gruda no fim quando chegam linhas (um diff, que se lê de cima); trocar o `id` recomeça do topo. Linhas são textos, `{ text, tone }` ou `{ spans: [{ text, tone?, bold? }], tone? }` — a linha em pedaços, cada um com a cor dele: o nome do serviço na frente de um log do compose, as cores ANSI do programa. Um console que sai dos blocos vai embora com as linhas; quem troca de aba e volta manda `lines` de novo. Com `expand: true` a janela para de rolar: o que vem antes fica fixo em cima e o console ocupa a altura que sobra. Um `view.update` que manda o console sem `lines` mantém as que ele já tem. |
| `calendar` | `id`, `mode?` (`single` ou `range`), `value?`, `min?`, `max?`, `action?`. Um mês em português, com setas. Em `single` o valor é `"AAAA-MM-DD"`; em `range` é `{ from, to }`: o primeiro clique marca o começo, o segundo fecha o período (em qualquer ordem) e o terceiro recomeça. `min`/`max` são datas ou `"today"` — um relatório não escolhe amanhã. `presets: [{ label, from, to }]` vira a coluna de atalhos do cartão (uma fileira em cima, num painel estreito), com o que bate com a escolha aceso. O cartão diz embaixo o que está escolhido e fica centrado no painel. |
| `row` | `children`: botões lado a lado; `align: "center"` centra a fileira (e num `text`, o texto), `"end"` encosta à direita e `"between"` espalha. Quem não é botão ganha `width` (ou 240). |

### A lista do OrbStack

Um item de `list` aceita ainda estes campos, todos opcionais — é com eles que a
aba do docker desenha os containers como o OrbStack:

| campo | |
|---|---|
| `avatar` | o quadrado arredondado e colorido na frente da linha, no lugar do `icon`: um nome de ícone (ou `.svg` da pasta do plugin), ou `{ icon?, text?, color?, shape?, plain?, svg? }` — `color` é um `tone`, `text` põe letras no lugar do desenho, `shape: "circle"` faz um círculo, `plain` tira a caixa. `svg` é um desenho inteiro em texto, com as cores dele (a janela não pinta por cima): o cubo colorido de cada container do docker. |
| `status` | um `tone`: a bolinha no canto do avatar — no ar, subindo, caído. |
| `dim` | a linha apagada, com o avatar cinza: o container parado ao lado dos que rodam. |
| `strong` | o título em negrito: a linha de um projeto. |
| `indent` | quantos níveis de recuo: os containers dentro do projeto. |
| `expanded` | `true`/`false` põe a seta de abrir e fechar na frente. O clique nela manda `toggle` (ou a `action` da linha, sem `toggle`). Quem esconde os filhos é o plugin, como no `section`. Numa lista com alguma seta, as linhas sem seta guardam o lugar dela, e os avatares do mesmo nível ficam alinhados. |
| `meta` | um texto curto à direita, sempre à vista — a porta publicada, o tamanho de uma imagem. Com o mouse em cima ele dá lugar às `actions`. `metaTone` pinta. |
| `subtitleTone` | a cor do subtítulo. |
| `selected` | a linha acesa, na cor de destaque: a do que está aberto numa janela. |

Na própria `list`, `alwaysActions: true` deixa as `actions` de cada linha sempre à vista, e não
só com o mouse em cima — o ▶ e a lixeira de cada container na lista do OrbStack. Um `section`
com `style: "label"` é só a palavra, sem o traço: o "Parados" que separa o fim da lista.

Uma Maestria que ainda não conhece esses campos desenha a linha como antes —
mande também `icon` e `tone` pra ela.

`input`, `checkbox` e `select` aceitam `disabled`. Campos dentro de um `card` ou de um
`columns` valem como os de fora: o texto vai nos `values`.

`icon`: `check`, `error`, `warning`, `info`, `file`, `folder`, `play`, `terminal`,
`link`, `star`, `clock`, `user`, `task`, `continue`, `pause`, `step-over`,
`step-into`, `step-out`, `reload`, `restart`, `stop`, `devtools`, `bug`, `device`,
`refresh`, `clear`, `copy`, `search`, `settings`, `calendar`, `report`, `receipt`,
`open`, `add`, `remove`, `undo`, `branch`, `commit`, `push`, `pull`, `sync`,
`server`, `edit`, `dot`, `box`, `stack`, `image`, `drive`, `network`, `cpu`, `trash`, `globe`,
`more`. `tone`: `green`, `red`, `yellow`, `accent`, `purple`, `faint`, as do terminal `blue`,
`cyan`, `magenta`, `white` e `black` (pra quando as cores de estado não bastam: um avatar por imagem), ou um hex
(`#4FC1FF`) — que é como uma configuração de cor chega num `tone`.

Clicar num botão, num item de lista com `action`, apertar enter num `input` com
`submit` ou mexer num `checkbox`/`select` com `action` manda um `view.action` com
os `values` de todos os campos da janela (`{ id: texto | bool | valor }`). O texto
digitado fica guardado na janela: um `view.update` que mantém o mesmo `id` não
apaga o que você escreveu. O campo só é sobrescrito quando o plugin manda um
`value` diferente do anterior.

Um tipo desconhecido aparece como "bloco desconhecido", pra você ver que mandou
algo que esta versão não desenha.
