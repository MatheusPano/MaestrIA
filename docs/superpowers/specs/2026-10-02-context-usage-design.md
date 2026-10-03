# Uso do contexto no painel da sessão do Claude

TASK#80059.

## Objetivo

Cada painel de sessão do Claude mostra, no cabeçalho, quanto do contexto a sessão já usou, como o Claude Code Desktop faz. Hoje isso só se sabe rodando `/context` na própria sessão.

Critério de sucesso: numa sessão aberta depois da atualização, a ficha aparece depois da primeira resposta, acompanha o uso a cada turno, some depois de um `/compact` até a resposta seguinte, e a linha de status do Renato continua aparecendo igual no terminal.

## Decisões tomadas

| Pergunta | Decisão |
|---|---|
| Fonte dos números | A linha de status do Claude Code (`statusLine`), que recebe `context_window` num JSON documentado |
| Detalhamento por categoria (o do `/context`) | Fora: só existe pelo Agent SDK, e as sessões rodam o `claude` num terminal |
| Transcript `.jsonl` | Não usar: o formato é interno e muda entre versões |
| Formato na tela | Ficha com mini barra e percentual, junto das fichas de branch e feature; tooltip com os tokens |

## 1. De onde vêm os números

O `--settings` que o app já passa a cada sessão (`HookServer.settingsFor`) passa a incluir um `statusLine` do tipo `command`, que roda um script do app:

```
sh '<~/.maestria/statusline.sh>' '<http://127.0.0.1:PORTA/status/<tabId>>' '<comando do usuário em base64, ou vazio>'
```

O script (`~/.maestria/statusline.sh`, gravado pelo app ao subir o servidor de hooks):

1. Lê o JSON inteiro do stdin.
2. Manda esse JSON por POST para a URL, em segundo plano, com `curl -s -m 1`, sem esperar resposta e com a saída descartada, para nunca segurar a linha de status.
3. Se recebeu um comando do usuário, roda esse comando com `sh -c`, passando o mesmo JSON no stdin, e o que ele imprimir é a saída do script.

O comando do usuário é o `statusLine` que a sessão teria sem o app. Ao abrir a sessão, o app procura, nesta ordem, e fica com o primeiro que achar: `<cwd>/.claude/settings.local.json`, `<cwd>/.claude/settings.json`, `~/.claude/settings.json`. Só vale `statusLine.type == "command"`; o `padding` dele, se houver, vai junto no `statusLine` do app. Arquivo que não existe ou não é json é pulado.

Como o `--settings` vale pela vida da sessão, só as sessões abertas depois da atualização mostram a ficha.

## 2. O que o app guarda

- Rota nova no servidor de hooks: `POST /status/<tabId>`. A resposta é vazia e imediata, como a dos hooks.
- O corpo vira um `ContextUsage` do painel (em memória, não vai pro config):
  - `percent`: `context_window.used_percentage`;
  - `tokens`: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` de `context_window.current_usage`;
  - `window`: `context_window.context_window_size`.
- Se `used_percentage` ou `current_usage` vier nulo (antes da primeira resposta e logo depois de um `/compact`), ou o corpo não tiver `context_window`, o painel fica sem uso (null) e a ficha some.
- Painel desconhecido ou corpo inválido: ignorado em silêncio, como nos hooks.

## 3. A ficha

- No cabeçalho do painel do Claude (`TabKind.claude`), no grupo das fichas (branch, feature, alterados), quando há uso: uma mini barra de 5 segmentos preenchidos pela proporção, seguida do percentual inteiro (`58%`).
- Cor: abaixo de 60% `Mx.fgDim`; de 60% até 85% (exclusive) `Mx.yellow`; 85% ou mais `Mx.red`.
- Tooltip: `116 mil de 200 mil tokens`. Números abaixo de mil aparecem inteiros; de mil a um milhão (exclusive), arredondados para `N mil`; a partir de um milhão, `N mi` com até uma casa decimal (`1 mi`, `1,2 mi`).
- Some junto com as outras fichas quando o painel é estreito (a regra de largura que já existe).

## 4. Linux

O `.deb` passa a depender de `curl` (`RUN_DEPS` em `packaging/linux/make-deb.sh`). No macOS o `curl` já vem com o sistema.

## 5. Testes

- Leitura do JSON da linha de status: caso completo, `used_percentage` nulo, `current_usage` nulo, sem `context_window`, tipos errados.
- Servidor: um POST em `/status/<tab>` chega como evento para o painel certo; `/hook/...` continua igual.
- `settingsFor`: com e sem comando do usuário; com `padding`; a precedência dos três arquivos.
- Script, de verdade com `sh`: repassa a saída do comando do usuário recebendo o JSON no stdin; sem comando, não imprime nada; com a URL apontando para um servidor de teste, o servidor recebe o JSON.
- Ficha: percentual, as três faixas de cor, o tooltip com os formatos de número, e a ficha ausente sem uso e em terminal.

## Riscos

- **A linha de status do usuário deixa de aparecer** se a resolução errar o arquivo. Coberto pelos testes de precedência e pelo teste do script repassando a saída.
- **Campos do `context_window` mudarem de nome** numa versão do Claude Code: a ficha some (vira null), sem quebrar nada.
- **`curl` ausente**: o POST falha em silêncio, a ficha não aparece, e a linha de status do usuário continua funcionando.
