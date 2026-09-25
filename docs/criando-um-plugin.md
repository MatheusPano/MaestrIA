# Criando um plugin pra Maestria

Um guia curto, do zero até um plugin com janela. A referência completa (todos os
campos, métodos e blocos) está em [`plugins.md`](plugins.md). Os plugins de
verdade, pra usar de exemplo, estão em `maestria-plugins/` (`relatorio-do-dia` e
`flutter`).

## O mínimo

Um plugin é **uma pasta com um `maestria-plugin.json`**. Só isso já é um plugin
válido:

```json
{
  "id": "voce.ola",
  "name": "Olá",
  "version": "0.1.0"
}
```

| campo | regra |
|---|---|
| `id` | obrigatório, único. Minúsculas, dígitos, `.`, `-` e `_` (`voce.nome-do-plugin`). |
| `version` | obrigatório. |
| `name` | o que aparece na tela. Sem ele, vale o `id`. |

Um plugin assim não faz nada, mas aparece em Configurações → plugins. Daqui você
acrescenta o que quiser, em três níveis:

1. **Só declarações** — temas e comandos prontos, sem programa nenhum.
2. **Um processo** — um programa seu (node, python, o que for) que recebe
   comandos e eventos e pede coisas à janela.
3. **Uma janela** — o processo desenha um painel com botões, listas, campos e
   console.

## Carregar enquanto você escreve

Configurações → plugins → **carregar pasta de desenvolvimento…** (no fim da
seção, abaixo da lista) e escolha a pasta. É um link: o plugin é lido de onde ele está. Depois de editar qualquer
coisa, aperte **reiniciar** (↻) na linha do plugin.

Se algo não funcionar, o **log** (ícone de recibo na mesma linha) mostra por quê:
erro no manifesto, tecla recusada, o stderr do seu processo.

## Nível 1: só declarações

Um comando que roda um shell e aparece no menu do painel (botão direito →
plugins), com uma tecla:

```json
{
  "id": "voce.ola",
  "name": "Olá",
  "version": "0.1.0",
  "contributes": {
    "commands": [
      {
        "id": "status",
        "title": "git status",
        "run": "git status -sb | head -1",
        "in": "background",
        "key": "meta+alt+g"
      },
      {
        "id": "revisar",
        "title": "pedir revisão",
        "send": "revise o diff atual de ${cwd} e aponte bugs"
      }
    ]
  }
}
```

- `run` roda um comando de shell na pasta do painel em foco. Com
  `"in": "background"` a última linha da saída vira um recado; sem ele, abre um
  terminal.
- `send` cola o texto na sessão do claude em foco e aperta enter.
- `${cwd}`, `${folder}`, `${sessionId}`, `${title}` e `${pluginDir}` são trocados
  pelos valores do painel.
- `key`: modificadores `meta` (⌘ — Ctrl+Shift no Linux), `alt`, `shift`, `ctrl` e a
  tecla, com `+`.
  Uma tecla que a Maestria já usa não é tomada — o comando fica sem tecla e a
  tela de plugins avisa.

Temas também são só declaração: veja "Temas" em [`plugins.md`](plugins.md).

## Nível 2: um processo

Quando precisa de lógica, o plugin tem um `main`: o programa que a Maestria sobe.

```
voce.ola/
  maestria-plugin.json
  maestria.js      ← o cliente do protocolo (copie de um plugin existente)
  main.js          ← o seu código
```

```json
{
  "id": "voce.ola",
  "name": "Olá",
  "version": "0.2.0",
  "main": ["node", "main.js"],
  "activationEvents": ["onCommand:ola"],
  "contributes": {
    "commands": [{ "id": "ola", "title": "dizer olá", "key": "meta+alt+o" }]
  }
}
```

Um comando **sem** `run` nem `send` vai pro seu processo. O `main.js`:

```js
const mx = require('./maestria');

mx.onRequest('command.invoke', async ({ command, context }) => {
  if (command === 'ola') {
    const sessoes = await mx.request('sessions.list');
    await mx.request('window.showBanner', {
      text: `olá! ${sessoes.length} painéis abertos; o em foco está em ${context.cwd}`,
    });
  }
  return null;
});

mx.start();
```

O `maestria.js` (~100 linhas, sem dependências) cuida do protocolo. Copie o de
`maestria-plugins/flutter/maestria.js` ou de `examples/plugins/exemplo-completo/`.

**Quando o processo sobe** (`activationEvents`): `onCommand:<id>` na primeira vez
que o comando roda, `onStartup` com o app, `onHook:Stop` quando uma sessão do
claude termina um turno, `onSession` quando um painel abre, fecha ou muda de
status. Sem nenhum, ele sobe com o app.

