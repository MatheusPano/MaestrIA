// Exemplo completo: comandos, eventos das sessões, notificação e uma janela
// com blocos. Leia junto com docs/plugins.md.

'use strict';

const mx = require('./maestria');

const VIEW = 'painel';

// O que o plugin sabe, montado dos eventos que chegam.
const state = {
  turns: 0,
  tools: {}, // nome da ferramenta → quantas vezes rodou
  lastStop: null, // { tabId, at, message }
  notifyOnStop: false,
  viewOpen: false,
};

mx.onRequest('initialize', (params) => {
  mx.log('subi com a API', params.apiVersion, 'e as permissões', params.permissions);
  return {};
});

mx.onRequest('command.invoke', async ({ command, context }) => {
  switch (command) {
    case 'painel':
      await openView();
      return null;
    case 'resumo': {
      const sessions = await mx.request('sessions.list');
      const claude = sessions.filter((s) => s.kind === 'claude');
      const waiting = claude.filter((s) => s.needsYou);
      await mx.request('window.showBanner', {
        text: `${claude.length} sessões do claude, ${waiting.length} esperando você`,
      });
      return null;
    }
    case 'markdown':
      await mx.request('pane.openMarkdown', {
        title: 'contexto do painel',
        markdown: [
          '# O que o comando recebeu',
          '',
          '```json',
          JSON.stringify(context, null, 2),
          '```',
        ].join('\n'),
      });
      return null;
    default:
      throw new Error(`comando desconhecido: ${command}`);
  }
});

mx.onNotification('event', async (event) => {
  if (event.type !== 'hook') return;
  const { name, payload, tabId } = event;
  if (name === 'PreToolUse' && payload.tool_name) {
    state.tools[payload.tool_name] = (state.tools[payload.tool_name] || 0) + 1;
  }
  if (name === 'Stop') {
    state.turns += 1;
    state.lastStop = {
      tabId,
      at: new Date().toLocaleTimeString('pt-BR'),
      message: (payload.last_assistant_message || '').slice(0, 160),
    };
    if (state.notifyOnStop) {
      await mx.request('window.notify', {
        title: 'uma sessão terminou o turno',
        body: state.lastStop.message || 'sem recado',
      });
    }
  }
  if (state.viewOpen && (name === 'Stop' || name === 'PreToolUse')) await refreshView();
});

mx.onNotification('view.action', async ({ viewId, action, values }) => {
  if (viewId !== VIEW) return;
  state.notifyOnStop = values.notificar === true;
  if (action === 'enviar') {
    const text = (values.mensagem || '').trim();
    if (!text) {
      await mx.request('window.showBanner', { text: 'escreva algo antes de enviar' });
      return;
    }
    try {
      await mx.request('terminal.sendText', { text, submit: true });
    } catch (e) {
      await mx.request('window.showBanner', { text: e.message, sticky: true });
    }
  } else if (action === 'zerar') {
    state.turns = 0;
    state.tools = {};
    state.lastStop = null;
  } else if (action.startsWith('ir:')) {
    await mx.request('session.focus', { tabId: action.slice(3) });
    return;
  }
  await refreshView();
});

async function blocks() {
  const sessions = await mx.request('sessions.list');
  const claude = sessions.filter((s) => s.kind === 'claude');
  const tools = Object.entries(state.tools).sort((a, b) => b[1] - a[1]).slice(0, 6);
  return [
    { type: 'heading', text: 'Sessões' },
    {
      type: 'list',
      empty: 'nenhuma sessão do claude aberta',
      items: claude.map((s) => ({
        title: s.title,
        subtitle: `${s.statusLabel}${s.branch ? ' · ' + s.branch : ''}`,
        icon: s.needsYou ? 'warning' : 'terminal',
        tone: s.needsYou ? 'yellow' : undefined,
        badge: s.focused ? 'em foco' : undefined,
        action: `ir:${s.id}`,
      })),
    },
    { type: 'divider' },
    { type: 'heading', text: 'Desde que o plugin subiu' },
    {
      type: 'kv',
      items: [
        { key: 'turnos terminados', value: String(state.turns) },
        { key: 'último', value: state.lastStop ? state.lastStop.at : '—' },
        ...tools.map(([name, n]) => ({ key: name, value: `${n}×` })),
      ],
    },
    state.lastStop && state.lastStop.message
      ? { type: 'text', style: 'dim', text: `“${state.lastStop.message}”` }
      : { type: 'text', style: 'faint', text: 'nenhum turno terminou ainda' },
    { type: 'divider' },
    { type: 'heading', text: 'Mandar pra sessão' },
    {
      type: 'input',
      id: 'mensagem',
      label: 'mensagem',
      placeholder: 'enter também envia',
      submit: 'enviar',
    },
    {
      type: 'checkbox',
      id: 'notificar',
      label: 'notificar quando uma sessão terminar o turno',
      value: state.notifyOnStop,
      action: 'preferencia',
    },
    {
      type: 'row',
      children: [
        { type: 'button', action: 'enviar', label: 'enviar pra sessão em foco', style: 'primary' },
        { type: 'button', action: 'zerar', label: 'zerar contagem' },
      ],
    },
  ];
}

async function openView() {
  await mx.request('view.open', { viewId: VIEW, title: 'painel do exemplo', blocks: await blocks() });
  state.viewOpen = true;
}

async function refreshView() {
  const { open } = await mx.request('view.update', { viewId: VIEW, blocks: await blocks() });
  // Fechada pelo x do painel: para de atualizar até o comando abrir de novo.
  state.viewOpen = open;
}

mx.start();
