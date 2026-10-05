# Uso do contexto no painel — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cada painel de sessão do Claude mostra no cabeçalho quanto do contexto está em uso, com os números vindos da linha de status do Claude Code.

**Architecture:** O `--settings` de cada sessão ganha um `statusLine` que roda um script do app; o script encaminha o JSON da linha de status para uma rota nova do servidor de hooks e roda a linha de status do usuário. O store guarda um `ContextUsage` por painel, e o cabeçalho desenha uma ficha com mini barra.

**Tech Stack:** Flutter 3.47.4 (fvm), Dart 3.13, `dart:io` HttpServer, POSIX `sh` + `curl`.

**Spec:** `docs/superpowers/specs/2026-10-02-context-usage-design.md`

## Global Constraints

- Rode tudo com `fvm flutter …`. Não rode `dart format` no repositório.
- Identificadores, nomes de arquivo e chaves em inglês; comentários, textos da interface e commits em português, com acentos. Comentários dizem *por quê*.
- Commits com a identidade git configurada no repositório, sem nenhuma atribuição de IA.
- Branch `feature/TASK#80059` (já criada, empilhada sobre `feature/TASK#80058`).
- Nada do `ContextUsage` vai para o config.
- Testes que criam `AppStore` e disparam save (debounce de 400ms) terminam com `store.dispose()` no fim do corpo, como os vizinhos; painéis do claude animam para sempre, então nunca `pumpAndSettle` com um deles na tela.

## Review Focus

1. **Usuário sem `statusLine` próprio** — a sessão abre normalmente, o script não imprime nada, e a ficha aparece mesmo assim. (Task 2.)
2. **Linha de status do usuário com aspas, `$`, `~` e pipes no comando** — chega intacta ao `sh -c` pelo base64. (Task 2.)
3. **`/compact` no meio da sessão** — `current_usage` nulo apaga a ficha até a próxima resposta. (Task 1.)
4. **`curl` travado ou ausente** — a linha de status do usuário continua saindo, sem atraso perceptível. (Task 2, teste com URL para porta fechada.)
5. **Painel estreito** — a ficha some junto com as outras. (Task 3.)

---

### Task 1: `ContextUsage`, a rota `/status` e o store

**Files:**
- Modify: `lib/models.dart` (classe nova `ContextUsage`), `lib/services/hooks.dart` (rota e evento), `lib/services/store.dart` (`MxTab.context`, aplicar o evento)
- Test: `test/context_usage_test.dart` (novo)

**Interfaces — Produces:**
- `class ContextUsage { const ContextUsage({required this.percent, required this.tokens, required this.window}); final int percent; final int tokens; final int window; static ContextUsage? fromStatusLine(Object? json); }` em `lib/models.dart`.
- `class StatusEvent { StatusEvent(this.tabId, this.payload); final String tabId; final Map<String, dynamic> payload; }` e `Stream<StatusEvent> get statuses` no `HookServer`.
- `ContextUsage? context;` no `MxTab` (em `store.dart`), e `void applyStatus(StatusEvent e)` no `AppStore`, ligado no `init()` como o `hooks.events.listen(applyHook)`.

- [ ] **Step 1: Testes que falham** em `test/context_usage_test.dart`:
  - `fromStatusLine` com `{'context_window': {'used_percentage': 58.4, 'context_window_size': 200000, 'current_usage': {'input_tokens': 10, 'cache_creation_input_tokens': 1000, 'cache_read_input_tokens': 115000, 'output_tokens': 300}}}` → `percent 58`, `tokens 116010`, `window 200000` (o percentual é arredondado para o inteiro mais próximo; `output_tokens` não entra).
  - `used_percentage: null` → null; `current_usage: null` → null; sem `context_window` → null; `'nada'` → null; `context_window_size` ausente ou 0 → null.
  - Servidor: suba um `HookServer` (veja `test/hook_port_test.dart` para o padrão de subir e parar), faça `HttpClient().postUrl('http://127.0.0.1:${server.port}/status/tab9')` com um corpo válido, e espere `server.statuses.first` ter `tabId == 'tab9'` e o payload; e um POST em `/hook/tab9` com `hook_event_name` continua saindo em `server.events` e **não** em `statuses`.
  - Store: `applyStatus(StatusEvent('t1', corpoVálido))` num store com um painel `t1` grava `tab.context` com os números; um corpo com `current_usage: null` volta `tab.context` para null; painel inexistente não lança.
