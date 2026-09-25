// Um cliente mínimo do protocolo de plugins da Maestria, sem dependências.
//
// Copie este arquivo pro seu plugin. O protocolo é JSON-RPC 2.0, uma
// mensagem json por linha no stdin/stdout -- veja docs/plugins.md. Nunca
// escreva no stdout por conta própria (console.log): é o canal do protocolo.
// Use `log()` daqui, ou console.error, que vai pro log do plugin.

'use strict';

const readline = require('readline');

const handlers = { requests: {}, notifications: {} };
const pending = new Map();
let nextId = 1;

function send(message) {
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
}

/** Pede algo à janela e espera a resposta. Rejeita com o erro que ela mandar. */
function request(method, params) {
  const id = `p${nextId++}`;
  send({ id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

/** Avisa a janela sem esperar resposta. */
function notify(method, params) {
  send({ method, params });
}

/** Escreve no log do plugin (configurações → plugins → log). */
function log(...parts) {
  notify('log', { message: parts.map((p) => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ') });
}

/** Atende um pedido da janela: `initialize`, `command.invoke`. */
function onRequest(method, fn) {
  handlers.requests[method] = fn;
}

/** Escuta uma notificação da janela: `event`, `view.action`, `shutdown`. */
function onNotification(method, fn) {
  handlers.notifications[method] = fn;
}

async function dispatch(msg) {
  if (msg.method !== undefined && msg.id !== undefined) {
    const fn = handlers.requests[msg.method];
    if (!fn) {
      send({ id: msg.id, error: { code: -32601, message: `método desconhecido: ${msg.method}` } });
      return;
    }
    try {
      const result = await fn(msg.params || {});
      send({ id: msg.id, result: result === undefined ? null : result });
    } catch (e) {
      send({ id: msg.id, error: { code: -32603, message: String((e && e.message) || e) } });
    }
    return;
  }
  if (msg.method !== undefined) {
    const fn = handlers.notifications[msg.method];
    if (fn) {
      try {
        await fn(msg.params || {});
      } catch (e) {
        log(`erro em ${msg.method}:`, String((e && e.stack) || e));
      }
    }
    return;
  }
  const waiting = pending.get(msg.id);
  if (!waiting) return;
  pending.delete(msg.id);
  if (msg.error) waiting.reject(new Error(msg.error.message));
  else waiting.resolve(msg.result);
}

/** Começa a ouvir. Chame depois de registrar os handlers. */
function start() {
  if (!handlers.requests.initialize) onRequest('initialize', () => ({}));
  if (!handlers.notifications.shutdown) onNotification('shutdown', () => process.exit(0));
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    dispatch(msg);
  });
  // stdin fechado é a janela indo embora.
  rl.on('close', () => process.exit(0));
}

module.exports = { request, notify, log, onRequest, onNotification, start };