**O que dá pra pedir à janela** (`mx.request(método, params)`): recados,
notificações, a lista de sessões, pastas e projetos, mandar texto pra uma sessão,
abrir sessão ou terminal, abrir um markdown no leitor, abrir o VS Code numa
linha, perguntar com um seletor rápido… A lista completa está em "Do plugin pra
janela", em [`plugins.md`](plugins.md).

### Permissões

O que mexe no que é seu precisa ser declarado — e aparece na hora de instalar:

```json
"permissions": ["hooks", "terminal.write"]
```

| permissão | pra quê |
|---|---|
| `hooks` | receber os eventos das sessões do claude, e ver o que cada uma pediu e fez |
| `terminal.write` | mandar texto pra um painel (`terminal.sendText`) |
| `sessions.create` | abrir sessões do claude e terminais |
| `notifications` | notificação do sistema |

Sem a permissão, o pedido volta com erro. Isso não é um sandbox: o seu processo
roda com as suas permissões de usuário.

### Ouvir as sessões

Com `hooks` declarado, os eventos das sessões do claude chegam como notificação:

```js
mx.onNotification('event', async (e) => {
  if (e.type === 'hook' && e.name === 'Stop') {
    await mx.request('window.showBanner', { text: 'uma sessão terminou o turno' });
  }
});
```

## Nível 3: uma janela

O processo pode abrir um painel. Ele manda uma lista de **blocos** em json, e a
Maestria desenha com o tema dela:

```js
async function abrir() {
  await mx.request('view.open', {
    viewId: 'principal',
    title: 'olá',
    blocks: [
      { type: 'heading', text: 'Olá' },
      { type: 'input', id: 'nome', label: 'seu nome', submit: 'saudar' },
      { type: 'button', action: 'saudar', label: 'saudar', style: 'primary' },
    ],
  });
}

// Clique num botão, enter num campo: tudo chega aqui, com os valores dos campos.
mx.onNotification('view.action', async ({ viewId, action, values }) => {
  if (action === 'saudar') {
    await mx.request('view.update', {
      viewId,
      blocks: [
        { type: 'heading', text: `Olá, ${values.nome || 'alguém'}!` },
        { type: 'input', id: 'nome', label: 'seu nome', submit: 'saudar' },
        { type: 'button', action: 'saudar', label: 'saudar de novo' },
      ],
    });
  }
});
```

- Uma janela por `viewId`: chamar `view.open` de novo traz a mesma de volta.
- `view.update` troca os blocos. O que você digitou num campo fica, se o `id`
  dele continuar igual.
- Os blocos: texto, markdown, código, lista, tabela chave–valor, progresso,
  botões (com ou sem ícone), campo, caixa de marcar, seletor, calendário e um
  console que recebe linhas aos poucos. Veja "Janelas (blocos)" em
  [`plugins.md`](plugins.md).
- As janelas de um plugin ficam numa seção própria no fim da lateral.

## Os detalhes que pegam

- **Nunca escreva no stdout.** O stdout é o canal do protocolo — um
  `console.log` perdido estraga a conversa. Use `mx.log(...)` ou `console.error`,
  que vão pro log do plugin.
- **node 22 ou mais novo**, se for usar o `WebSocket` global. O `node` é achado
  no PATH do sistema com os fallbacks de sempre (`/opt/homebrew/bin` etc.).
- **Teclas com ⌥ + E, I, N, U ou crase** são acentos no teclado do Mac. Elas
  funcionam (a Maestria confere a tecla pela posição), mas prefira outras se o
  plugin for pra mais gente.
- **Configurações:** se o seu plugin tem opções (cores, caminhos, liga/desliga),
  declare em `contributes.settings`. A Maestria desenha o formulário e manda os
  valores no `initialize` e em `settings.changed`.
- **Guardar coisas:** use a pasta de `MAESTRIA_PLUGIN_DATA` (variável de
  ambiente do processo). Ela sobrevive a atualizar o plugin.
- **Botão no rodapé da lateral:** um comando com `"sidebar": true` e um `icon`
  (um nome de ícone, ou um `.svg` da pasta do plugin).

## Instalar noutra máquina

Configurações → plugins → **instalar…** aceita uma URL de git, um `.zip` ou uma
pasta. Antes de instalar, a tela mostra o que o plugin roda e as permissões que
pede.

## Lista de conferência

- [ ] `maestria-plugin.json` na raiz, com `id` e `version`.
- [ ] Com processo: `main` apontando pro programa, e o `maestria.js` junto.
- [ ] `activationEvents` com os eventos que devem subir o processo.
- [ ] `permissions` com o que ele pede à janela.
- [ ] Nada escrito no stdout fora do protocolo.
- [ ] Carregado como pasta de desenvolvimento e testado; o log sem erro.