- [ ] **Step 2:** `fvm flutter test test/context_usage_test.dart` → FAIL (compilação).
- [ ] **Step 3: Implementar.**
  - `ContextUsage.fromStatusLine`: só aceita `Map`; lê `context_window` como `Map`; `used_percentage` e `context_window_size` como `num`; `current_usage` como `Map` com os três campos `num` (ausente conta 0); devolve null quando faltar percentual, `current_usage` ou janela (> 0). Comentário: por que nulo é "sem número agora" (antes da primeira resposta e depois de `/compact`).
  - `HookServer.start`: no `listen`, se `segments.first == 'status'`, decodifica o corpo e emite `StatusEvent(segments[1], payload)` num `StreamController.broadcast` próprio; responde vazio. O caminho `/hook/…` não muda.
  - `AppStore.applyStatus`: acha o painel (`_byId`), troca `tab.context = ContextUsage.fromStatusLine(e.payload)` e chama `notifyListeners()` só se o valor mudou (compare os três campos).
- [ ] **Step 4:** testes do arquivo PASS; `fvm flutter analyze` limpo; `fvm flutter test` inteiro PASS.
- [ ] **Step 5: Commit** `lê o uso do contexto que a linha de status do Claude Code manda e guarda no painel`.

---

### Task 2: O script da linha de status e o `statusLine` no `--settings`

**Files:**
- Modify: `lib/services/hooks.dart` (`settingsFor`, gravar o script), `lib/services/store.dart` (passar o cwd ao `settingsFor` em `_launchClaude`), `packaging/linux/make-deb.sh` (`RUN_DEPS` com `curl`)
- Test: `test/statusline_test.dart` (novo); ajustar `test/hook_port_test.dart` se a assinatura de `settingsFor` mudar

**Interfaces:**
- Consumes: a rota `/status/<tabId>` (Task 1).
- Produces: `static const statusLineScript` (o texto do script) e `static File get statusLineFile => File('$mxStateDir/statusline.sh')` no `HookServer`; o script é gravado no `start()` (sobrescreve sempre, para atualizar entre versões; falha de escrita é engolida, como a do `portFile`). `String settingsFor(String tabId, {String? cwd})`. `static Map<String, dynamic>? userStatusLine(String? cwd, {String? home})` — o `statusLine` do usuário pela precedência do spec (`home` default `Platform.environment['HOME']`, parâmetro só para teste).

- [ ] **Step 1: Testes que falham** em `test/statusline_test.dart`:
  - `userStatusLine`: com diretórios temporários de `cwd` e `home`, o `settings.local.json` do projeto vence o `settings.json` do projeto, que vence o do `home`; um arquivo com json inválido é pulado; `statusLine` com `type` diferente de `command` é ignorado; nada em lugar nenhum → null.
  - `settingsFor('t1', cwd: …)` sem `statusLine` do usuário: o json tem `statusLine.type == 'command'` e o `command` contém `statusline.sh`, a URL `http://127.0.0.1:<porta>/status/t1` e um terceiro argumento vazio `''`; os `hooks` continuam iguais.
  - Com `statusLine` do usuário `{"type":"command","command":"echo \"$HOME\" | tr a-z A-Z","padding":2}`: o terceiro argumento é o base64 desse comando, e `padding: 2` vai no `statusLine` do app.
  - O script de verdade: grave `statusLineScript` num arquivo temporário e rode `Process.run('sh', ['-c', "printf '%s' '<json>' | sh <arquivo> <url> <base64>"])`:
    - com o comando do usuário `cat` (em base64), a saída é o json recebido;
    - com o terceiro argumento vazio, a saída é vazia e o código de saída é 0;
    - com o comando do usuário contendo aspas simples, `$` e pipe (por exemplo `printf "%s" 'a$b' | tr a b`), a saída bate com rodar o comando direto;
    - com a URL apontando para um `HttpServer` de teste, o servidor recebe o json (espere até 2s);
    - com a URL apontando para uma porta fechada, o script termina em menos de 1,5s e a saída do comando do usuário sai igual.
- [ ] **Step 2:** `fvm flutter test test/statusline_test.dart` → FAIL.
- [ ] **Step 3: Implementar.**
  - O script (POSIX `sh`, sem bashismos):

    ```sh
    #!/bin/sh
    # A linha de status de uma sessão aberta pela maestria: manda o que o
    # Claude Code mostrou pra janela e devolve a linha de status do usuário.
    url="$1"
    user="$2"
    input=$(cat)
    # Em segundo plano e com a saída descartada: a linha de status não pode
    # esperar pela janela, nem quando ela está fechada.
    printf '%s' "$input" | curl -s -m 1 -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$url" >/dev/null 2>&1 &
    if [ -n "$user" ]; then
      cmd=$(printf '%s' "$user" | base64 --decode 2>/dev/null || printf '%s' "$user" | base64 -D)
      printf '%s' "$input" | sh -c "$cmd"
    fi
    ```

    (Confira no macOS e no Linux do CI que `base64 --decode` funciona; o `|| … -D` é a volta do macOS antigo.)
  - `settingsFor(tabId, {cwd})`: monta `statusLine` com `type: 'command'`, `command: "sh ${Sh.q(statusLineFile.path)} ${Sh.q(url)} ${Sh.q(b64)}"` (importe o `Sh` de `shell.dart`, ou repita uma função de aspas simples se o import criar ciclo — diga qual no relatório) e, se o do usuário tiver, `padding`. O base64 é do texto UTF-8 do comando do usuário.
  - `_launchClaude`: `hooks.settingsFor(tab.id, cwd: tab.cwd)`. O `display` do comando no terminal continua sem mostrar o json.
  - `make-deb.sh`: `RUN_DEPS="git, libnotify-bin, xdg-utils, curl"`.
- [ ] **Step 4:** testes PASS; analyze limpo; suíte inteira PASS.
- [ ] **Step 5: Commit** `injeta uma linha de status que manda o uso do contexto pra janela e mantém a do usuário`.

---

### Task 3: A ficha no cabeçalho

**Files:**
- Modify: `lib/ui/terminal_pane.dart` (ficha nova no grupo das fichas)
- Test: `test/pane_header_test.dart`

**Interfaces:**
- Consumes: `MxTab.context` e `ContextUsage` (Task 1).
- Produces: `String formatTokens(int n)` (top-level, em `terminal_pane.dart` ou num lugar de formatação que já exista — procure antes) e o widget `_ContextChip`.

- [ ] **Step 1: Testes que falham** em `test/pane_header_test.dart` (use o jeito de montar o cabeçalho que o arquivo já usa):
  - `formatTokens`: `999 → '999'`, `1000 → '1 mil'`, `116010 → '116 mil'`, `200000 → '200 mil'`, `1000000 → '1 mi'`, `1200000 → '1,2 mi'`.
  - Painel do claude com `context = ContextUsage(percent: 58, tokens: 116010, window: 200000)`: aparece `58%`, e o tooltip `116 mil de 200 mil tokens`.
  - Cor: 59% usa `Mx.fgDim`, 60% `Mx.yellow`, 84% `Mx.yellow`, 85% `Mx.red` (leia a cor do `Text` do percentual).
  - Sem `context` não há `%` no cabeçalho; num terminal (`TabKind.shell`) com `context` preenchido também não.
  - Num cabeçalho estreito (largura abaixo do corte de 170 que já esconde as fichas), a ficha não aparece.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3: Implementar** `_ContextChip` com a mesma caixa do `_Chip` (margem à direita 6, padding 7×3, fundo da cor com alpha 0,12, raio 4): 5 segmentos de 4×7 px com 1 px de espaço, os preenchidos na cor da faixa e os vazios na mesma cor com alpha 0,25 (preenchidos = `(percent / 20).ceil().clamp(0, 5)`, com 0% sem nenhum), 4 px de espaço e o `Text('$percent%')` em 11 px na cor da faixa; tudo dentro de um `Tooltip(message: '${formatTokens(tokens)} de ${formatTokens(window)} tokens')`. Entra no `Row` das fichas logo depois da ficha de branch, só para `tab.kind == TabKind.claude` com `tab.context != null`. Comentário curto dizendo de onde vem o número (a linha de status) e por que some (null antes da primeira resposta e depois de `/compact`).
- [ ] **Step 4:** PASS; analyze limpo; suíte inteira PASS.
- [ ] **Step 5: Commit** `mostra no cabeçalho do painel quanto do contexto a sessão do Claude já usou`.

---

### Task 4: Verificação no app

- [ ] `make analyze && make test` limpos.
- [ ] `fvm flutter run -d macos`: abrir uma sessão nova do Claude, mandar uma mensagem, conferir a ficha e o tooltip; conferir que a linha de status do Renato continua no terminal; rodar `/compact` e conferir que a ficha some e volta na resposta seguinte. (Feito pelo Renato.)
