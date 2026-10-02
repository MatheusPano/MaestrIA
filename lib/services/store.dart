import 'dart:async';
import 'dart:convert';
import 'dart:io';
// Só a `Color`, pro [AppStore.tintOf]: o `foundation` não a reexporta, e o
// `material` inteiro traria uma janela de widgets pra dentro da store.
import 'dart:ui' show Color;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../theme.dart';
import 'agents.dart';
// --- ditado (vocalização) — fora desta versão --------------------------------
// Ver o cabeçalho de `services/dictation.dart`.
// import 'dictation.dart';
import 'docs.dart';
import 'editor.dart';
import 'git.dart';
import 'history.dart';
import 'hooks.dart';
import 'layout.dart';
import 'links.dart';
import 'notify.dart';
import 'paths.dart';
import 'plugin_api.dart';
import 'plugin_floats.dart';
import 'plugins.dart';
import 'pty.dart';
import 'setup.dart';
import 'shell.dart';
import 'shortcuts.dart';
import 'workspace.dart';

/// O que um painel é.
///
/// [reader] é o de fora: não tem processo, não tem pty e não tem sessão -- é
/// um documento na árvore de painéis, do mesmo tamanho e com o mesmo cabeçalho
/// que os outros. Ver [MxDoc] e `ui/doc_pane.dart` pra como ele é desenhado.
///
/// [setup] é o segundo de fora: os arquivos que o Claude Code lê de uma
/// pasta, editáveis. Ver [MxSetup] e `ui/setup_pane.dart`.
///
/// [plugin] é o terceiro: uma janela que um plugin desenhou em blocos. Ver
/// [PluginView] e `ui/plugin_pane.dart`. Só em memória -- o plugin é quem sabe
/// o que ela mostra, e amanhã ele abre de novo se ainda quiser.
enum TabKind { shell, claude, reader, setup, plugin }

/// One panel. Owns its pty and its hook-derived state.
class MxTab {
  MxTab({
    required this.id,
    required this.folder,
    required this.kind,
    required this.cwd,
    required this.branch,
    this.customLabel,
    this.doc,
    this.setup,
    this.view,
    this.launcher,
  });

  final String id;

  /// Held by reference, not by path, so renaming a folder renames its panels.
  final Folder folder;
  final TabKind kind;
  final String cwd;
  String branch;
  String? customLabel;

  /// A cor deste painel, quando alguém escolheu uma. Ver [MxTint].
  ///
  /// Mora ao lado do [customLabel] porque é a outra metade da mesma coisa: as
  /// duas são o que *você* diz sobre este painel, e nenhuma das duas se
  /// deriva de pasta, branch ou estado. Null é o padrão e é a maioria -- um
  /// painel sem cor é o cartão de sempre.
  ///
  /// Vale quando o projeto deste painel não tem cor -- se tem, é a dele que
  /// manda. Ver [AppStore.chosenTintOf].
  MxTint? tint;

  final TermSession term = TermSession();
  final HookState hooks = HookState();

  /// O que este painel mostra, quando ele é um [TabKind.reader]. Null em todos
  /// os outros -- e não-null em todos os readers, que é o que [isReader]
  /// garante pra quem vai desreferenciar.
  final MxDoc? doc;

  /// Um painel de leitura: nada aqui tem processo, fila, git ou estado de
  /// sessão pra dizer. Meia dúzia de lugares perguntam isso antes de tratar
  /// este painel como uma sessão.
  bool get isReader => kind == TabKind.reader && doc != null;

  /// O que este painel mostra, quando ele é um [TabKind.setup]: a pasta cujos
  /// arquivos de configuração do Claude estão no editor. Null em todos os
  /// outros -- e não-null em todos os de configuração, que é o que [isSetup]
  /// garante pra quem vai desreferenciar.
  final MxSetup? setup;

  /// Um painel de configuração. Ver [isReader]: a mesma pergunta, pelo mesmo
  /// motivo.
  bool get isSetup => kind == TabKind.setup && setup != null;

  /// O que este painel mostra, quando ele é um [TabKind.plugin]. Mesma regra
  /// de [doc] e [setup]: não-null exatamente nos painéis de plugin.
  final PluginView? view;

  bool get isPluginView => kind == TabKind.plugin && view != null;

  /// O plugin dono deste terminal, quando um plugin o abriu pra ele
  /// (`session.openShell` com `owned`): a conexão do ssh. Um terminal com dono
  /// mora na aba do plugin, e não nos avulsos -- é lá que o plugin o desenha,
  /// verde enquanto conecta, e é por lá que se volta a ele.
  ///
  /// Não é lembrado: uma conexão não se retoma, e um terminal que voltasse
  /// amanhã seria um prompt local com o nome do servidor.
  String? owner;

  /// O que o dono disse que este terminal é (o id do host), pra ele se achar
  /// de novo depois de reiniciar sem ter que adivinhar pelo título.
  String? ownerTag;

  /// Um terminal que mora dentro de uma janela do dono (`session.openShell`
  /// com `embedded`, desenhado por um bloco `terminal`), e não num painel: a
  /// aba Terminal de um container, como no OrbStack. Nunca vai pra grade --
  /// pôr na tela é pôr a janela do plugin na tela.
  bool embedded = false;

  /// Um painel que não é uma sessão de terminal: não tem pty, não tem saída
  /// pra ler e não tem o que matar no encerramento.
  ///
  /// Nasceu quando a configuração virou o segundo destes. Os lugares que
  /// perguntavam `isReader` quase todos queriam perguntar isto -- um editor de
  /// configuração tem tão pouco a ver com git, fila e status quanto uma folha
  /// de markdown.
  bool get isPassive => isReader || isSetup || isPluginView;

  /// O programa que este painel subiu, quando ele saiu de um. Ver [Launcher].
  ///
  /// Por referência, como a [folder]: renomear o programa renomeia os painéis
  /// dele, e trocar o comando vale no próximo "rodar de novo". Vira null
  /// quando o programa é apagado -- o painel continua o terminal que sempre
  /// foi, com o que estiver rodando dentro dele, em vez de sumir junto com a
  /// linha que o abriu.
  Launcher? launcher;

  /// The project inside the folder this panel is part of, if any. Null is a
  /// panel that is just a panel in a folder -- the shape everything had before
  /// projects existed, and still the right one for a one-off session.
  String? featureOrHotfixId;

  /// De qual painel este nasceu, quando ele nasceu de um passo de fluxo.
  ///
  /// Um fluxo produz painéis -- a sessão de revisão, o terminal do comando --
  /// e eles chegavam na lateral como linhas soltas, sem nada dizendo que eram
  /// a mesma coisa acontecendo. Isto é o fio que a lateral segue pra pendurar
  /// a ninhada em quem a abriu.
  ///
  /// Só em memória, como a própria fila (ver [followUps]): o id de um painel
  /// é desta execução, e um painel restaurado amanhã não é o mesmo painel.
  String? bornOf;

  /// A fila deste painel está esperando a hora de sair?
  ///
  /// Ligada quando o turno acaba com passo na fila, desligada quando o passo
  /// sai -- e quando o painel fecha, ou a sessão é marcada como concluída.
  /// Entre uma coisa e outra quem decide a hora é [AppStore.holdFor]: um
  /// turno que acaba não é, sozinho, trabalho que acabou.
  bool armed = false;

  /// What happens the next time this session goes quiet, in order.
  ///
  /// Deliberately not saved with the layout. A queue is armed for a session
  /// that is running *now*; a restored panel comes back with `--resume` and is
  /// idle from its first breath, so a persisted queue would fire the whole
  /// thing into a session that had not been asked anything.
  final List<FollowUp> followUps = [];

  /// Filled in from `claude agents --json` once the session registers itself.
  String? sessionId;

  /// O `--name` com que esta sessão subiu: como o `claude agents` a lista e o
  /// único endereço que outro agente tem pra ela -- `ListAgents` e
  /// `SendMessage` falam nomes, nunca ids de sessão. Anotado no launch e
  /// atualizado pelo que o CLI responde, que é a resposta que vale.
  ///
  /// Não é o [title] e de propósito não anda junto com ele: renomear o painel
  /// renomeia o painel, enquanto o processo lá fora continua atendendo pelo
  /// nome com que foi iniciado.
  String? agentName;
  int dirty = 0;
  final DateTime startedAt = DateTime.now();

  /// O ⌘+ deste painel: passos de um ponto sobre o corpo base ([MxType.size]).
  ///
  /// Do painel e não da janela de propósito — numa grade de quatro, um deles é
  /// o que você está lendo de perto e os outros três são de canto de olho. E
  /// em passos, não em tamanho, pra que trocar a base nas configurações leve
  /// todos junto sem apagar a diferença que cada um pediu.
  int zoom = 0;

  /// O corpo com que o pty deste painel é desenhado. Um leitor não passa por
  /// aqui: ele soma os mesmos passos à escala do markdown, que é outra.
  double get fontSize => Mx.type.sizeAt(zoom);

  /// O grupo de que este painel faz parte, se faz de algum. Ver [PaneGroup].
  ///
  /// Um só, e o último em que ele entrou: dois grupos podem conter a mesma
  /// sessão, e a linha da lateral tem uma cor e um clique -- não dois. Quem
  /// grava e limpa isto é [AppStore._stamp], sempre a partir do grupo inteiro.
  String? groupId;

  /// Marked by hand: this session did its job.
  ///
  /// The one piece of a panel's state that nothing derives, because nothing
  /// can. A session that stops is [ClaudeStatus.idle], which says the turn
  /// ended -- not that the answer was any good. Only the person who read it
  /// knows that, so this is a judgement the app is told, never one it infers.
  ///
  /// It is not "closed" either: a panel marked done keeps its scrollback and
  /// its session id, so the answer is still on screen and the conversation is
  /// still resumable. What it stops being is *pending*.
  bool done = false;

  /// Preso no lugar: escolher outra sessão na lateral não troca este painel.
  ///
  /// É o "tela dividida com um fixo e outro que vai mudando". Sem isso o
  /// clique troca o painel em foco (ver [AppStore._place]), e o foco é
  /// justamente o que você mexe o tempo todo -- bastava ler o painel de
  /// referência uma vez pra que o próximo clique o levasse embora.
  ///
  /// Só vale enquanto o painel está na tela: é uma propriedade do lugar que
  /// ele ocupa, e uma sessão que saiu dele deixa de estar presa. Quem
  /// pergunta é [AppStore.isPinned], não este campo.
  bool pinned = false;

  /// Sem processo de propósito: a conversa fica, a memória volta.
  ///
  /// Uma sessão do claude parada no prompt custa uns 200MB de RAM pra não
  /// fazer nada -- e treze delas na lateral, das quais duas na tela, são o
  /// motivo de a máquina ficar sem memória. Hibernar é desligar o processo e
  /// ficar com o que importa: o id da conversa (ver [resumable]), o
  /// scrollback e a linha na lateral. Retomar é um clique, e o `--resume`
  /// devolve a conversa de onde parou.
  ///
  /// Distinto de [exited] sozinho, que também é o `q` apertado sem querer e o
  /// processo que morreu: aqui foi o app que desligou, e a linha tem que dizer
  /// isso -- e o clique nela tem que religar, em vez de mostrar uma moldura
  /// com "processo saiu (0)". Ver [AppStore.hibernate] e [AppStore.wake].
  bool hibernated = false;

  /// Quando esta sessão parou de trabalhar: o instante da virada pra repouso,
  /// não o do último evento.
  ///
  /// A diferença importa. [HookState.lastEventAt] anda a cada sinal, inclusive
  /// o de um fork que reporta depois do turno ter acabado -- e uma sessão que
  /// rejuvenesce sozinha não responde "terminou quando".
  ///
  /// Null enquanto ela trabalha, e null de novo no próximo prompt: a idade é
  /// deste repouso, não da última vez que ela esteve parada. Fora do [toJson]
  /// pelo mesmo motivo da fila -- um painel restaurado retoma a conversa de
  /// ontem, mas não é uma sessão que acabou de parar.
  DateTime? restedAt;

  /// Parou sem você ver.
  ///
  /// A pergunta que faltava. Cinco painéis parados dizem todos "pronto", e
  /// entre "esse eu já li" e "esse terminou enquanto eu estava em outra
  /// janela" o app não tinha nada -- nem a idade resolve, porque meia hora
  /// fora envelhece os cinco junto.
  ///
  /// Ligado na virada pra repouso quando você não estava olhando pra ele (ver
  /// [AppStore.watching]), desligado quando você olha. Como o tique de
  /// [done], é sobre o que *você* já viu -- só que este o app consegue
  /// observar sozinho.
  bool unseen = false;

  /// Parada, com uma parada carimbada. Ver [restedAt].
  bool get rested => restedAt != null && !exited && status.atRest;

  /// A idade deste repouso, pra quem desenha a linha. Ver [shortAgo].
  String? get restedAgo => rested ? shortAgo(restedAt!) : null;

  /// The panel title, in the order of what a human would actually recognise:
  /// what you named it, then the branch's task id, then the folder.
  String get folderRoot => folder.root;

  String get title {
    if (customLabel != null && customLabel!.isNotEmpty) return customLabel!;
    // Um documento se chama pelo que ele é: o nome do arquivo, "plano de
    // TASK#47730", "relatório do dia". A pasta e a branch não dizem nada sobre
    // ele que o título já não diga melhor.
    if (doc case final open?) return open.title;
    // E a configuração pela pasta que ela configura: é a única coisa que
    // distingue duas abertas lado a lado.
    if (setup case final open?) return 'claude · ${open.name}';
    if (view case final v?) return v.title;
    // E um painel de programa se chama pelo programa: "btop", e não pelo repo
    // em que ele por acaso subiu. Mesmo raciocínio do documento acima -- a
    // pasta e a branch não dizem nada dele que o nome não diga melhor.
    if (launcher case final l?) return l.name;
    // A loose panel has no folder to be named after. What it does have is the
    // folder it was pointed at -- and `~` when that is only home.
    if (folder.isLoose) return cwd == folder.root ? '~' : cwd.split('/').last;
    // In the main checkout the branch is almost always the trunk, and four
    // panels called "master" name nothing. There, the folder is the name.
    if (cwd == folder.root) return folder.name;
    if (branch.isNotEmpty && branch != '(detached)') {
      final m = RegExp(r'([A-Za-z]+[#-]?\d+)').firstMatch(branch);
      if (m != null) return m.group(1)!;
      return branch.split('/').last;
    }
    return cwd.split('/').last;
  }

  String get subtitle {
    if (doc case final open?) {
      final when =
          '${open.at.hour.toString().padLeft(2, '0')}:'
          '${open.at.minute.toString().padLeft(2, '0')}';
      if (open.missing) return '${open.source.label} · o arquivo não está mais lá';
      // A origem e a hora, que são as duas perguntas que um documento aberto
      // levanta: de onde ele saiu, e se é o de agora ou o de duas horas atrás.
      // A origem sai quando o título já a carrega -- "plano de TASK#47730" com
      // "de TASK#47730" embaixo é o cabeçalho dizendo a mesma coisa duas vezes.
      final from = open.origin;
      final says = from != null && from.isNotEmpty && !title.contains(from);
      return [open.source.label, if (says) 'de $from', when].join(' · ');
    }
    // O arquivo aberto no editor, que é o que o título não diz.
    if (setup case final open?) return open.selected ?? 'configuração do claude';
    if (view case final v?) return 'plugin · ${v.pluginName}';
    // Antes do "processo saiu": saiu porque o app mandou, e o que a linha tem
    // a dizer é o que fazer a respeito.
    if (hibernated) return 'hibernada · clique pra retomar';
    if (exited) return 'processo saiu (${term.exitCode ?? '?'})';
    // O comando, que é a única coisa que o cabeçalho ainda não disse: o nome
    // do programa já é o título, e "programa" embaixo dele não informaria
    // nada. `npm run dev` embaixo de "dev" informa.
    if (launcher case final l?) return l.command;
    if (kind == TabKind.shell) return 'shell';
    return hooks.subtitle;
  }

  bool get exited => term.exited;

  /// O id que um `--resume` desta sessão levaria: o que o painel anotou, ou o
  /// que os hooks contaram.
  String? get resumeId => sessionId ?? hooks.sessionId;

  /// A conversa dá pra retomar, com ou sem processo vivo.
  ///
  /// A distinção que faltava: sair do processo não é perder a sessão. É o que
  /// mandar a sessão pro background faz -- o claude solta o terminal e segue
  /// rodando fora dele --, e é o que um `/exit` faz também; nos dois casos o
  /// que ficou pra trás é uma conversa endereçada por um id, que é justamente
  /// o que o painel volta a abrir. Ver [AppStore._writeConfig], que é quem
  /// tratava esse painel como um painel morto.
  bool get resumable => kind == TabKind.claude && resumeId != null;

  /// Um leitor nunca está fazendo nada: ele é uma folha de papel. Fica em
  /// [ClaudeStatus.unknown], que é o estado que não acende badge, não conta
  /// como pendência e não notifica.
  ClaudeStatus get status => switch (kind) {
    TabKind.reader || TabKind.setup || TabKind.plugin => ClaudeStatus.unknown,
    TabKind.shell => exited ? ClaudeStatus.ended : ClaudeStatus.unknown,
    TabKind.claude => hooks.status,
  };

  /// A receita do painel: o que basta pra abrir *um igual* a este.
  ///
  /// A metade do [toJson] que descreve o painel em vez do que passou dentro
  /// dele -- e é por isso que ela tem nome próprio: um grupo salvo (ver
  /// [PaneGroup]) guarda arranjo, não história. Quem remonta um painel destes,
  /// dos dois lados, é [AppStore._openPane].
  Map<String, dynamic> get recipe => {
    'folderRoot': folder.root,
    if (folder.isLoose) 'loose': true,
    if (featureOrHotfixId != null) 'featureOrHotfixId': featureOrHotfixId,
    'kind': kind.name,
    'cwd': cwd,
    // Só o id: o nome e o comando são do programa, não do painel, e uma cópia
    // deles aqui voltaria amanhã com o comando de ontem depois de você editar
    // o programa. Um id que não existe mais volta como terminal -- ver
    // [AppStore._openPane].
    if (launcher case final l?) 'launcher': l.id,
    if (customLabel != null) 'label': customLabel,
    // Junto do nome, e na receita e não só no layout: um grupo salvo guarda
    // arranjo, e a cor de um painel é do painel -- reabri-lo pelo grupo tem
    // que devolver o cartão que você pintou.
    if (tint != null) 'tint': tint!.name,
    // The session id is the whole point: a restored panel resumes the
    // conversation instead of starting a stranger in the same folder.
    if (resumable) 'sessionId': resumeId,
    if (doc case final open?) 'doc': open.toJson(),
    if (setup case final open?) 'setup': open.toJson(),
    // Uma sessão que você deixou grande é uma sessão que você quer grande
    // amanhã também — e é uma tecla, não uma preferência, então não tem outro
    // lugar onde ser lembrada.
    if (zoom != 0) 'zoom': zoom,
  };

  /// What it takes to bring this panel back next time the app opens.
  Map<String, dynamic> toJson() => {
    ...recipe,
    // Fora da receita de propósito: a receita é o que um grupo guarda, e um
    // grupo guardando a que grupo o painel pertence seria ele apontando pra
    // si mesmo. Aqui, no layout, é o que faz a cor da linha e o clique dela
    // sobreviverem ao fechamento da janela.
    if (groupId != null) 'group': groupId,
    // Unlike the queue, which is armed for a session running *now*, what the
    // work produced outlives the session that produced it: the six files are
    // still the six files tomorrow morning.
    if (hooks.touched.isNotEmpty) 'touched': hooks.touched,
    // Pelo mesmo motivo dos arquivos, e com mais razão: o plano é o documento
    // que sobreviveu ao turno, e o hook que o trouxe não acontece de novo. Um
    // restart que o esquecesse apagaria a única cópia que existe dele.
    if (hooks.plans.isNotEmpty) 'plans': hooks.plans.map((n) => n.toJson()).toList(),
    // Worth the trip through the config: it is the one thing about a panel
    // that only you knew, and a restart that forgot it would be asking you
    // to read four sessions again to find out which three were settled.
    if (done) 'done': true,
    // No layout e não na receita: um grupo guarda arranjo, e abrir um grupo
    // é querer os painéis dele rodando. Já a janela que fecha com uma sessão
    // hibernada reabre com ela hibernada -- religar treze processos no launch
    // pra deixá-los parados era justamente o que a hibernação veio evitar.
    if (hibernated) 'hibernated': true,
    // No layout e não na receita, como o grupo: preso é um jeito de estar
    // nesta tela, e a tela é o que o layout guarda.
    if (pinned) 'pinned': true,
  };
}

/// Em que prateleira do menu de filtros uma opção fica.
///
/// Existe porque as duas se combinam de formas diferentes: dentro de um grupo
/// as opções somam ("claude *ou* shell"), entre grupos elas cortam ("claude
/// *e* esperando você"). Sem isso, marcar duas coisas de grupos diferentes
/// devolvia lista vazia e parecia bug.
enum MxFilterGroup {
  kind('tipo'),
  state('estado');

  const MxFilterGroup(this.label);
  final String label;
}

/// Uma opção do menu de filtros da lateral, fora do escopo (pastas e
/// projetos, que são a lista do próprio usuário) e do texto digitado.
enum MxFilter {
  claude('sessões do claude', MxFilterGroup.kind),
  shell('terminais', MxFilterGroup.kind),
  waiting('esperando você', MxFilterGroup.state),
  working('rodando', MxFilterGroup.state),
  parked('paradas', MxFilterGroup.state),
  finished('concluídas', MxFilterGroup.state);

  const MxFilter(this.label, this.group);
  final String label;
  final MxFilterGroup group;

  bool matches(MxTab t) => switch (this) {
    MxFilter.claude => t.kind == TabKind.claude,
    MxFilter.shell => t.kind == TabKind.shell,
    // Concluída sai de "esperando você" e de "paradas" de propósito: o tique é
    // você dizendo que essa já foi, e uma sessão guardada não é uma pendência.
    MxFilter.waiting => !t.done && t.status.needsHuman,
    MxFilter.working => t.status == ClaudeStatus.working || t.status == ClaudeStatus.tool,
    MxFilter.parked =>
      !t.done &&
          (t.status == ClaudeStatus.idle ||
              t.status == ClaudeStatus.ready ||
              t.status == ClaudeStatus.ended ||
              t.exited),
    MxFilter.finished => t.done,
  };
}

/// O id da feature/hotfix de uma receita de painel salva.
///
/// A receita gravada antes do rename chama o campo de `projectId`, e é isso
/// que os grupos de painéis salvos guardam até alguém salvá-los de novo. Ver
/// [MxTab.recipe].
@visibleForTesting
String? featureOrHotfixIdIn(Map<String, dynamic> pane) =>
    (pane['featureOrHotfixId'] ?? pane['projectId']) as String?;

/// Uma linha da lateral no lugar em que ela está desenhada.
///
/// A mesma pasta aparece uma vez em cada workspace dela, e um arrasto precisa
/// saber de qual das aparições ela saiu: é o [within] -- null na raiz.
typedef RowPlace = ({SidebarRow row, Workspace? within});

class AppStore extends ChangeNotifier {
  // --- ditado (vocalização) — fora desta versão ------------------------------
  // Sem o ditado o construtor não tem mais o que ligar.
  // /// [dictation] entra pela porta porque é a única peça daqui que um teste não
  // /// tem como exercitar: não há microfone numa suíte, e não há whisper.cpp na
  // /// máquina que roda a CI. Todo o resto do ditado -- o que é colado, em que
  // /// painel, e o que acontece quando não se ouviu nada -- é lógica deste
  // /// store, e é o que o teste alcança trocando só as duas pontas de IO.
  // AppStore({Dictation? dictation}) : dictation = dictation ?? Dictation() {
  // // No construtor e não no [init]: quem desenha painel escuta o store, não o
  // // ditado, então sem esta ponte o cabeçalho nunca fica sabendo que o
  // // microfone abriu. O [init] sobe servidor, timer e git -- coisas que um
  // // teste não quer --, e uma ligação em memória não tem por que morar lá.
  // this.dictation.addListener(notifyListeners);
  // }
  AppStore();

  final HookServer hooks = HookServer();
  final AgentsWatcher agents = AgentsWatcher();
  final Notifier notifier = Notifier();

  /// Os plugins instalados. Ver `services/plugins.dart`.
  final Plugins plugins = Plugins();

  /// Quem mostra o seletor rápido de um plugin (`window.pick`). A store não
  /// tem tela; quem liga isto é o `main.dart`, que tem um contexto debaixo
  /// do navegador. Null nos testes, e aí o pedido volta com erro.
  Future<String?> Function({
    required String title,
    String? placeholder,
    required List<({String value, String label, String? detail})> items,
  })?
  quickPick;

  final List<Folder> folders = [];

  /// Os workspaces da lateral. Ver [Workspace] -- cada um é dono da lista
  /// das pastas dele, e é a lateral que aninha (o mesmo arranjo de
  /// [featuresOrHotfixes] dentro de [folders]).
  ///
  /// Um workspace pode ficar vazio: o criado na mão não some porque o último
  /// repo saiu dele. Quem o tira da lateral é [dissolveWorkspace] ou
  /// [closeWorkspace].
  final List<Workspace> workspaces = [];

  /// A ordem da raiz da lateral: `workspace:<id>` e `folder:<root>`.
  ///
  /// Até a 2.4.0 a ordem saía da lista de pastas, com a seção no lugar da
  /// primeira pasta dela. Com a mesma pasta em dois workspaces, essa conta
  /// deixa de ter resposta. Vazio é o config de antes disto, e aí
  /// [sidebarRows] faz a conta antiga. Ver [rowKey].
  final List<String> rootOrder = [];

  /// The named jobs inside those folders. Flat, keyed back to a folder by
  /// [FeatureOrHotfix.folderRoot] -- the sidebar is what nests them.
  final List<FeatureOrHotfix> featuresOrHotfixes = [];

  /// Where panels that belong to no repo live. Not in [folders]: it is never
  /// saved, never git-refreshed, and never removable -- it is a place to put
  /// things, not a thing the user added.
  final Folder loose = Folder.loose(Platform.environment['HOME'] ?? '/');

  final List<MxTab> tabs = [];

  /// Os arranjos que você salvou. Ver [PaneGroup] -- e [saveGroup], que é o
  /// gesto que põe um aqui.
  ///
  /// Fora das pastas de propósito, como a lista de painéis: um grupo pode
  /// juntar painéis de repos diferentes, então pendurá-lo numa pasta seria
  /// escolher uma das duas por ele.
  final List<PaneGroup> groups = [];

  /// Os programas que você ensinou ao maestria. Ver [Launcher] -- e
  /// [openLauncher], que é o que uma linha do menu do + faz.
  ///
  /// Fora das pastas como os grupos, e pelo mesmo motivo: `btop` não é do repo
  /// em que você o abriu primeiro. Um programa é uma forma de abrir painel, e
  /// vale em qualquer pasta da lateral.
  final List<Launcher> launchers = [];

  final Map<String, List<WorktreeInfo>> worktrees = {};

  /// A árvore de painéis, ou null com a tela limpa. As regras de corte,
  /// colapso e proporção estão em `layout.dart`; o que fica aqui é o foco e os
  /// gestos que a lateral e os painéis disparam.
  PaneNode? panes;

  /// Qual painel o teclado está escutando, pelo id da sessão que ele mostra.
  String? focusedPaneId;

  /// A janela está na frente?
  ///
  /// Quem conta é o `AppLifecycleListener` do `main.dart`; começa em true
  /// porque um app que acabou de abrir está na frente, e porque um teste que
  /// não tem janela nenhuma não deve ver o mundo inteiro como não visto.
  ///
  /// Existe por uma razão só: "parou sem você ver" precisa saber se você
  /// estava aqui. Ver [MxTab.unseen] e [watching].
  bool windowActive = true;

  /// Desde quando você está em outra janela. Null enquanto está nesta.
  DateTime? _awaySince;

  String? banner;

  /// O sino: o que os painéis fizeram enquanto você olhava pra outro lugar,
  /// mais novo primeiro. Ver [MxNotice].
  ///
  /// Só em memória, como [MxTab.restedAt]: um painel restaurado retoma a
  /// conversa de ontem, mas a pergunta de ontem já não está esperando ninguém.
  final List<MxNotice> notices = [];

  /// Até onde o sino lembra. Cinquenta é mais do que um dia de trabalho
  /// produz de coisa que ainda interessa, e o que passar disso é arqueologia.
  static const noticeCap = 50;

  /// A lista do sino está aberta.
  bool noticesOpen = false;

  /// A lista das sessões, aberta pelo resumo da barra de status. Irmã da
  /// lista do sino: as duas moram na barra, e abrir uma fecha a outra.
  bool sessionsOpen = false;

  int get unreadNotices => notices.where((n) => !n.read).length;

  /// Os avisos que estão na tela agora, em cartões no canto -- o mais novo
  /// embaixo, perto do sino de onde ele veio. Ver [toastLife].
  ///
  /// Um subconjunto de [notices], não uma lista à parte: dispensar o cartão
  /// tira ele da tela, e a linha continua no sino.
  final List<MxNotice> toasts = [];

  /// Quantos cartões cabem de uma vez. Cinco painéis terminando juntos são
  /// três cartões e o número do sino dizendo o resto.
  static const toastCap = 3;

  /// Não perturbe: os avisos entram no sino, mas não sobem na tela.
  ///
  /// Lembrado, como a lateral escondida: é um jeito de trabalhar, não um
  /// humor de cinco minutos.
  bool doNotDisturb = false;

  final Map<MxNotice, Timer> _toastTimers = {};

  /// How wide the sidebar is, in logical pixels. Dragged by the gutter between
  /// it and the panes, and remembered — a width you set once is a width you
  /// set once.
  static const double minSidebar = 248;
  static const double maxSidebar = 680;
  static const double defaultSidebar = 352;
  double sidebarWidth = defaultSidebar;

  /// Se a lateral está fora da tela.
  ///
  /// Escondida, e não encolhida: [minSidebar] existe porque uma lista de 100px
  /// é uma lista ilegível, então "agora quero a janela inteira pros painéis"
  /// não é uma frase que o vão saiba dizer. É lembrada pelo mesmo motivo que
  /// [sidebarWidth], e é por isso que são dois campos: a largura que ela volta
  /// a ter é a que você tinha deixado.
  bool sidebarHidden = false;

  /// A barra de status no topo da janela, e não no pé. O sino, a lista dele
  /// e os cartões vão junto: eles moram perto do sino de onde vieram.
  ///
  /// Lembrada como a lateral escondida -- é um jeito de montar a janela.
  bool statusBarTop = false;

  /// A ordem dos ícones de plugin na faixa, pelos ids, como você arrastou.
  /// Quem não está aqui (um plugin novo) vem depois, na ordem dos plugins.
  /// Ver [railPlugins] e [moveRailPlugin].
  List<String> railOrder = [];

  /// O que a lateral está mostrando: null pras sessões, ou o id do plugin cuja
  /// aba foi escolhida na faixa (ver [railPlugins]). É o que o VS Code chama de
  /// "view container": cada ícone da faixa troca a lateral inteira, em vez de
  /// cada plugin empilhar a própria seção embaixo das pastas.
  ///
  /// Lembrado como a largura, e pelo mesmo motivo. Um plugin que sumiu não
  /// deixa a lateral vazia -- ver [shownPlugin].
  String? sidebarView;

  /// The chosen palette. Lives here because it is remembered like everything
  /// else the window keeps; [Mx.current] is what the widgets actually read.
  MxPalette get theme => Mx.palette;

  /// As teclas e o que elas fazem. Guardado aqui pelo mesmo motivo do tema:
  /// é uma escolha que a janela lembra. Quem lê é `ui/keys.dart`.
  final MxKeymap keymap = MxKeymap();

  // --- ditado (vocalização) — fora desta versão ------------------------------
  // /// O microfone. Aqui e não no painel porque só há um microfone na máquina:
  // /// dois painéis gravando ao mesmo tempo é um estado que não existe, e é este
  // /// campo único que o torna impossível de representar. Ver [toggleDictation].
  // final Dictation dictation;

  int _seq = 0;
  bool _restoring = false;

  /// A janela já foi embora?
  ///
  /// Um passo de fluxo tem espera dentro dele -- colar um texto no prompt de
  /// outra sessão leva um quarto de segundo, ver [TermSession.submit] -- e o
  /// app pode fechar nesse intervalo. Voltar da espera pra avisar uma tela que
  /// não existe mais é um erro de verdade (`A AppStore was used after being
  /// disposed`), e ele não é do passo: é de continuar falando depois do fim.
  bool _gone = false;
  Timer? _saveDebounce;

  /// Alerts already fired, keyed per session, so a state that stays put does
  /// not notify every two seconds.
  final Set<String> _alerted = {};

  MxTab? _byId(String? id) => id == null ? null : tabs.firstWhereOrNull((t) => t.id == id);

  /// A sessão de um id. A árvore de painéis guarda ids, então quem a desenha
  /// precisa desta volta.
  MxTab? tabById(String? id) => _byId(id);

  /// As sessões na tela, na ordem em que aparecem nela.
  List<MxTab> get openPanes => [
    for (final id in Panes.order(panes))
      if (_byId(id) case final tab?) tab,
  ];

  int get paneCount => Panes.count(panes);

  bool isOpen(MxTab tab) => Panes.has(panes, tab.id);

  /// Preso e na tela -- ver [MxTab.pinned].
  bool isPinned(MxTab tab) => tab.pinned && isOpen(tab);

  /// Prende ou solta o painel de [tab]. Fora da tela não há lugar pra prender.
  void togglePin(MxTab tab) {
    if (!isOpen(tab)) return;
    tab.pinned = !tab.pinned;
    _save();
    notifyListeners();
  }

  /// Cai no primeiro painel quando o foco aponta pra uma sessão que já saiu da
  /// tela: sempre há um painel em foco enquanto houver painel.
  MxTab? get focusedTab => _byId(focusedPaneId) ?? _byId(Panes.order(panes).firstOrNull);

  Future<void> init() async {
    await hooks.start();
    hooks.events.listen(applyHook);
    agents.updates.listen(applyAgents);
    plugins.onCall = PluginApi(this).handle;
    // Ligar, desligar ou ver um plugin cair muda o que os menus oferecem e o
    // que o teclado faz. O log não passa por aqui -- ver [Plugins.logs].
    plugins.addListener(notifyListeners);
    await _loadConfig();
    // Um config que não existe ainda não leu a pasta de plugins no caminho.
    if (!plugins.scanned) plugins.scan();
    plugins.onReady = (p) {
      if (p.id == _sidebarLive) plugins.tell(p, 'sidebar.shown');
    };
    plugins.startup();
    // A aba de plugin que ficou na tela da última vez precisa do processo de
    // pé pra ter o que mostrar.
    _syncSidebar(announce: true);
    agents.start();
    Timer.periodic(const Duration(seconds: 1), (_) {
      // O relógio da fila: um passo só sai quando a sessão está parada há um
      // tempo, e "há um tempo" é uma condição que ninguém avisa -- ela chega
      // pela ausência de eventos, então alguém tem que ir olhar.
      pumpFlows();
      // O que está parado fora da tela há tempo demais solta o processo. Ver
      // [hibernateIdle].
      hibernateIdle();
      // Um segundo parado em cima de um painel conta como tê-lo lido. Avisa
      // por conta própria quando de fato apaga uma marca.
      seeFocused();
      // Only the elapsed-seconds readouts need this cadence.
      if (tabs.any((t) => t.status == ClaudeStatus.tool || t.armed)) notifyListeners();
    });
    Timer.periodic(const Duration(seconds: 10), (_) => refreshGit());
    // A idade de um repouso envelhece sozinha: ninguém manda evento avisando
    // que "agora" virou "1min". Num relógio próprio e lento de propósito --
    // pendurar isso no de um segundo redesenharia a janela inteira a cada
    // segundo pra mexer num número que anda de minuto em minuto.
    Timer.periodic(const Duration(seconds: 20), (_) {
      if (tabs.any((t) => t.rested)) notifyListeners();
    });
    notifyListeners();
  }

  // --- persistence --------------------------------------------------------

  /// A pasta onde a janela guarda o que ela lembra. Ver [mxStateHome] -- mora
  /// em `services/paths.dart` porque o [HookServer] anota a porta dele ali
  /// também, e ele sobe antes de existir store pra perguntar.
  static String get stateHome => mxStateHome;

  File get _configFile => File('$mxStateDir/config.json');

  @visibleForTesting
  String get configPath => _configFile.path;

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
    final rawFolders = ((legacy ? j['projects'] : j['folders']) as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    for (final p in rawFolders) {
      folders.add(Folder.fromJson(p));
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
  }

  Future<void> _loadConfig() async {
    try {
      if (!_configFile.existsSync()) return;
      final j = jsonDecode(await _configFile.readAsString()) as Map<String, dynamic>;
      readSidebar(j);
      for (final g in (j['groups'] as List? ?? const [])) {
        if (PaneGroup.fromJson(g) case final group?) groups.add(group);
      }
      // Antes do layout de propósito: os painéis salvos apontam pra cá pelo
      // id, e um painel de `btop` restaurado antes da lista existir voltaria
      // como um terminal qualquer.
      for (final l in (j['launchers'] as List? ?? const [])) {
        if (Launcher.fromJson(l) case final launcher?) launchers.add(launcher);
      }
      final w = (j['sidebarWidth'] as num?)?.toDouble();
      if (w != null) sidebarWidth = w.clamp(minSidebar, maxSidebar);
      sidebarHidden = j['sidebarHidden'] as bool? ?? false;
      statusBarTop = j['statusBarTop'] as bool? ?? false;
      railOrder = [
        for (final id in j['railOrder'] as List? ?? const [])
          if (id is String) id,
      ];
      sidebarView = j['sidebarView'] as String?;
      doNotDisturb = j['doNotDisturb'] as bool? ?? false;
      floats.readJson(j['floats']);
      groupsCollapsed = j['groupsCollapsed'] as bool? ?? false;
      hibernateMinutes = (j['hibernateMinutes'] as num?)?.toInt() ?? defaultHibernateMinutes;
      // Antes do tema: um tema de plugin só existe depois que o plugin é
      // lido, e o id salvo cairia no padrão.
      plugins.load(j['plugins']);
      plugins.scan();
      Mx.applyId(j['theme'] as String?);
      Mx.applyType(MxType.fromJson(j['type']));
      keymap.load(j['shortcuts']);
      // --- ditado (vocalização) — fora desta versão --------------------------
      // dictation.config = DictationConfig.fromJson(j['dictation']);
      await refreshGit();
      await _restoreLayout(j['layout'] as Map<String, dynamic>?);
    } catch (_) {}
  }

  /// Bring back the panels from last time, processes and all.
  ///
  /// A layout that reopens empty is not a layout. Claude panels come back with
  /// `--resume`, so the panel you left mid-task is the panel you get.
  Future<void> _restoreLayout(Map<String, dynamic>? layout) async {
    if (layout == null) return;
    final saved = (layout['panes'] as List? ?? const []).whereType<Map<String, dynamic>>();
    if (saved.isEmpty) return;

    _restoring = true;
    // Uma posição por painel salvo, com null onde não deu pra voltar: as
    // folhas da árvore são índices desta lista, então uma lista que só junta
    // os que vingaram deslocaria todas as folhas depois do painel que faltou.
    final restored = <MxTab?>[];
    for (final pane in saved) {
      final tab = _openPane(pane);
      restored.add(tab);
      if (tab == null) continue;
      tab.hooks.touched.addAll((pane['touched'] as List? ?? const []).whereType<String>());
      tab.hooks.plans.addAll(
        (pane['plans'] as List? ?? const []).map(PlanNote.fromJson).whereType<PlanNote>(),
      );
      tab.done = pane['done'] == true;
      tab.pinned = pane['pinned'] == true;
      // Só se o grupo ainda existir: um grupo esquecido no meio do caminho
      // deixaria as linhas coloridas de um conjunto que não abre mais.
      final group = pane['group'] as String?;
      if (groups.any((g) => g.id == group)) tab.groupId = group;
    }
    _restoring = false;

    final count = restored.nonNulls.length;
    if (count == 0) return;
    // -1 é o que o `indexWhere` grava quando a última coisa que você fez foi
    // tirar tudo do painel: volta com as sessões vivas na lateral e a tela
    // limpa, que é como você deixou.
    MxTab? at(int? i) => i != null && i >= 0 && i < restored.length ? restored[i] : null;
    if (layout['tree'] case final tree?) {
      panes = Panes.fromJson(tree, (i) => at(i)?.id);
    } else if (at((layout['active'] as int?) ?? 0) case final left?) {
      // Um config escrito antes da grade existir: dois slots, esquerda e
      // direita. Vira a fileira de dois que ele sempre foi.
      final right = at(layout['split'] as int?);
      panes = right == null
          ? PaneLeaf(left.id)
          : PaneSplit(PaneAxis.row, [PaneLeaf(left.id), PaneLeaf(right.id)], [0.5, 0.5]);
    }
    focusedPaneId = at(layout['focused'] as int?)?.id ?? Panes.order(panes).firstOrNull;
    // Nenhum recado aqui. "13 painéis restaurados da última sessão" contava o
    // que já estava desenhado na lateral, e ficava na tela até alguém clicar
    // no x — a faixa que mais se via era a que menos dizia.
    notifyListeners();
  }

  /// Abre o painel que [pane] descreve -- a receita de [MxTab.recipe].
  ///
  /// Um lugar só pra isso porque duas coisas remontam painéis a partir do
  /// mesmo json: o layout da última execução e um grupo salvo (ver
  /// [openGroup]). Null é o painel que não tem mais onde abrir: a pasta saiu
  /// da lateral, o cwd não existe, o documento não voltou.
  MxTab? _openPane(Map<String, dynamic> pane) {
    final root = (pane['folderRoot'] ?? pane['projectRoot']) as String?;
    final folder = pane['loose'] == true ? loose : folders.firstWhereOrNull((f) => f.root == root);
    final cwd = pane['cwd'] as String?;
    if (folder == null || cwd == null || !Directory(cwd).existsSync()) return null;
    final label = pane['label'] as String?;
    final featureOrHotfix = featureOrHotfixById(featureOrHotfixIdIn(pane));
    final MxTab tab;
    if (pane['kind'] == 'reader') {
      // Um leitor volta como o documento que era: um arquivo se relê do
      // disco na montagem do painel, e um plano volta do texto que foi
      // salvo com ele. Sem documento não há painel -- e é melhor não voltar
      // do que voltar uma folha em branco onde havia um plano.
      final doc = MxDoc.fromJson(
        (pane['doc'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      if (doc == null) return null;
      tab = _newReader(doc, folder: folder, cwd: cwd, featureOrHotfix: featureOrHotfix);
    } else if (pane['kind'] == 'browser') {
      // O navegador embutido saiu do app. Um config gravado enquanto ele
      // existia ainda traz painéis desses: eles não voltam, e a linha some do
      // arquivo no primeiro save.
      return null;
    } else if (pane['kind'] == 'setup') {
      // A configuração volta na pasta que configurava, com o mesmo arquivo
      // aberto. Sem pasta não há painel.
      final setup = MxSetup.fromJson(
        (pane['setup'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      if (setup == null || !Directory(setup.root).existsSync()) return null;
      tab = _newSetup(setup, folder: folder, cwd: cwd, featureOrHotfix: featureOrHotfix);
    } else if (pane['kind'] == 'claude') {
      final resumeId = pane['sessionId'] as String?;
      // Hibernada ontem, hibernada hoje -- ver [MxTab.hibernated]. Sem id não
      // há o que retomar, e aí ela volta como sempre voltou: rodando.
      final asleep = pane['hibernated'] == true && resumeId != null;
      tab = openClaude(
        folder,
        cwd: cwd,
        label: label,
        featureOrHotfix: featureOrHotfix,
        resumeId: resumeId,
        start: !asleep,
      );
    } else {
      // Um painel de programa volta rodando o programa: o `btop` que você
      // deixou aberto é `btop` de novo, e não um prompt parado na pasta dele.
      // O programa apagado no meio do caminho devolve o terminal que o painel
      // sempre foi por baixo -- é menos do que você deixou, mas é o painel.
      tab = openShell(
        folder,
        cwd: cwd,
        featureOrHotfix: featureOrHotfix,
        launcher: launcherById(pane['launcher'] as String?),
      );
    }
    if (label != null) tab.customLabel = label;
    tab.tint = MxTint.byName(pane['tint'] as String?);
    // Contido pela base de agora: quem baixou o corpo nas configurações
    // desde a última vez não recebe um painel fora do limite.
    tab.zoom = Mx.type.clampZoom((pane['zoom'] as num?)?.toInt() ?? 0);
    return tab;
  }

  /// Um painel mudou por fora da store: repinta a janela e guarda o estado.
  ///
  /// A porta que faltava pra um painel que tem um mundo próprio dentro dele. O
  /// editor de configuração é o caso: o arquivo aberto muda por um clique
  /// dentro do painel, não por um método daqui, e a linha da lateral tem que
  /// passar a dizer o nome dele. Sem isto o painel só se atualizaria sozinho
  /// por dentro, e a lista ao lado continuaria mostrando o arquivo de antes.
  void touch() {
    _save();
    notifyListeners();
  }

  void _save() {
    if (_restoring || _gone) return;
    // Quem saiu da tela deixa de estar preso, por qualquer caminho que tenha
    // saído -- o x, um grupo que tomou a tela, outra sessão solta em cima.
    // Aqui porque todo gesto que mexe na árvore passa por aqui, e senão a
    // sessão voltaria presa num lugar que você nunca prendeu.
    for (final t in tabs) {
      if (t.pinned && !isOpen(t)) t.pinned = false;
    }
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _writeConfig);
  }

  Future<void> _writeConfig() async {
    try {
      await _configFile.parent.create(recursive: true);
      // Painel com processo vivo, mais o que ainda tem conversa pra retomar --
      // ver [MxTab.resumable]. Descartar todo painel sem processo era descartar
      // a sessão que foi pro background junto com o terminal morto: o claude
      // sai do pty e continua rodando, e era esse id que fazia falta na volta.
      // Os de plugin ficam: ver [TabKind.plugin].
      final open = tabs
          .where((t) => !t.isPluginView && t.owner == null && (!t.exited || t.resumable))
          .toList();
      final tree = Panes.toJson(panes, (id) => open.indexWhere((t) => t.id == id));
      // Escrito ao lado e movido pra cima, em vez de escrito em cima: um
      // `writeAsString` direto cria o arquivo, trunca e só depois escreve, e
      // quem ler nessa fresta acha zero byte. Ler o config é o [_loadConfig],
      // que engole a exceção do `jsonDecode` -- ou seja, a janela abriria sem
      // pasta, sem projeto e sem layout por causa de uma leitura que caiu no
      // milissegundo errado. O `rename` dentro da mesma pasta é atômico: quem
      // ler acha o config velho inteiro ou o novo inteiro, nunca a metade.
      //
      // O pid no nome do temporário é por causa da segunda janela: duas
      // maestrias guardam no mesmo config, e com um nome fixo elas escreveriam
      // uma dentro do rascunho da outra.
      final temp = File('${_configFile.path}.$pid.tmp');
      await temp.writeAsString(
        jsonEncode({
          'folders': folders.map((f) => f.toJson()).toList(),
          // Ao lado das pastas porque é delas que ele fala: a seção é um jeito
          // de desenhar um punhado delas junto. Ver [Workspace].
          if (workspaces.isNotEmpty) 'workspaces': workspaces.map((w) => w.toJson()).toList(),
          'rootOrder': [for (final r in sidebarRows) rowKey(r)],
          'featuresOrHotfixes': featuresOrHotfixes.map((p) => p.toJson()).toList(),
          // Ao lado do layout e escritos com o mesmo json que ele: um grupo é
          // um layout guardado com nome. Ver [PaneGroup].
          if (groups.isNotEmpty) 'groups': groups.map((g) => g.toJson()).toList(),
          if (launchers.isNotEmpty) 'launchers': launchers.map((l) => l.toJson()).toList(),
          'sidebarWidth': sidebarWidth,
          // Só quando está escondida, como os outros interruptores daqui: um
          // config que não fala do assunto é um config com a lateral na tela.
          if (sidebarHidden) 'sidebarHidden': true,
          if (statusBarTop) 'statusBarTop': true,
          if (railOrder.isNotEmpty) 'railOrder': railOrder,
          if (sidebarView != null) 'sidebarView': sidebarView,
          if (doNotDisturb) 'doNotDisturb': true,
          if (floats.toJson() case final f when f.isNotEmpty) 'floats': f,
          if (groupsCollapsed) 'groupsCollapsed': true,
          if (hibernateMinutes != defaultHibernateMinutes) 'hibernateMinutes': hibernateMinutes,
          'theme': Mx.palette.id,
          if (Mx.type.toJson() case final type when type.isNotEmpty) 'type': type,
          if (keymap.toJson() case final binds when binds.isNotEmpty) 'shortcuts': binds,
          if (plugins.toJson() case final p when p.isNotEmpty) 'plugins': p,
          // --- ditado (vocalização) — fora desta versão ----------------------
          // Sai do arquivo no próximo save, junto com o resto: é config de uma
          // feature que ainda não estreou, então não há o que preservar.
          // if (dictation.config.toJson() case final d when d.isNotEmpty) 'dictation': d,
          'layout': {
            'panes': open.map((t) => t.toJson()).toList(),
            if (tree != null) 'tree': tree,
            'focused': open.indexWhere((t) => t.id == focusedPaneId),
          },
        }),
      );
      await temp.rename(_configFile.path);
    } catch (_) {}
  }

  /// Repaints the window in [palette] and remembers the choice.
  void setTheme(MxPalette palette) {
    if (palette.id == Mx.palette.id) return;
    Mx.apply(palette);
    _save();
    notifyListeners();
  }

  /// Reescreve o pty em [type] e guarda a escolha. Vale na hora, em todo
  /// painel — o xterm remede a célula e o pty é redimensionado junto.
  void setTypography(MxType type) {
    if (type == Mx.type) return;
    Mx.applyType(type);
    _save();
    notifyListeners();
  }

  /// ⌘+ e ⌘− no painel em foco, em passos.
  ///
  /// Um leitor responde também: a pergunta que a tecla faz é sobre o painel,
  /// não sobre o pty, e um plano lido de perto é o mesmo pedido.
  void zoomFocused(int by) {
    final tab = focusedTab;
    if (tab == null) return;
    final zoom = Mx.type.clampZoom(tab.zoom + by);
    if (zoom == tab.zoom) return;
    tab.zoom = zoom;
    _save();
    notifyListeners();
  }

  /// ⌘0: devolve o painel em foco ao corpo base.
  void resetZoomFocused() {
    final tab = focusedTab;
    if (tab == null || tab.zoom == 0) return;
    tab.zoom = 0;
    _save();
    notifyListeners();
  }

  /// Põe [chord] em [action] e avisa de quem ela foi tirada — um atalho que
  /// muda de dono em silêncio é uma tecla que um dia simplesmente para de
  /// funcionar, sem nada na tela ligando uma coisa à outra.
  void bindShortcut(MxAction action, MxChord chord, {MxChord? replacing}) {
    final stolen = keymap.bind(action, chord, replacing: replacing);
    if (stolen != null) showBanner('${chord.label} saiu de "${stolen.label}"');
    _save();
    notifyListeners();
  }

  void unbindShortcut(MxAction action, MxChord chord) {
    keymap.unbind(action, chord);
    _save();
    notifyListeners();
  }

  void resetShortcuts([MxAction? action]) {
    action == null ? keymap.reset() : keymap.resetAction(action);
    _save();
    notifyListeners();
  }

  // --- ditado (vocalização) — fora desta versão ------------------------------
  // void setDictation(DictationConfig config) {
  // if (config == dictation.config) return;
  // dictation.config = config;
  // _save();
  // notifyListeners();
  // }

  // --- ditado (vocalização) — fora desta versão ------------------------------
  // /// Falar em vez de digitar, no painel em foco.
  // ///
  // /// Um atalho e não dois porque é um gesto: aperta, fala, aperta. Push-to-talk
  // /// -- segurar a tecla -- seria mais natural e não cabe no mapa de atalhos,
  // /// que é feito de [MxChord] e só sabe da tecla descendo.
  // ///
  // /// O texto é *colado*, nunca enviado, a menos que se peça -- ver
  // /// [DictationConfig.submit]. E vai pro painel em que o ditado começou, não
  // /// pro que está em foco no fim: quem fala trinta segundos pode ter clicado
  // /// em outro painel no meio, e a fala continua sendo daquele.
  // Future<void> toggleDictation() async {
  // if (dictation.phase == DictationPhase.transcribing) return;
  // if (dictation.busy) {
  // final into = _byId(dictation.target);
  // final heard = await dictation.end();
  // if (heard.problem case final why?) {
  // showBanner(why, sticky: true);
  // return;
  // }
  // final text = heard.text ?? '';
  // if (text.isEmpty) {
  // showBanner('não entendi nada — nada foi colado');
  // return;
  // }
  // if (into == null || into.exited) {
  // showBanner('o painel que estava ouvindo não está mais aí: "$text"', sticky: true);
  // return;
  // }
  // if (dictation.config.submit) {
  // await into.term.submit(text);
  // } else {
  // into.term.terminal.paste(text);
  // }
  // return;
  // }
  // final tab = focusedTab;
  // // Um leitor não tem prompt pra receber texto, e um painel cujo processo
  // // saiu não tem quem o leia.
  // if (tab == null || tab.isReader || tab.exited) {
  // showBanner('o ditado precisa de um painel com processo vivo em foco');
  // return;
  // }
  // if (await dictation.begin(tab.id) case final why?) showBanner(why, sticky: true);
  // }

  /// Called on every drag frame, so it bails when the clamp swallowed the
  /// delta — otherwise dragging past the end keeps repainting for nothing.
  void setSidebarWidth(double width) {
    final w = width.clamp(minSidebar, maxSidebar);
    if (w == sidebarWidth) return;
    sidebarWidth = w;
    _save();
    notifyListeners();
  }

  /// Tira a lateral da tela, ou a traz de volta. Ver [sidebarHidden].
  void toggleSidebar() => setSidebarHidden(!sidebarHidden);

  /// Separado do toggle porque há quem precise dela na tela sem saber se ela
  /// está: buscar na lateral escondida é mostrá-la primeiro. Ver [MxKeys.run].
  void setSidebarHidden(bool hidden) {
    if (hidden == sidebarHidden) return;
    sidebarHidden = hidden;
    _save();
    _syncSidebar();
    notifyListeners();
  }

  /// Leva a barra de status pro topo da janela, ou de volta pro pé. Ver
  /// [statusBarTop].
  void setStatusBarTop(bool top) {
    if (top == statusBarTop) return;
    statusBarTop = top;
    _save();
    notifyListeners();
  }

  /// O clique num ícone da faixa: [pluginId] null é o das sessões.
  ///
  /// O do VS Code, inteiro: com a lateral escondida, qualquer ícone a traz de
  /// volta já na aba dele; clicar no ícone da aba que já está na tela esconde
  /// a lateral. É o que deixa a faixa ser também o interruptor, sem um quarto
  /// botão pra isso.
  void showSidebarView(String? pluginId) {
    final current = shownPlugin?.id;
    if (!sidebarHidden && current == pluginId) return setSidebarHidden(true);
    sidebarHidden = false;
    sidebarView = pluginId;
    _save();
    // Todo clique avisa, mesmo o que volta pra aba que já era a dela: é a
    // deixa pro plugin olhar de novo -- o git relê o status, o flutter os
    // aparelhos.
    _syncSidebar(announce: true);
    notifyListeners();
  }

  /// O plugin cuja aba própria está na tela agora. Ver [_syncSidebar].
  String? _sidebarLive;

  /// Conta ao plugin que a aba dele entrou ou saiu da tela
  /// (`sidebar.shown` / `sidebar.hidden`).
  ///
  /// Entrar sobe o processo se ele não está de pé: a aba é dele, e sem ele
  /// não há o que desenhar. O aviso sai quando ele terminar de subir -- ver
  /// [Plugins.onReady]. Sair não derruba nada: é a deixa pra ele parar de
  /// vigiar o que ninguém está vendo.
  void _syncSidebar({bool announce = false}) {
    final shown = sidebarHidden ? null : shownPlugin;
    final now = shown != null && shown.manifest!.sidebar ? shown.id : null;
    if (now == _sidebarLive && !announce) return;
    if (_sidebarLive case final gone? when gone != now) {
      if (plugins.byId(gone) case final p?) plugins.tell(p, 'sidebar.hidden');
    }
    _sidebarLive = now;
    if (now == null) return;
    final p = plugins.byId(now)!;
    plugins.isUp(p) ? plugins.tell(p, 'sidebar.shown') : plugins.wake(p);
  }

  /// A aba própria de cada plugin que já mandou uma (`sidebar.update`). Um
  /// [MxTab] fora de [tabs], como a janela de plugin sem painel: é o que deixa
  /// a aba ser desenhada pelo mesmo [PluginPane] das janelas -- os mesmos
  /// blocos, os mesmos campos, o mesmo `view.action` de volta, com
  /// `viewId: "sidebar"`.
  final Map<String, MxTab> _sidebarTabs = {};

  /// O id de janela reservado pra aba da lateral.
  static const sidebarViewId = 'sidebar';

  /// A aba própria de [plugin], se ele já mandou alguma.
  MxTab? sidebarTabOf(MxPlugin plugin) => _sidebarTabs[plugin.id];

  /// O selo que cada plugin pediu pro ícone dele na faixa -- as mudanças do
  /// git, um app rodando. Ausente, o ícone conta as janelas abertas.
  final Map<String, String> sidebarBadges = {};

  /// Os painéis pequenos que os plugins põem por cima da janela
  /// (`float.show`), e onde cada um foi largado. Ver [PluginFloats].
  late final PluginFloats floats = PluginFloats(onMoved: _save);

  /// Troca os blocos da aba de [plugin] e/ou o selo do ícone dele (vazio
  /// tira). Null é "não mexe". Diz se a aba está na tela.
  bool updatePluginSidebar(
    MxPlugin plugin, {
    List<Map<String, dynamic>>? blocks,
    String? badge,
    PluginRfwUpdate? rfw,
  }) {
    if (badge != null) {
      badge.isEmpty ? sidebarBadges.remove(plugin.id) : sidebarBadges[plugin.id] = badge;
    }
    if (blocks == null && rfw == null) {
      notifyListeners();
      return _sidebarLive == plugin.id;
    }
    final tab = _sidebarTabs.putIfAbsent(
      plugin.id,
      () => MxTab(
        id: 'sidebar:${plugin.id}',
        folder: loose,
        kind: TabKind.plugin,
        cwd: loose.root,
        branch: '',
        view: PluginView(
          pluginId: plugin.id,
          pluginName: plugin.name,
          id: sidebarViewId,
          title: plugin.name,
          blocks: const [],
        ),
      ),
    );
    if (rfw != null) tab.view!.setRfw(library: rfw.library, root: rfw.root, data: rfw.data);
    if (blocks != null) {
      tab.view!
        ..rfwLibrary = null
        ..setBlocks(blocks);
    }
    notifyListeners();
    return _sidebarLive == plugin.id;
  }

  /// Os plugins que ganham um ícone na faixa, na ordem de [railOrder] e, pra
  /// quem não está lá, na dos plugins.
  ///
  /// Os que têm um lugar a oferecer: um desenho próprio e algum comando (o
  /// Flutter, o SSH, o git) -- e qualquer um com janela aberta, que de outro
  /// jeito não teria onde aparecer. Um plugin só de temas, ou o relatório, que
  /// é um botão e não um lugar, fica fora: uma aba pra um botão é uma lateral
  /// vazia com um botão no meio.
  List<MxPlugin> get railPlugins {
    final shown = [
      for (final p in plugins.all)
        if ((p.active &&
                (p.manifest!.sidebar ||
                    (p.manifest!.icon != null && p.manifest!.commands.isNotEmpty))) ||
            tabs.any((t) => t.view?.pluginId == p.id || t.owner == p.id))
          p,
    ];
    return [
      for (final id in railOrder) ?shown.firstWhereOrNull((p) => p.id == id),
      for (final p in shown)
        if (!railOrder.contains(p.id)) p,
    ];
  }

  /// Leva o ícone de [pluginId] pra posição [to] da faixa. Os que não estão
  /// na faixa agora (um plugin desligado) continuam guardados, no fim, pra
  /// voltarem num lugar conhecido quando ligarem de novo.
  void moveRailPlugin(String pluginId, int to) {
    final ids = [for (final p in railPlugins) p.id]..remove(pluginId);
    ids.insert(to.clamp(0, ids.length), pluginId);
    railOrder = [
      ...ids,
      for (final id in railOrder)
        if (!ids.contains(id)) id,
    ];
    _save();
    notifyListeners();
  }

  /// O plugin da aba na tela, ou null pras sessões. Um [sidebarView] que
  /// aponta pra um plugin que saiu da faixa cai nas sessões em vez de mostrar
  /// uma aba de ninguém.
  MxPlugin? get shownPlugin {
    final id = sidebarView;
    if (id == null) return null;
    return railPlugins.firstWhereOrNull((p) => p.id == id);
  }

  /// As janelas abertas de [plugin], na ordem em que abriram.
  List<MxTab> viewsOf(MxPlugin plugin) => tabs.where((t) => t.view?.pluginId == plugin.id).toList();

  /// Os botões de plugin do rodapé: os que pediram lugar ali e cujo plugin
  /// não tem aba na faixa -- o que tem já é um ícone, e dois ícones pro mesmo
  /// lugar fariam pensar que são dois lugares.
  List<PluginCommand> get footerCommands => plugins.commands
      .where((c) => c.sidebar && !railPlugins.any((p) => p.id == c.pluginId))
      .take(Plugins.maxSidebarCommands)
      .toList();

  /// As sessões do claude esperando por você, em todas as pastas. É o selo do
  /// ícone das sessões na faixa: numa aba de plugin, a lista que diria isso
  /// não está na tela.
  List<MxTab> get waitingSessions =>
      tabs.where((t) => t.kind == TabKind.claude && !t.done && t.status.needsHuman).toList();

  // --- folders -----------------------------------------------------------

  Future<Folder?> addFolder(String rawPath) async {
    final outcome = await _adoptFolder(rawPath);
    if (outcome.folder == null) {
      showBanner('pasta não encontrada: ${expandHome(rawPath)}', sticky: true);
      return null;
    }
    if (!outcome.created) return outcome.folder;
    _save();
    await refreshGit();
    notifyListeners();
    return outcome.folder;
  }

  /// A pasta adotada, e se ela é nova.
  ///
  /// Separado de [addFolder] por causa de [importWorkspace], que adota várias
  /// de uma vez: gravar o config e varrer o git a cada uma seria N gravações e
  /// N `git worktree list` pra um gesto só. E o `created` é o que os dois
  /// chamadores não conseguem descobrir sozinhos depois -- uma pasta devolvida
  /// é uma pasta devolvida, tenha ela acabado de entrar ou estado ali desde
  /// ontem.
  ///
  /// Não fala com o usuário e não notifica: quem chama é que sabe o que dizer.
  Future<({Folder? folder, bool created})> _adoptFolder(String rawPath) async {
    // O caminho vem de um campo de texto, e num campo de texto se digita `~/`
    // -- ver [expandHome]. Aqui em cima porque tudo abaixo (o `git` da pasta, o
    // `existsSync`, o que vai pro config) já tem que estar falando do lugar de
    // verdade.
    final path = expandHome(rawPath);
    final root = await Git.mainRoot(path);
    final resolved = root ?? path;
    final existing = folders.firstWhereOrNull((p) => p.root == resolved);
    if (existing != null) return (folder: existing, created: false);
    if (!Directory(resolved).existsSync()) return (folder: null, created: false);
    final folder = Folder(root: resolved, name: resolved.split('/').last);
    folders.add(folder);
    return (folder: folder, created: true);
  }

  /// Um `.code-workspace` do VS Code, aberto como o que ele é aqui: as pastas
  /// dele, todas de uma vez.
  ///
  /// No config ficam as pastas e o [Workspace] que as lista, com o arquivo
  /// guardado como de onde ele veio -- ver [CodeWorkspace]. O
  /// arquivo é um jeito de adicionar pasta, e o que ele evita é justamente o
  /// que ele parece pouco: adicionar uma a uma, no dedo, uma lista que já
  /// existe escrita em algum lugar.
  ///
  /// O resumo devolvido importa mais do que parece. Duas pastas do mesmo
  /// monorepo resolvem pro mesmo checkout principal e viram uma só na lateral
  /// (ver `Git.mainRoot`), e sem alguém contando isso o botão engoliria uma
  /// pasta em silêncio -- ver [WorkspaceImport].
  Future<WorkspaceImport?> importWorkspace(String rawPath) async {
    final ws = await CodeWorkspace.read(rawPath);
    if (ws == null) {
      showBanner('não consegui ler esse workspace: ${expandHome(rawPath.trim())}', sticky: true);
      return null;
    }
    if (ws.folders.isEmpty) {
      showBanner('o workspace "${ws.name}" não lista nenhuma pasta', sticky: true);
      return null;
    }
    final added = <Folder>[];
    final already = <Folder>[];
    final missing = <String>[];
    for (final entry in ws.folders) {
      final outcome = await _adoptFolder(entry.path);
      final folder = outcome.folder;
      if (folder == null) {
        missing.add(entry.path);
        continue;
      }
      if (!outcome.created) {
        already.add(folder);
        continue;
      }
      // O apelido do workspace só vale pra pasta que ele de fato nomeia: se o
      // git subiu daqui pro checkout principal, o nome escolhido era do
      // subdiretório e pendurá-lo no repo inteiro seria uma etiqueta errada.
      if (entry.name != null && folder.root == entry.path) folder.name = entry.name!;
      added.add(folder);
    }
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
    _save();
    if (added.isNotEmpty) await refreshGit();
    final result = WorkspaceImport(workspace: ws, added: added, already: already, missing: missing);
    showBanner(result.summary, sticky: result.sticky);
    notifyListeners();
    return result;
  }

  /// A cor desta pasta, ou null pra tirar a que ela tinha. Ver [Folder.tint].
  void setFolderTint(Folder folder, MxTint? tint) {
    folder.tint = tint;
    _save();
    notifyListeners();
  }

  void renameFolder(Folder p, String name) {
    p.name = name;
    _save();
    notifyListeners();
  }

  void toggleCollapsed(Folder p) {
    p.collapsed = !p.collapsed;
    _save();
    notifyListeners();
  }

  Future<void> removeFolder(Folder p) async {
    folders.remove(p);
    for (final w in workspaces) {
      w.folderRoots.remove(p.root);
      w.collapsedFolders.remove(p.root);
    }
    featuresOrHotfixes.removeWhere((pr) => pr.folderRoot == p.root);
    for (final t in tabs.where((t) => t.folderRoot == p.root).toList()) {
      closeTab(t);
    }
    _save();
    notifyListeners();
  }

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

  /// Se a busca achou alguma coisa nesta seção -- numa sessão de qualquer
  /// pasta dela.
  bool hasHitsInWorkspace(Workspace w) => foldersOf(w).any(hasHits);

  Future<void> refreshGit() async {
    for (final p in folders) {
      final list = await Git.worktrees(p.root);
      // A call that could not answer keeps the last answer. Writing an empty
      // list here on a lost `git` call is what made the sidebar fold a
      // folder's worktrees away and unfold them ten seconds later, with
      // everything below jumping both times.
      if (list == null) continue;
      worktrees[p.root] = list;
      // `worktree list` fails outside a repo, so an empty list is the answer
      // to "is this even a repo" -- and its first entry is the main checkout,
      // which is the branch the folder itself is sitting on.
      p.isRepo = list.isNotEmpty;
      p.branch = list.firstWhereOrNull((w) => w.isMain)?.branch ?? '';
    }
    for (final t in tabs) {
      t.dirty = await Git.dirtyCount(t.cwd) ?? t.dirty;
      if (t.branch.isEmpty) t.branch = await Git.branchOf(t.cwd);
    }
    notifyListeners();
  }

  /// Where a new panel lands: the folder you are looking at, and the loose
  /// tray when you are looking at nothing at all.
  Folder get focusedFolder {
    final tab = focusedTab;
    if (tab != null) {
      if (tab.folder.isLoose) return loose;
      final p = folders.firstWhereOrNull((p) => p.root == tab.folderRoot);
      if (p != null) return p;
    }
    return folders.firstOrNull ?? loose;
  }

  // --- busca --------------------------------------------------------------

  /// O que está escrito no campo de busca da lateral.
  ///
  /// Nada disto vai pro config, e é de propósito: uma busca é sobre agora. Um
  /// filtro que sobrevivesse ao restart abriria o app escondendo metade das
  /// sessões sem ninguém ter pedido.
  String query = '';

  /// As pastas e os projetos marcados no menu de filtros, pela identidade que
  /// sobrevive a um rename: o root e o id.
  final Set<String> filterRoots = {};
  final Set<String> filterFeaturesOrHotfixes = {};
  final Set<MxFilter> filterFlags = {};

  /// Os termos de [query], separados: "google perm" acha "permissão do google"
  /// sem exigir a ordem. Recalculado ao digitar, não a cada linha desenhada.
  List<String> _terms = [];

  bool get filtering =>
      _terms.isNotEmpty ||
      filterRoots.isNotEmpty ||
      filterFeaturesOrHotfixes.isNotEmpty ||
      filterFlags.isNotEmpty;

  /// Quantas opções estão marcadas, pro ponto no botão de filtro.
  int get activeFilters => filterRoots.length + filterFeaturesOrHotfixes.length + filterFlags.length;

  void setQuery(String q) {
    if (q == query) return;
    query = q;
    _terms = q.toLowerCase().split(' ').where((t) => t.isNotEmpty).toList();
    notifyListeners();
  }

  void toggleFilter(MxFilter f) {
    filterFlags.contains(f) ? filterFlags.remove(f) : filterFlags.add(f);
    notifyListeners();
  }

  void toggleFilterFolder(Folder f) {
    filterRoots.contains(f.root) ? filterRoots.remove(f.root) : filterRoots.add(f.root);
    notifyListeners();
  }

  void toggleFilterFeatureOrHotfix(FeatureOrHotfix p) {
    filterFeaturesOrHotfixes.contains(p.id) ? filterFeaturesOrHotfixes.remove(p.id) : filterFeaturesOrHotfixes.add(p.id);
    notifyListeners();
  }

  /// Volta a lateral a mostrar tudo. Um caminho só, chamado pelo x do campo,
  /// pelo "limpar" do menu, pelo Esc e pela tela de "nada encontrado" — quatro
  /// saídas que precisam deixar exatamente o mesmo estado.
  void clearSearch() {
    if (!filtering && query.isEmpty) return;
    query = '';
    _terms = [];
    filterRoots.clear();
    filterFeaturesOrHotfixes.clear();
    filterFlags.clear();
    notifyListeners();
  }

  /// Tudo em que a busca procura, numa linha. O que *não* está aqui é o
  /// subtítulo: ele muda a cada turno da sessão, e uma lista de resultados que
  /// se remonta sozinha enquanto o agente fala é uma lista que não dá pra usar.
  String _haystack(MxTab t) => [
    t.title,
    t.customLabel ?? '',
    t.folder.name,
    featureOrHotfixOf(t)?.name ?? '',
    t.branch,
    t.cwd,
    t.agentName ?? '',
    // Pra "shell" e "claude" acharem por tipo sem passar pelo menu.
    t.kind.name,
  ].join(' ').toLowerCase();

  /// Esta sessão passa pela busca e pelos filtros de agora?
  bool matches(MxTab t) {
    if (_terms.isNotEmpty) {
      final hay = _haystack(t);
      if (!_terms.every(hay.contains)) return false;
    }
    // Pasta e projeto são o mesmo grupo — o "onde" — e somam entre si: marcar
    // um repo e um projeto de outro repo mostra os dois, não nada.
    if (filterRoots.isNotEmpty || filterFeaturesOrHotfixes.isNotEmpty) {
      final scoped =
          filterRoots.contains(t.folderRoot) ||
          (t.featureOrHotfixId != null && filterFeaturesOrHotfixes.contains(t.featureOrHotfixId));
      if (!scoped) return false;
    }
    for (final group in MxFilterGroup.values) {
      final picked = filterFlags.where((f) => f.group == group);
      if (picked.isNotEmpty && !picked.any((f) => f.matches(t))) return false;
    }
    return true;
  }

  /// A lista que uma parte da lateral desenha: tudo, ou só os achados.
  List<MxTab> visible(Iterable<MxTab> of) => (filtering ? of.where(matches) : of).toList();

  /// Se este grupo tem alguma coisa a mostrar. Um grupo sem achado nenhum sai
  /// da lateral inteiro enquanto a busca durar — um cabeçalho vazio é uma
  /// linha dizendo "não é aqui" ocupando o lugar de uma que é.
  bool hasHits(Folder f) => tabsOf(f).any(matches);

  List<MxTab> get hits => tabs.where(matches).toList();

  // --- projects -----------------------------------------------------------

  List<FeatureOrHotfix> featuresOrHotfixesOf(Folder f) => featuresOrHotfixes.where((p) => p.folderRoot == f.root).toList();

  FeatureOrHotfix? featureOrHotfixById(String? id) =>
      id == null ? null : featuresOrHotfixes.firstWhereOrNull((p) => p.id == id);

  FeatureOrHotfix? featureOrHotfixOf(MxTab tab) => featureOrHotfixById(tab.featureOrHotfixId);

  /// The project a new panel joins when the caller did not name one: whichever
  /// the panel you are looking at is in. Opening a third session while you are
  /// inside "permissão do google" means a third session on that job.
  FeatureOrHotfix? get focusedFeatureOrHotfix {
    final tab = focusedTab;
    return tab == null ? null : featureOrHotfixOf(tab);
  }

  FeatureOrHotfix addFeatureOrHotfix(
    Folder f,
    String name, {
    String brief = '',
    FeatureOrHotfixKind kind = FeatureOrHotfixKind.feature,
  }) {
    final featureOrHotfix = FeatureOrHotfix(
      // Not the tab counter: this one outlives the window, and `tab3` would
      // name a different project every time the app restarts.
      id: 'pj${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      folderRoot: f.root,
      name: name,
      brief: brief,
      kind: kind,
    );
    featuresOrHotfixes.add(featureOrHotfix);
    _save();
    notifyListeners();
    return featureOrHotfix;
  }

  void editFeatureOrHotfix(FeatureOrHotfix featureOrHotfix, {String? name, String? brief}) {
    if (name != null && name.trim().isNotEmpty) featureOrHotfix.name = name.trim();
    if (brief != null) featureOrHotfix.brief = brief;
    _save();
    notifyListeners();
  }

  /// A cor deste projeto, ou null pra tirar a que ele tinha -- e com ela a
  /// dos painéis que não escolheram a sua. Ver [FeatureOrHotfix.tint] e [tintOf].
  ///
  /// Fora do [editFeatureOrHotfix] de propósito: aquele tem os campos que se editam
  /// num diálogo de texto, e este é uma escolha de menu que vale na hora.
  void setFeatureOrHotfixTint(FeatureOrHotfix featureOrHotfix, MxTint? tint) {
    featureOrHotfix.tint = tint;
    _save();
    notifyListeners();
  }

  /// Troca a natureza depois de criada: o "login quebrado" que parecia
  /// feature e era hotfix. Nada mais muda -- ver [FeatureOrHotfixKind].
  void setFeatureOrHotfixKind(FeatureOrHotfix featureOrHotfix, FeatureOrHotfixKind kind) {
    if (featureOrHotfix.kind == kind) return;
    featureOrHotfix.kind = kind;
    _save();
    notifyListeners();
  }

  void toggleFeatureOrHotfixCollapsed(FeatureOrHotfix featureOrHotfix) {
    featureOrHotfix.collapsed = !featureOrHotfix.collapsed;
    _save();
    notifyListeners();
  }

  /// Finish a project: the job is done, so its sessions are over too.
  ///
  /// The one difference from [removeFeatureOrHotfix] is the only one that matters --
  /// there the panels stay open because the work goes on without the label;
  /// here they close, because saying a project is done and leaving four
  /// sessions of it running would be saying two different things at once.
  /// Nothing is archived: what the job leaves behind is in the repo, and a
  /// briefing worth keeping is a paragraph the caller copies out first.
  ///
  /// Returns how many panels went with it, so the caller can say so.
  int completeFeatureOrHotfix(FeatureOrHotfix featureOrHotfix) {
    final closing = tabsIn(featureOrHotfix);
    for (final t in closing) {
      closeTab(t);
    }
    featuresOrHotfixes.remove(featureOrHotfix);
    _save();
    notifyListeners();
    return closing.length;
  }

  /// Dissolve a project. Its panels are set loose in the folder, not closed --
  /// dropping the label you put on a job is not deciding the job is over.
  void removeFeatureOrHotfix(FeatureOrHotfix featureOrHotfix) {
    featuresOrHotfixes.remove(featureOrHotfix);
    for (final t in tabs.where((t) => t.featureOrHotfixId == featureOrHotfix.id)) {
      t.featureOrHotfixId = null;
    }
    _save();
    notifyListeners();
  }

  /// Move [tab] into [featureOrHotfix], or out of every project when it is null.
  ///
  /// A project belongs to one folder, so a panel running somewhere else
  /// cannot join it: the brief would be describing a checkout that session
  /// cannot see.
  void assign(MxTab tab, FeatureOrHotfix? featureOrHotfix) {
    if (featureOrHotfix != null && featureOrHotfix.folderRoot != tab.folderRoot) return;
    if (tab.featureOrHotfixId == featureOrHotfix?.id) return;
    tab.featureOrHotfixId = featureOrHotfix?.id;
    _save();
    notifyListeners();
  }

  List<MxTab> tabsIn(FeatureOrHotfix featureOrHotfix) => tabs.where((t) => t.featureOrHotfixId == featureOrHotfix.id).toList();

  /// A session marked done is counted nowhere: the mark exists to stop a
  /// finished panel from spending the badge that means "somebody go look".
  int needingHumanIn(FeatureOrHotfix featureOrHotfix) =>
      tabsIn(featureOrHotfix).where((t) => !t.done && t.status.needsHuman).length;

  // --- tabs ---------------------------------------------------------------

  MxTab openShell(
    Folder f, {
    String? cwd,
    String? command,
    FeatureOrHotfix? featureOrHotfix,
    Launcher? launcher,
    bool place = true,
  }) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: f,
      kind: TabKind.shell,
      cwd: cwd ?? f.root,
      branch: '',
      launcher: launcher,
    );
    if (featureOrHotfix != null && featureOrHotfix.folderRoot == f.root) tab.featureOrHotfixId = featureOrHotfix.id;
    _register(tab, place: place);
    // O comando do programa, quando quem chamou não trouxe um: é o que faz
    // "abrir o btop" abrir o btop, e não um prompt onde você digitaria btop.
    final run = command ?? launcher?.command;
    if (run == null) {
      tab.term.startShell(tab.cwd);
    } else {
      tab.term.startCommand(run, tab.cwd);
    }
    return tab;
  }

  /// Abre [launcher] numa pasta: um terminal que já sobe dentro do programa.
  ///
  /// O mesmo caminho de [openShell] -- porque é isso que ele é. O que o
  /// programa acrescenta é o de fora do pty: o nome no cabeçalho, o desenho na
  /// lateral, e o painel voltando amanhã rodando a mesma coisa.
  MxTab openLauncher(Launcher launcher, Folder f, {String? cwd, FeatureOrHotfix? featureOrHotfix}) =>
      openShell(f, cwd: cwd, featureOrHotfix: featureOrHotfix, launcher: launcher);

  /// Launch `claude` in [cwd], named, with our hook listeners injected.
  MxTab openClaude(
    Folder f, {
    required String cwd,
    String? label,
    String? resumeId,
    FeatureOrHotfix? featureOrHotfix,
    String? prompt,
    bool start = true,
  }) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: f,
      kind: TabKind.claude,
      cwd: cwd,
      branch: '',
      customLabel: label,
    );
    tab.sessionId = resumeId;
    if (featureOrHotfix != null && featureOrHotfix.folderRoot == f.root) tab.featureOrHotfixId = featureOrHotfix.id;
    _register(tab);

    final name = (label == null || label.isEmpty) ? tab.cwd.split('/').last : label;
    tab.agentName = name;
    if (start) {
      _launchClaude(tab, resumeId: resumeId, prompt: prompt);
    } else {
      // Um painel que nasce hibernado: a linha na lateral, a conversa pra
      // retomar, e nenhum processo. Ver [MxTab.hibernated].
      tab.hibernated = true;
      tab.term.park();
      tab.hooks.status = ClaudeStatus.ended;
      tab.term.remark('hibernada — a conversa volta com um clique');
    }

    Git.branchOf(cwd).then((b) {
      tab.branch = b;
      notifyListeners();
    });
    return tab;
  }

  /// Sobe o `claude` de [tab] -- na abertura, e de novo ao acordar de uma
  /// hibernação ([wake]), que é por que isto tem nome próprio.
  void _launchClaude(MxTab tab, {String? resumeId, String? prompt}) {
    final name = tab.agentName ?? tab.cwd.split('/').last;
    // The project's standing context, when the panel is in one. In the system
    // prompt rather than as a first message: it has to still be true on turn
    // forty, and a first message scrolls out of the window long before that.
    final joined = featureOrHotfixOf(tab);
    final brief = joined?.brief.trim() ?? '';
    final opening = prompt?.trim() ?? '';
    final parts = [
      'claude',
      '--name ${Sh.q(name)}',
      '--settings ${Sh.q(hooks.settingsFor(tab.id))}',
      if (brief.isNotEmpty) '--append-system-prompt ${Sh.q(brief)}',
      if (resumeId != null) '--resume ${Sh.q(resumeId)}',
      // Positional, so it comes last: `claude [flags] '<prompt>'` opens the
      // REPL with that already sent. Typing it into the pty instead would be
      // racing the TUI for its own prompt.
      if (opening.isNotEmpty) Sh.q(opening),
    ];
    tab.term.startCommand(
      parts.join(' '),
      tab.cwd,
      display:
          'claude --name ${Sh.q(name)} '
          '--settings <hooks :${hooks.port}>'
          '${brief.isEmpty ? '' : ' --append-system-prompt <briefing de ${joined!.name}>'}'
          '${resumeId == null ? '' : ' --resume …'}'
          '${opening.isEmpty ? '' : ' <prompt inicial>'}',
    );
    // Nothing reports the prompt being ready -- see `HookState.settle` -- so
    // the panel gives the launch a beat and then says so itself. A session
    // that spoke first (it can only be a prompt you typed) keeps its state.
    Timer(const Duration(seconds: 3), () {
      if (!tabs.contains(tab) || tab.exited) return;
      if (tab.hooks.settle()) notifyListeners();
    });
  }

  // --- histórico de conversas ---------------------------------------------

  /// As conversas que já rodaram em [folder]. Ver `services/history.dart`.
  ///
  /// Da pasta *e das worktrees dela*, porque uma conversa é da worktree em que
  /// aconteceu -- e o trabalho aqui mora em worktree: filtrar só pelo checkout
  /// principal esconderia justamente as conversas de task.
  ///
  /// Quem pergunta é a seção de uma pasta no histórico, quando alguém pede o
  /// resto dela: a lista chega com as conversas mais recentes de todas as
  /// pastas juntas -- ver [allChats] --, e o pedaço de uma pasta que cai ali
  /// não é o histórico dela. A bandeja dos avulsos não tem o que pedir e
  /// recebe [allChats]: ela é o que sobrou de pasta nenhuma.
  Future<List<ChatEntry>> chatsIn(Folder folder) => folder.isLoose
      ? allChats()
      : ChatHistory.read(
          root: chatHome,
          cwds: [folder.root, ...?worktrees[folder.root]?.map((w) => w.path)],
        );

  /// Todas as conversas, de qualquer pasta.
  ///
  /// Não é a soma das [chatsIn] das pastas da lateral: o `~/.claude/projects`
  /// guarda uma pasta por caminho em que o claude já rodou, e a maior parte
  /// deles nunca foi adicionada aqui. É essa a pergunta que isto responde --
  /// "aquela conversa de sexta", sem lembrar em que repo ela foi --, e é por
  /// isso que ela é da janela e não de uma pasta.
  ///
  /// Quem retoma uma delas cai na pasta pelo caminho da própria conversa, e
  /// nos avulsos quando ele não é de nenhuma das de cima: ver [resumeChat].
  Future<List<ChatEntry>> allChats() => ChatHistory.read(root: chatHome);

  /// De onde as conversas são lidas. Sob teste, as fixtures -- pela mesma
  /// razão de [stateHome]: um `flutter test` que fosse ao `~/.claude` de
  /// verdade dependeria das conversas que a máquina de quem rodou teve.
  static String get chatHome =>
      Platform.environment.containsKey('FLUTTER_TEST') ? 'test/fixtures/history' : ChatHistory.home;

  /// A pasta da lateral em que [cwd] está, quando é de alguma: a raiz dela,
  /// algo dentro dela, ou uma worktree dela -- que é outra pasta no disco e
  /// ainda é trabalho do mesmo repo, e é onde metade das conversas daqui
  /// rodou. Ver [worktrees].
  ///
  /// Nula é o caminho que a lateral não conhece: o `~/.claude/projects` tem
  /// uma pasta por lugar em que o claude já rodou, e a maior parte deles nunca
  /// foi adicionada aqui. É essa a resposta que os avulsos recebem -- no
  /// histórico, que reparte as conversas por pasta, e no painel que retoma uma
  /// delas. Ver [resumeChat].
  Folder? folderAt(String cwd) {
    if (cwd.isEmpty) return null;
    bool inside(String root) => cwd == root || cwd.startsWith('$root/');
    // A raiz antes das worktrees porque é o caso de quase toda conversa, e não
    // porque uma exclua a outra: as duas listas não se cruzam.
    return folders.firstWhereOrNull((f) => inside(f.root)) ??
        folders.firstWhereOrNull((f) => worktrees[f.root]?.any((w) => inside(w.path)) ?? false);
  }

  /// Em que pé está [chat] agora. Ver [ChatStanding].
  ChatStanding standingOf(ChatEntry chat) {
    if (tabs.any((t) => t.resumeId == chat.sessionId)) return ChatStanding.onScreen;
    // Viva é o que o `claude agents --json` lista: ele só enxerga processo de
    // pé, que é a razão de ele não servir de histórico -- e a razão de servir
    // exatamente pra isto.
    if (agents.latest.any((a) => a.sessionId == chat.sessionId)) return ChatStanding.live;
    if (chat.missing || chat.cwd.isEmpty || !Directory(chat.cwd).existsSync()) {
      return ChatStanding.gone;
    }
    return ChatStanding.fresh;
  }

  /// Retoma [chat] num painel: o `--resume` daquela conversa, na pasta em que
  /// ela rodou.
  ///
  /// As três recusas são as de [ChatStanding], e a linha do histórico já as
  /// mostrava antes do clique -- o aviso aqui é pra quem clicou de qualquer
  /// jeito, ou pra quando a sessão subiu entre a leitura da lista e o clique.
  MxTab? resumeChat(ChatEntry chat, {Folder? folder, FeatureOrHotfix? featureOrHotfix}) {
    switch (standingOf(chat)) {
      case ChatStanding.onScreen:
        // Não é pra abrir de novo: é pra olhar. Uma segunda sessão no mesmo id
        // seria o CLI recusando por sessão viva -- a que o próprio cockpit
        // acabou de subir.
        final open = tabs.firstWhere((t) => t.resumeId == chat.sessionId);
        select(open);
        return open;
      case ChatStanding.live:
        showBanner(
          '"${chat.label}" ainda está rodando fora do maestria — '
          'o claude só retoma uma conversa depois que ela sai',
          sticky: true,
        );
        return null;
      case ChatStanding.gone:
        showBanner(
          chat.cwd.isEmpty
              ? 'não sei em que pasta "${chat.label}" rodou'
              : 'a pasta dessa conversa não existe mais: ${chat.cwd}',
          sticky: true,
        );
        return null;
      case ChatStanding.fresh:
        break;
    }
    // A pasta que o cockpit conhece pra esse caminho, quando quem pediu não
    // disse: o histórico inteiro traz conversa de repo que não está na lateral,
    // e essa entra nos avulsos.
    final at = folder ?? folderAt(chat.cwd) ?? loose;
    return openClaude(
      at,
      cwd: chat.cwd,
      // O painel se chama pela conversa. Sem isto ele viria com o nome da
      // pasta, igual a todos os outros dali -- e o que se acabou de escolher
      // numa lista de quarenta foi *aquela* conversa.
      label: chat.label,
      resumeId: chat.sessionId,
      featureOrHotfix: featureOrHotfix,
    );
  }

  // --- painéis de leitura -------------------------------------------------

  /// Põe [doc] na tela, num painel de leitura. Ver [TabKind.reader].
  ///
  /// Reaproveita o leitor que já estiver aberto, quando há um: um leitor é um
  /// *lugar*, do mesmo jeito que um painel de terminal é um lugar, e abrir
  /// quatro `.md` seguidos é trocar o que está naquele lugar quatro vezes --
  /// não picar a janela em quatro. Sem nenhum aberto, o documento entra ao
  /// lado do painel de onde saiu e não em cima dele: quem clica em "ver o
  /// plano" quer o plano *e* a sessão que o escreveu.
  ///
  /// [folder] é o lugar de onde o documento veio, quando quem o pediu foi um
  /// lugar e não um painel -- o botão direito de uma pasta, de um projeto, de
  /// uma worktree. Sem ele o leitor herdaria a pasta do painel em foco, e um
  /// `.md` aberto pelo menu de uma pasta apareceria na lateral debaixo de
  /// outra. [cwd] é a pasta exata quando o lugar não é a raiz dela -- o
  /// checkout de uma worktree --, e sem ele é a raiz.
  MxTab showDoc(MxDoc doc, {MxTab? from, Folder? folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) {
    final source = from ?? focusedTab;
    // O que está na tela primeiro; depois um que tenha saído dela -- um leitor
    // que alguém tirou do painel continua sendo *o* leitor, e abrir o próximo
    // documento num segundo deixaria dois na lateral pra sempre.
    final reading =
        openPanes.firstWhereOrNull((t) => t.isReader) ?? tabs.firstWhereOrNull((t) => t.isReader);
    if (reading != null) {
      reading.doc!.become(doc);
      // O apelido era o nome do documento anterior. Um leitor renomeado à mão
      // que passa a mostrar outra coisa mentiria no cabeçalho.
      reading.customLabel = null;
      if (!Panes.has(panes, reading.id)) _placeBeside(reading, source);
      focusedPaneId = reading.id;
      _save();
      notifyListeners();
      return reading;
    }
    // O lugar dito manda; sem nenhum, o painel de onde o documento saiu. Nos
    // dois casos ele entra ao lado do que está em foco -- onde o leitor
    // *aparece* é uma coisa, de quem ele é é outra.
    final place = folder != null;
    final tab = _newReader(
      doc,
      folder: folder ?? source?.folder ?? focusedFolder,
      cwd: place ? cwd : source?.cwd,
      featureOrHotfix: place ? featureOrHotfix : (source == null ? null : featureOrHotfixOf(source)),
    );
    _placeBeside(tab, source);
    _save();
    notifyListeners();
    return tab;
  }

  /// O plano de uma sessão, aberto pra ler. Sem [note], o da vez.
  MxTab? showPlan(MxTab tab, [PlanNote? note]) {
    final plan = note ?? tab.hooks.plan;
    if (plan == null) {
      showBanner('${tab.title} não apresentou nenhum plano ainda');
      return null;
    }
    final which = tab.hooks.plans.indexOf(plan);
    final versioned = which >= 0 && which < tab.hooks.plans.length - 1
        ? 'plano ${which + 1}/${tab.hooks.plans.length}'
        : 'plano';
    return showDoc(
      MxDoc(
        source: DocSource.plan,
        title: '$versioned de ${tab.title}',
        text: plan.text,
        origin: tab.title,
        at: plan.at,
      ),
      from: tab,
    );
  }

  /// O último recado da sessão, que é markdown e era lido como texto cru.
  MxTab? showMessage(MxTab tab) {
    final said = tab.hooks.lastMessageFull;
    if (said == null || said.trim().isEmpty) {
      showBanner('${tab.title} ainda não disse nada ao terminar um turno');
      return null;
    }
    return showDoc(
      MxDoc(
        source: DocSource.message,
        title: 'recado de ${tab.title}',
        text: said,
        origin: tab.title,
      ),
      from: tab,
    );
  }

  /// Um `.md` do disco. O painel relê sozinho enquanto estiver aberto.
  MxTab? showFile(String path, {MxTab? from, Folder? folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) {
    if (!File(path).existsSync()) {
      showBanner('esse arquivo não está mais lá: $path', sticky: true);
      return null;
    }
    return showDoc(
      MxDoc.file(path, origin: from?.title),
      from: from,
      folder: folder,
      cwd: cwd,
      featureOrHotfix: featureOrHotfix,
    );
  }

  /// Um link, seguido.
  ///
  /// A mesma resposta pros dois lugares em que se clica num link, porque é o
  /// mesmo gesto: o leitor de markdown, que sabe onde os links dele estão, e o
  /// terminal, onde eles são texto como o resto e alguém tem que reconhecê-los
  /// (ver `services/links.dart`). Um `.md` abre no leitor — que é o "por
  /// dentro do maestria" que o app tem —, outro arquivo vai pro Quick Look, e
  /// endereço de fora sai pro navegador: aqui não há onde desenhar uma página.
  ///
  /// [base] é a pasta contra a qual um caminho relativo é resolvido: a do
  /// arquivo que trouxe o link, ou a da sessão que o imprimiu.
  Future<void> followLink(String href, {MxTab? from, String? base}) async {
    if (href.trim().isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      // Página e e-mail são assunto de quem cuida de links: o app escolhido
      // pra cada um deles é o do sistema.
      final ok = await Notifier.openLink(href);
      if (!ok) showBanner('não consegui abrir $href', sticky: true);
      return;
    }
    // Só a parte que é caminho: a âncora depois do # não é um arquivo, e o
    // leitor não tem pra onde rolar até ela.
    final path = href.split('#').first;
    if (path.isEmpty) return;
    final target = resolveLinkPath(path, base: base ?? from?.cwd);
    if (!File(target).existsSync()) {
      showBanner('esse link aponta pra um arquivo que não existe: $target', sticky: true);
      return;
    }
    if (readable(target)) {
      showFile(target, from: from);
      return;
    }
    await Notifier.quickLook(target);
  }

  /// Um markdown escolhido à mão, aberto no leitor.
  ///
  /// A porta que faltava. Tudo o mais aqui abre um documento que o cockpit viu
  /// nascer — o plano veio pelo hook, o `.md` veio da tira de arquivos
  /// alterados, que é o que as ferramentas de escrita anunciaram. Um arquivo
  /// escrito por `cat >`, um de ontem, ou um caminho que a sessão te devolveu
  /// no meio de uma frase não estão em lista nenhuma, e o scrollback não é
  /// clicável: sem isto, a única saída era o Finder.
  ///
  /// Não filtra por extensão de propósito: o painel nativo já só oferece texto,
  /// e um `.txt` que alguém escolheu é um `.txt` que alguém quis ler.
  ///
  /// Quem pede é um *lugar*: o botão direito de uma pasta, de um projeto, de
  /// uma worktree -- ver `openHereItems`. Um markdown mora numa pasta, e era o
  /// menu do painel que oferecia isso: o painel nativo abria na pasta da
  /// sessão em que você clicou, que quase nunca é a do arquivo que se quer
  /// ler. Sem lugar dito -- pelo atalho de teclado -- ainda é o painel em foco
  /// quem diz onde procurar, porque ali não há outro lugar a que se referir.
  Future<void> openMarkdown({Folder? folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) async {
    final tab = folder == null ? focusedTab : null;
    final picked = await Notifier.chooseMarkdown(
      startIn: cwd ?? folder?.root ?? tab?.cwd ?? focusedFolder.root,
    );
    if (picked == null) return;
    showFile(picked, from: tab, folder: folder, cwd: cwd, featureOrHotfix: featureOrHotfix);
  }

  /// O documento que o leitor está mostrando agora, se há um leitor na tela.
  ///
  /// Quem pergunta é a barra de documentos de um painel: com o plano e três
  /// `.md` oferecidos ali, o que ela precisa dizer é qual deles é o que está
  /// aberto -- senão clicar duas vezes na mesma ficha parece não ter feito nada.
  MxDoc? get reading => openPanes.firstWhereOrNull((t) => t.isReader)?.doc;

  /// Se o markdown deste caminho vale um leitor em vez do Quick Look.
  static bool readable(String path) => isMarkdownPath(path);

  MxTab _newReader(MxDoc doc, {required Folder folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: folder,
      kind: TabKind.reader,
      cwd: cwd ?? folder.root,
      branch: '',
      doc: doc,
    );
    if (featureOrHotfix != null && featureOrHotfix.folderRoot == folder.root) tab.featureOrHotfixId = featureOrHotfix.id;
    // Não passa pelo [_register]: não há processo pra subir nem saída de
    // processo pra escutar, e a colocação na tela é outra (ao lado, não em
    // cima).
    tabs.add(tab);
    return tab;
  }

  MxTab _newSetup(MxSetup setup, {required Folder folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: folder,
      kind: TabKind.setup,
      cwd: cwd ?? folder.root,
      branch: '',
      setup: setup,
    );
    if (featureOrHotfix != null && featureOrHotfix.folderRoot == folder.root) tab.featureOrHotfixId = featureOrHotfix.id;
    // Fora do [_register] pelo mesmo motivo do leitor: não há processo pra
    // subir nem saída de processo pra escutar.
    tabs.add(tab);
    return tab;
  }

  // --- painéis de configuração --------------------------------------------

  /// Os arquivos que o Claude Code lê em [folder], num painel que os edita.
  /// Ver [TabKind.setup].
  ///
  /// Um por raiz, e não um só como o leitor: a configuração de um repo e a
  /// de outro não são o mesmo lugar -- clicar na segunda com a primeira aberta
  /// não pode trocar o que você estava editando na primeira. A da mesma raiz,
  /// sim, é a mesma: pedir de novo traz a que já existe de volta pra tela.
  ///
  /// [cwd] é a raiz quando ela não é a da pasta -- o checkout de uma
  /// worktree, que tem o `CLAUDE.md` versionado igual e um `settings.local`
  /// só dele.
  MxTab showSetup({required Folder folder, String? cwd, FeatureOrHotfix? featureOrHotfix}) {
    final root = cwd ?? folder.root;
    final open = tabs.firstWhereOrNull((t) => t.isSetup && t.setup!.root == root);
    if (open != null) {
      if (!Panes.has(panes, open.id)) _placeBeside(open, focusedTab);
      focusedPaneId = open.id;
      _save();
      notifyListeners();
      return open;
    }
    final tab = _newSetup(
      MxSetup(root: root),
      folder: folder,
      cwd: cwd,
      featureOrHotfix: featureOrHotfix,
    );
    // Ao lado do que está em foco: quem abre a configuração de uma pasta
    // quer olhar pra ela junto da sessão que está rodando ali.
    _placeBeside(tab, focusedTab);
    _save();
    notifyListeners();
    return tab;
  }

  /// Encaixa [tab] à direita do painel de [beside], quando há um na tela.
  ///
  /// Ao lado de um preso é ao lado de um solto: encaixar corta o painel ao
  /// meio, e o preso é justamente o que não pode perder o lugar nem o tamanho.
  /// Sem solto nenhum na tela, é o [_place] que decide.
  void _placeBeside(MxTab tab, MxTab? beside) {
    if (beside != null && isPinned(beside)) {
      beside = openPanes.firstWhereOrNull((t) => !isPinned(t));
    }
    if (panes == null || beside == null || !Panes.has(panes, beside.id)) {
      _place(tab);
      return;
    }
    panes = Panes.insert(panes!, tabId: tab.id, targetId: beside.id, side: DropSide.right);
    focusedPaneId = tab.id;
  }

  // --- plugins ------------------------------------------------------------

  MxTab? _pluginTab(String pluginId, String viewId) =>
      tabs.firstWhereOrNull((t) => t.view?.pluginId == pluginId && t.view?.id == viewId);

  /// A janela [viewId] do plugin, aberta ao lado do painel em foco.
  ///
  /// Uma por id, como a configuração é uma por pasta: pedir de novo a que já
  /// existe troca o conteúdo dela e a traz pra tela, em vez de empilhar uma
  /// segunda igual. É o que deixa um plugin chamar `view.open` toda vez que o
  /// comando dele roda, sem ter que lembrar se ela ainda está aberta.
  MxTab openPluginView(
    MxPlugin plugin,
    String viewId, {
    required String title,
    required List<Map<String, dynamic>> blocks,
    PluginRfwUpdate? rfw,
  }) {
    final source = focusedTab;
    if (_pluginTab(plugin.id, viewId) case final open?) {
      open.view!
        ..title = title
        ..setBlocks(blocks);
      if (rfw != null) open.view!.setRfw(library: rfw.library, root: rfw.root, data: rfw.data);
      if (!Panes.has(panes, open.id)) _placeBeside(open, source);
      focusedPaneId = open.id;
      notifyListeners();
      return open;
    }
    // Da bandeja solta, e não da pasta do painel em foco: a janela não é
    // daquela pasta (ver [tabsOf]), e herdar a cor ou o projeto dela diria
    // que é.
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: loose,
      kind: TabKind.plugin,
      cwd: loose.root,
      branch: '',
      view: PluginView(
        pluginId: plugin.id,
        pluginName: plugin.name,
        id: viewId,
        title: title,
        blocks: blocks,
      ),
    );
    if (rfw != null) tab.view!.setRfw(library: rfw.library, root: rfw.root, data: rfw.data);
    // Fora do [_register], como o leitor: não há processo pra subir.
    tabs.add(tab);
    _placeBeside(tab, source);
    notifyListeners();
    return tab;
  }

  /// Troca o título e/ou os blocos de uma janela aberta. Diz se ela ainda
  /// está aberta -- o plugin cuja janela você fechou fica sabendo por aqui.
  bool updatePluginView(
    MxPlugin plugin,
    String viewId, {
    String? title,
    List<Map<String, dynamic>>? blocks,
    PluginRfwUpdate? rfw,
  }) {
    final tab = _pluginTab(plugin.id, viewId);
    if (tab == null) return false;
    final view = tab.view!;
    if (title != null) view.title = title;
    if (rfw != null) view.setRfw(library: rfw.library, root: rfw.root, data: rfw.data);
    if (blocks != null) {
      view
        ..rfwLibrary = null
        ..setBlocks(blocks);
    }
    notifyListeners();
    return true;
  }

  /// O console [consoleId] da janela [viewId], quando ela está aberta. Mexer
  /// nele não repinta a janela -- ver [PluginConsole].
  PluginConsole? pluginConsole(MxPlugin plugin, String viewId, String consoleId) =>
      (viewId == sidebarViewId ? _sidebarTabs[plugin.id] : _pluginTab(plugin.id, viewId))?.view!
          .console(consoleId);

  void closePluginView(MxPlugin plugin, String viewId) {
    if (_pluginTab(plugin.id, viewId) case final tab?) closeTab(tab);
  }

  void _closePluginViewsOf(String pluginId) {
    for (final t in tabs.where((t) => t.view?.pluginId == pluginId).toList()) {
      closeTab(t);
    }
    floats.dropPlugin(pluginId);
  }

  /// Um clique ou envio dentro de uma janela de plugin, de volta pra ele.
  void pluginViewAction(MxTab tab, String action, Map<String, dynamic> values) {
    final view = tab.view;
    if (view == null) return;
    plugins.viewAction(view.pluginId, view.id, action, values);
  }

  /// Roda o comando de um plugin a partir de [on] -- o painel do menu que o
  /// ofereceu, ou o que está em foco.
  Future<void> runPluginCommand(PluginCommand command, {MxTab? on}) async {
    final tab = on ?? focusedTab;
    final folder = tab?.folder ?? focusedFolder;
    final cwd = tab?.cwd ?? folder.root;
    final plugin = plugins.byId(command.pluginId);
    final values = {
      'cwd': cwd,
      'folder': folder.root,
      'sessionId': tab?.resumeId ?? '',
      'title': tab?.title ?? '',
      'pluginDir': plugin?.dir ?? '',
    };
    switch (command.target) {
      case CommandTarget.terminal:
        openShell(
          folder,
          cwd: cwd,
          command: expandCommand(command.run!, values, quote: true),
          featureOrHotfix: tab == null ? null : featureOrHotfixOf(tab),
        );
      case CommandTarget.background:
        final r = await Sh.run(expandCommand(command.run!, values, quote: true), cwd: cwd);
        final said = (r.ok ? r.stdout : (r.stderr.isEmpty ? r.stdout : r.stderr))
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .lastOrNull;
        showBanner(
          r.ok
              ? '${command.title}: ${said ?? 'feito'}'
              : '${command.title} falhou (código ${r.code})${said == null ? '' : ': $said'}',
          sticky: !r.ok,
        );
      case CommandTarget.session:
        if (tab == null || tab.kind != TabKind.claude || tab.exited || tab.hibernated) {
          showBanner('${command.title}: precisa de uma sessão do claude rodando em foco');
          return;
        }
        await tab.term.submit(expandCommand(command.send!, values, quote: false));
      case CommandTarget.plugin:
        try {
          await plugins.invoke(command, {...values, if (tab != null) 'tabId': tab.id});
        } on PluginRpcError catch (e) {
          showBanner('${command.title}: ${e.message}', sticky: true);
        }
    }
  }

  /// Troca `${cwd}`, `${folder}`, `${sessionId}`, `${title}` e `${pluginDir}`
  /// pelos valores do painel. Num comando de shell cada valor vai entre aspas
  /// -- um título com espaço ou uma pasta com `$` não podem virar outro
  /// comando. Num texto pra sessão vai cru.
  @visibleForTesting
  static String expandCommand(String template, Map<String, String> values, {required bool quote}) =>
      template.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) {
        final v = values[m.group(1)];
        if (v == null) return m.group(0)!;
        return quote ? Sh.q(v) : v;
      });

  /// Liga ou desliga um plugin. Desligado, as janelas dele fecham: não há
  /// mais ninguém do outro lado pra atender um clique.
  Future<void> setPluginEnabled(MxPlugin plugin, bool on) async {
    await plugins.setEnabled(plugin, on);
    if (!on) _closePluginViewsOf(plugin.id);
    // O tema em uso pode ter sido dele: [MxThemes.byId] cai no padrão.
    if (!on) Mx.applyId(Mx.palette.id);
    _save();
    notifyListeners();
  }

  Future<void> uninstallPlugin(MxPlugin plugin) async {
    _closePluginViewsOf(plugin.id);
    await plugins.uninstall(plugin);
    Mx.applyId(Mx.palette.id);
    _save();
    notifyListeners();
  }

  /// Uma configuração de plugin, trocada na tela e guardada no config.
  void setPluginSetting(MxPlugin plugin, String id, Object? value) {
    plugins.setSetting(plugin, id, value);
    _save();
    notifyListeners();
  }

  Future<MxPlugin> installPlugin(StagedPlugin staged) async {
    final plugin = await plugins.commit(staged);
    // Uma versão nova pode ter trocado as janelas; as antigas eram do
    // processo que acabou de cair.
    _closePluginViewsOf(plugin.id);
    _save();
    notifyListeners();
    return plugin;
  }

  /// The manual worktree dance, as one button.
  Future<MxTab?> newTask(
    Folder p, {
    required String taskId,
    required String branchPattern,
    required String dirPattern,
    String? baseRef,
    String? setupCommand,
    FeatureOrHotfix? featureOrHotfix,
  }) async {
    final base = baseRef ?? await Git.defaultRemoteRef(p.root) ?? 'origin/master';
    final branch = branchPattern.replaceAll('{id}', taskId);
    final dir = dirPattern.replaceAll('{id}', taskId).replaceAll('#', '-');

    final outcome = await Git.addWorktree(
      root: p.root,
      dirName: dir,
      branch: branch,
      baseRef: base,
    );
    showBanner(outcome.message, sticky: !outcome.ok);
    if (!outcome.ok) return null;

    if (setupCommand != null && setupCommand.trim().isNotEmpty) {
      final shell = openShell(p, cwd: outcome.path, command: setupCommand.trim(), featureOrHotfix: featureOrHotfix);
      shell.customLabel = '$taskId setup';
    }

    await refreshGit();
    return openClaude(p, cwd: outcome.path, label: taskId, featureOrHotfix: featureOrHotfix);
  }

  // --- worktrees ----------------------------------------------------------

  /// The panel already running in [path], if any. A worktree with a live
  /// session is one you go back to, not one you open twice.
  MxTab? tabAt(String path) => tabs.firstWhereOrNull((t) => t.cwd == path && !t.exited);

  /// O que abrir no vscode quando o alvo é uma pasta da lateral: o workspace
  /// Uma pasta -- ou o `.code-workspace` de uma, que é um arquivo.
  ///
  /// Só o caminho: havia um `openFolderInEditor` que, dada uma pasta importada
  /// de um workspace, abria o arranjo inteiro em vez do terço dela. Ele tinha
  /// uma porta só -- a linha 'abrir no vscode' do menu da pasta --, e a linha
  /// saiu do menu. Ver [Workspace.codeWorkspacePath], que é o que sobrou do
  /// assunto.
  Future<void> openInEditor(String path) async {
    if (!Directory(path).existsSync() && !File(path).existsSync()) {
      showBanner(
        CodeWorkspace.looksLikeOne(path)
            ? 'esse workspace não está mais lá: $path'
            : 'essa pasta não existe mais: $path',
        sticky: true,
      );
      return;
    }
    final ok = await Editor.open(path);
    showBanner(
      ok
          ? 'aberto no vscode: ${path.split('/').last}'
          : 'não achei o vscode — nem o `code` no PATH, nem o app',
      sticky: !ok,
    );
  }

  /// Delete a worktree, once its own panels are out of the way.
  ///
  /// Removing the folder under a running session leaves that pty pointing at
  /// nothing, so the panels come first -- and closing someone's session for
  /// them is not this button's call to make.
  Future<void> removeWorktree(
    Folder p,
    WorktreeInfo w, {
    bool force = false,
    bool deleteBranch = false,
  }) async {
    if (tabAt(w.path) != null) {
      showBanner('feche o painel que está nessa worktree antes de excluí-la', sticky: true);
      return;
    }
    final outcome = await Git.removeWorktree(
      root: p.root,
      worktree: w,
      force: force,
      deleteBranch: deleteBranch,
    );
    showBanner(outcome.message, sticky: !outcome.ok);
    await refreshGit();
  }

  Future<void> pruneWorktrees(Folder p) async {
    final outcome = await Git.prune(p.root);
    showBanner(outcome.message, sticky: !outcome.ok);
    await refreshGit();
  }

  /// O que dizer quando uma sessão morre nos primeiros segundos.
  ///
  /// O 127 ganha nome próprio porque é o modo de falha mais provável de uma
  /// instalação nova, e o número não diz nada a quem só queria abrir uma
  /// sessão: é o "command not found" do shell, quase sempre um `claude` que
  /// está no PATH do terminal e não no que o app herda. [Sh.env] já cobre as
  /// pastas usuais; o que sobra depende de onde o binário foi instalado, e aí
  /// só o dono da máquina resolve -- então a receita vem junto.
  @visibleForTesting
  static String earlyExitMessage(String title, int? code) => code == 127
      ? '$title: não achei o `claude` no PATH do app — instale-o, ou ponha a '
            'pasta do binário no ${Sh.profileFile} (o rc do shell interativo o '
            'app não lê)'
      : '$title: o claude saiu na largada (código ${code ?? '?'}) '
            '— abra o painel pra ver o motivo';

  void _register(MxTab tab, {bool place = true}) {
    tabs.add(tab);
    plugins.emit(
      'session.opened',
      {'tabId': tab.id, 'kind': tab.kind.name, 'cwd': tab.cwd, 'folder': tab.folder.root},
      activations: ['onSession'],
    );
    // A new panel lands in whichever pane you were looking at -- unless it
    // lives inside a plugin window (see [MxTab.embedded]).
    if (place) _place(tab);
    tab.term.onExit = () {
      // Dying in the first seconds is not the same as being closed: it means
      // the launch itself failed, and the reason is sitting in that panel's
      // own buffer.
      final alive = DateTime.now().difference(tab.startedAt);
      if (tab.kind == TabKind.claude && alive.inSeconds < 5) {
        showBanner(earlyExitMessage(tab.title, tab.term.exitCode), sticky: true);
      }
      // O processo saiu e o painel ficou: o ssh que caiu é a linha que o
      // plugin pinta de vermelho.
      plugins.emit(
        'session.exited',
        {'tabId': tab.id, 'code': tab.term.exitCode},
        activations: ['onSession'],
      );
      _save();
      notifyListeners();
    };
    _save();
    notifyListeners();
  }

  /// Põe [tab] na tela -- o clique numa linha da lateral.
  ///
  /// Quando a tela *é* um grupo (ver [activeGroup]), escolher uma sessão que
  /// não é dele não troca um quadro da grade: a grade sai inteira e a sessão
  /// escolhida fica com a tela. É o "se eu clicar em outro painel que não está
  /// no grupo, ele substitui o grupo inteiro por esse".
  ///
  /// Fora de um grupo continua valendo o que [_place] documenta -- trocar o
  /// que está no lugar em foco. A distinção é o ponto: uma grade que você
  /// montou à mão e não agrupou é sua, e um clique numa quarta sessão não pode
  /// desmanchá-la sem você ter pedido; uma grade que é um grupo tem pra onde
  /// voltar, porque está guardada.
  void select(MxTab tab) {
    // O embutido não tem painel: quem vai pra tela é a janela que o desenha.
    if (tab.embedded) return;
    // O clique numa hibernada é o "retomar" -- ver [MxTab.hibernated].
    if (tab.hibernated) unawaited(wake(tab));
    final group = activeGroup;
    // Um painel preso segura a grade: trocar o grupo inteiro levaria junto
    // o painel que você prendeu justamente pra ele ficar.
    if (group != null && tab.groupId != group.id && !openPanes.any(isPinned)) {
      panes = PaneLeaf(tab.id);
      focusedPaneId = tab.id;
    } else {
      _place(tab);
    }
    _save();
    notifyListeners();
  }

  /// Põe [tab] na tela, sem salvar nem repintar -- o miolo que [select] e
  /// [_register] embrulham cada um do seu jeito.
  ///
  /// Um painel é um lugar, não uma sessão: escolher outra sessão na lateral
  /// troca o que está no lugar em foco em vez de abrir mais um. Abrir lugar é
  /// arrastar -- é o único gesto que divide a tela, e é assim de propósito:
  /// clicar numa lista de vinte sessões não pode ir picando a janela.
  ///
  /// O lugar em foco, a menos que ele esteja preso (ver [MxTab.pinned]): aí é
  /// o primeiro solto da tela. Com todos presos não há lugar pra trocar, e a
  /// sessão abre um novo -- prender tudo é dizer que nada daquilo sai. Esse
  /// lugar novo é o que o último solto deixou (ver [_hole]), ou a borda
  /// direita da tela: nunca a metade de um preso.
  void _place(MxTab tab) {
    if (panes == null) {
      panes = PaneLeaf(tab.id);
    } else if (!Panes.has(panes, tab.id)) {
      final focused = focusedTab;
      final loose = focused != null && !isPinned(focused)
          ? focused.id
          : openPanes.firstWhereOrNull((t) => !isPinned(t))?.id;
      if (loose != null) {
        Panes.swap(panes, loose, tab.id);
      } else if (!_fillHole(tab.id)) {
        panes = Panes.edge(panes!, tabId: tab.id, side: DropSide.right);
      }
    }
    focusedPaneId = tab.id;
  }

  /// A tela de antes de o último painel solto sair, e quem saiu.
  ///
  /// É o que segura os presos no lugar. Com a direita inteira presa, tirar o
  /// da esquerda faz a árvore desabar e os presos tomarem a tela -- e o
  /// clique seguinte, sem solto pra trocar, abriria a sessão numa borda
  /// qualquer, empurrando os presos pra onde eles nunca estiveram. Com isto o
  /// clique reabre o buraco onde ele estava, do tamanho que tinha.
  ({PaneNode tree, String id})? _hole;

  /// Reabre o [_hole] com [tabId] dentro, se a tela ainda é a que ficou
  /// quando ele se fechou. Qualquer outra mudança no meio -- um arraste, um
  /// painel a mais, um grupo -- já é outra tela, e o buraco antigo não é mais
  /// um lugar dela.
  bool _fillHole(String tabId) {
    final hole = _hole;
    _hole = null;
    if (hole == null) return false;
    if (!Panes.sameShape(Panes.remove(Panes.copy(hole.tree), hole.id), panes)) return false;
    Panes.swap(hole.tree, hole.id, tabId);
    panes = hole.tree;
    return true;
  }

  /// Tira a folha da árvore e reencosta o foco em quem ficou no lugar dela.
  void _drop(MxTab tab) {
    // Um solto que sai de perto de presos deixa o lugar marcado: ver [_hole].
    final loose = Panes.has(panes, tab.id) && !isPinned(tab);
    final tree = loose ? Panes.copy(panes) : null;
    final before = Panes.order(panes);
    final at = before.indexOf(tab.id);
    panes = Panes.remove(panes, tab.id);
    if (tree != null && openPanes.any(isPinned)) _hole = (tree: tree, id: tab.id);
    if (focusedPaneId != tab.id) return;
    final left = Panes.order(panes);
    focusedPaneId = left.isEmpty ? null : left[at.clamp(0, left.length - 1)];
  }

  /// Tira o painel da tela sem encerrar nada.
  ///
  /// O X do header é isto, e [closeTab] é outra coisa. Uma sessão que saiu do
  /// painel continua na lateral com o processo, o scrollback e a fila que
  /// tinha -- ela só parou de ocupar a tela. Era o que faltava: o gesto mais
  /// à mão do header era o único que matava a conversa, então "chega de olhar
  /// pra isso" custava a sessão.
  void dismiss(MxTab tab) {
    if (!Panes.has(panes, tab.id)) return;
    // O espaço não fica vago: o corte em volta desaba e os painéis vizinhos
    // tomam conta do que sobrou, que é o que "fechar um dos quatro" quer
    // dizer numa grade.
    _drop(tab);
    _save();
    notifyListeners();
  }

  /// Encerra: mata o processo e apaga o painel da lateral. Para só limpar a
  /// tela, [dismiss].
  void closeTab(MxTab tab) {
    // A janela de um plugin leva junto os terminais embutidos que ela desenhava:
    // sem a janela eles não têm onde aparecer. Ver [MxTab.embedded].
    if (tab.view case final view?) {
      for (final id in _embeddedIn(view.blocks)) {
        final inner = tabs.firstWhereOrNull(
          (t) => t.id == id && t.embedded && t.owner == view.pluginId,
        );
        if (inner != null) closeTab(inner);
      }
    }
    tab.armed = false;
    if (!tab.isPassive) {
      plugins.emit('session.closed', {'tabId': tab.id}, activations: ['onSession']);
    }
    // Sem await de propósito: [TermSession.kill] espera o hangup ser atendido
    // antes de escalar, e a tela não tem nada a ganhar parada esperando por
    // isso. O painel sai da lateral agora; o processo termina de morrer
    // sozinho, com quem ele subiu junto.
    unawaited(tab.term.kill());
    tabs.remove(tab);
    _drop(tab);
    // Encerrar o último painel com sessões vivas na lateral deixaria a tela
    // limpa no meio do trabalho: quando não sobra painel nenhum, a última
    // sessão aberta ocupa o lugar.
    if (panes == null) {
      if (tabs.lastWhereOrNull((t) => !t.embedded) case final next?) _place(next);
    }
    _save();
    notifyListeners();
  }

  /// Os `tabId` dos blocos `terminal` de uma janela de plugin, inclusive os de
  /// dentro de um `card`, de um `columns` ou de uma fileira.
  static Iterable<String> _embeddedIn(List<Map<String, dynamic>> blocks) sync* {
    for (final b in blocks) {
      if (b['type'] == 'terminal' && b['tabId'] is String) yield b['tabId'] as String;
      if (b['children'] != null) yield* _embeddedIn(PluginView.blocksFrom(b['children']));
    }
  }

  void closeFocused() {
    final tab = focusedTab;
    if (tab != null) closeTab(tab);
  }

  /// Fecha de uma vez o que você declarou resolvido: os concluídos, e só.
  ///
  /// [MxTab.done] sozinho nunca fecha nada -- marcar é um juízo, não um
  /// descarte, e o painel fica com o scrollback e a sessão pra reler ou
  /// retomar. Mas quando você pede a varrida, está dizendo justamente que
  /// terminou com essa leva; deixar de fora os concluídos obrigaria a fechar
  /// um por um exatamente os painéis que você já declarou resolvidos.
  ///
  /// O painel encerrado já foi junto e não vai mais. Ele empilha rápido, o que
  /// era o argumento -- mas um processo que saiu não é um trabalho acabado, é
  /// um `q` apertado sem querer ou um comando que morreu, e desde que o
  /// cabeçalho ganhou o botão de subir de novo ([relaunch]) ele é justamente
  /// um painel *esperando* pra rodar outra vez. Varrer isso é uma vassoura que
  /// leva o que você ia usar. Fechar continua a um clique no x da linha.
  ///
  /// Devolve quantos fechou, pro chamador poder dizer o que a varrida levou.
  int closeSettled(Folder p) {
    final settled = tabsOf(p).where((t) => t.done).toList();
    for (final t in settled) {
      closeTab(t);
    }
    return settled.length;
  }

  /// Quantos painéis de [p] a varrida levaria: é o que decide se o "limpar"
  /// da régua tem o que fazer. Ver [closeSettled].
  int settledIn(Folder p) => tabsOf(p).where((t) => t.done).length;

  void renameTab(MxTab tab, String label) {
    tab.customLabel = label;
    _save();
    notifyListeners();
  }

  /// A cor deste painel, ou null pra tirar a que ele tinha. Ver [MxTint].
  ///
  /// Vizinha do [renameTab] porque é o mesmo gesto: dar nome e dar cor são as
  /// duas coisas que a pessoa diz sobre um painel, e as duas têm que
  /// atravessar o fechamento da janela -- daí o [_save].
  void setTabTint(MxTab tab, MxTint? tint) {
    tab.tint = tint;
    _save();
    notifyListeners();
  }

  /// Mark a session as having done its job, or take the mark back.
  ///
  /// Deliberately not a close. Closing says "I am done with this panel" and
  /// takes the conversation with it; this says "this one worked", which is
  /// something you want to be able to say about a session you are keeping --
  /// to reread, to resume, to point the next one at. What it buys is quiet:
  /// see [MxTab.done], [needingHuman] and [_checkAlerts].
  ///
  /// Returns how many queued steps went with it. Marking drops the queue,
  /// because a follow-up firing into a session you just called finished would
  /// be the app arguing with you -- and it is the one thing here you cannot
  /// see, so the caller is handed the number to say out loud.
  int setDone(MxTab tab, bool done) {
    if (tab.done == done) return 0;
    tab.done = done;
    var dropped = 0;
    if (done) {
      tab.armed = false;
      dropped = tab.followUps.length;
      tab.followUps.clear();
    }
    _save();
    notifyListeners();
    return dropped;
  }

  /// Drop [tab] onto [target]'s place in the list, sliding the rest along.
  ///
  /// The list is one list while the sidebar draws it per folder, so a
  /// folder's panels are a subsequence of it and not a slice. Landing the
  /// panel on the target's index leaves every other panel's relative order
  /// untouched -- and with it the ⌘1..9 numbering, which is this same list
  /// counted from the top, and the saved layout, which is its order on disk.
  void moveTab(MxTab tab, MxTab target) {
    final from = tabs.indexOf(tab);
    final to = tabs.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    // After the removal the target sits at `to - 1` when the panel came from
    // above and at `to` when it came from below -- which is exactly the index
    // that puts the panel after it in the first case and before it in the
    // second. Both are the slot you dropped it on.
    tabs.removeAt(from);
    tabs.insert(to, tab);
    // Dropped among another project's panels, it joins that project: the list
    // it landed in is the answer to which job it is part of.
    tab.featureOrHotfixId = target.featureOrHotfixId;
    _save();
    notifyListeners();
  }

  // --- grupos de painéis --------------------------------------------------

  /// Se a régua dos grupos está dobrada, escondendo as linhas dela.
  ///
  /// Mora aqui e não numa [Folder] porque a bandeja dos grupos não é pasta
  /// nenhuma -- ver [PaneGroup] --, e é lembrada pelo mesmo motivo que
  /// [sidebarWidth]: é uma escolha de como a janela fica arrumada, e quem a
  /// fez uma vez a fez pra valer.
  bool groupsCollapsed = false;

  void toggleGroupsCollapsed() {
    groupsCollapsed = !groupsCollapsed;
    _save();
    notifyListeners();
  }

  /// Guarda o arranjo que está na tela como um grupo chamado [name]. Ver
  /// [PaneGroup].
  ///
  /// A tela é a fonte, e não uma lista de painéis pra marcar: "salvar um
  /// grupo" é arrumar a grade do jeito que ela serve e dizer que é assim que
  /// ela abre. Salvar com o nome de um grupo que já existe atualiza aquele
  /// grupo em vez de criar um homônimo -- dois "grid da manhã" na lateral
  /// seriam duas linhas iguais e nenhuma forma de saber qual é qual.
  ///
  /// Null com a tela limpa ou sem nome: não há arranjo pra guardar.
  PaneGroup? saveGroup(String name) {
    final title = name.trim();
    final open = openPanes;
    if (title.isEmpty || open.isEmpty) return null;
    final at = groups.indexWhere((g) => g.name.toLowerCase() == title.toLowerCase());
    final group = PaneGroup(
      // Numa atualização, o id do grupo que estava ali: é o mesmo grupo, com
      // outro arranjo dentro. Ver [addFeatureOrHotfix] pro formato.
      id: at < 0 ? 'gp${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}' : groups[at].id,
      name: title,
      panes: [for (final t in open) t.recipe],
      // O mesmo json que o layout salvo leva, e com as folhas apontando pra
      // lista que acabou de ser escrita: quem remonta a árvore, dos dois
      // lados, é o `Panes.fromJson`.
      tree: Panes.toJson(panes, (id) => open.indexWhere((t) => t.id == id)),
    );
    if (at < 0) {
      groups.add(group);
    } else {
      groups[at] = group;
    }
    _stamp(group, open);
    _save();
    notifyListeners();
    return group;
  }

  /// Agrupa os painéis que estão na tela -- o "agrupar painéis" do botão
  /// direito de um painel.
  ///
  /// Não pede nome: o gesto é apontar pra grade que já está montada e dizer
  /// que aqueles painéis andam juntos, e um diálogo no meio disso cobraria uma
  /// decisão que ninguém tinha pra tomar. O nome sai do que o grupo abre ("3
  /// terminais"), com um número atrás quando já existe um assim -- e trocar
  /// por um nome de gente é o "renomear" do menu do grupo.
  ///
  /// Null com menos de dois painéis na tela: um painel sozinho não é grade.
  PaneGroup? groupPanes() {
    final open = openPanes;
    if (open.length < 2) return null;
    final base = PaneGroup.summarize([for (final t in open) t.recipe]);
    // Nome novo e não o de um grupo existente: cair no nome de outro faria
    // [saveGroup] atualizar aquele grupo em vez de criar este.
    var name = base;
    for (var n = 2; groups.any((g) => g.name.toLowerCase() == name.toLowerCase()); n++) {
      name = '$base ($n)';
    }
    return saveGroup(name);
  }

  /// Desfaz o grupo. Os painéis continuam abertos e onde estavam: o que se
  /// desfaz é o laço entre eles, não o arranjo na tela.
  void ungroup(PaneGroup group) {
    _stamp(group, const []);
    groups.remove(group);
    _save();
    notifyListeners();
  }

  /// Marca [members] como os painéis de [group] -- e desmarca quem tinha a
  /// marca e não está mais na lista.
  ///
  /// Sempre pelo grupo inteiro, nunca painel por painel, porque é isso que a
  /// marca quer dizer: um grupo atualizado com dois painéis não pode deixar o
  /// terceiro colorido de um conjunto de que ele saiu.
  void _stamp(PaneGroup group, List<MxTab> members) {
    for (final t in tabs) {
      if (t.groupId == group.id && !members.contains(t)) t.groupId = null;
    }
    for (final t in members) {
      t.groupId = group.id;
    }
  }

  PaneGroup? groupById(String? id) =>
      id == null ? null : groups.firstWhereOrNull((g) => g.id == id);

  // --- programas ----------------------------------------------------------

  Launcher? launcherById(String? id) =>
      id == null ? null : launchers.firstWhereOrNull((l) => l.id == id);

  /// Ensina um programa novo e devolve ele -- é quem chamou que decide se abre
  /// um painel com ele em seguida.
  Launcher addLauncher({
    required String name,
    required String command,
    LauncherIcon icon = LauncherIcon.terminal,
  }) {
    final launcher = Launcher(
      // Do relógio e não do tamanho da lista: apagar dois e criar um terceiro
      // daria a ele o id de um painel salvo que apontava pro primeiro.
      id: 'lch${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      command: command.trim(),
      icon: icon,
    );
    launchers.add(launcher);
    _save();
    notifyListeners();
    return launcher;
  }

  /// Muda o que já existe, no lugar. Os painéis abertos seguram o programa por
  /// referência, então renomear já renomeia o cabeçalho deles -- e o comando
  /// novo é o que o próximo [relaunch] roda.
  void editLauncher(Launcher launcher, {String? name, String? command, LauncherIcon? icon}) {
    final title = name?.trim();
    final run = command?.trim();
    if (title != null && title.isNotEmpty) launcher.name = title;
    if (run != null && run.isNotEmpty) launcher.command = run;
    if (icon != null) launcher.icon = icon;
    _save();
    notifyListeners();
  }

  /// Esquece o programa. Não fecha nada: os painéis dele viram os terminais
  /// que sempre foram por baixo, com o que estiver rodando dentro deles.
  void removeLauncher(Launcher launcher) {
    launchers.remove(launcher);
    for (final t in tabs.where((t) => t.launcher == launcher)) {
      t.launcher = null;
    }
    _save();
    notifyListeners();
  }

  /// Sobe de novo, no mesmo painel, o programa que já tinha saído.
  ///
  /// Um painel de programa é o programa: sair do `btop` deixa uma moldura com
  /// "processo saiu (0)" onde antes havia um monitor, e a resposta pra isso
  /// não é fechar o painel e refazer o caminho do menu. Só depois da saída --
  /// matar um processo vivo pra rodar o mesmo comando seria outro gesto, e um
  /// que ninguém pediu.
  void relaunch(MxTab tab) {
    final command = tab.launcher?.command;
    if (command == null || !tab.exited) return;
    tab.term.relaunch(command, tab.cwd);
    notifyListeners();
  }

  // --- hibernação -----------------------------------------------------------

  /// Depois de quanto tempo parada fora da tela uma sessão hiberna sozinha.
  /// Zero é nunca. Ver [hibernateIdle].
  int hibernateMinutes = defaultHibernateMinutes;

  static const defaultHibernateMinutes = 30;

  /// A hibernação automática está ligada.
  bool get autoHibernate => hibernateMinutes > 0;

  void setHibernateMinutes(int minutes) {
    final value = minutes.clamp(0, 24 * 60);
    if (value == hibernateMinutes) return;
    hibernateMinutes = value;
    _save();
    notifyListeners();
  }

  /// Dá pra hibernar: uma sessão do claude, com processo, com conversa pra
  /// retomar. Ver [MxTab.hibernated].
  bool canHibernate(MxTab tab) =>
      tab.kind == TabKind.claude && !tab.exited && !tab.hibernated && tab.resumeId != null;

  /// Desliga o processo de [tab] e fica com a conversa. Ver [MxTab.hibernated].
  ///
  /// O que se perde é o que estava *dentro* do processo: os servidores MCP
  /// dele, e um `npm run dev` que uma ferramenta tenha deixado rodando -- o
  /// hangup vai pro grupo inteiro (ver [TermSession.kill]). O que fica é o que
  /// o `--resume` devolve, que é a conversa.
  void hibernate(MxTab tab) {
    if (!canHibernate(tab)) return;
    tab.hibernated = true;
    tab.armed = false;
    tab.restedAt = null;
    tab.unseen = false;
    tab.hooks.status = ClaudeStatus.ended;
    tab.hooks.activeTool = null;
    tab.hooks.toolStartedAt = null;
    tab.term.remark(
      'hibernada — processo desligado pra liberar memória; a conversa volta com um clique',
    );
    // Sem await, como em [closeTab]: o hangup é atendido no tempo dele e a
    // linha já pode dizer o que aconteceu. Sem pty não há o que desligar --
    // é o painel que ainda não subiu --, e aí basta declará-lo desligado.
    if (tab.term.pid == null) {
      tab.term.park();
    } else {
      unawaited(tab.term.kill());
    }
    _save();
    notifyListeners();
  }

  /// Religa uma sessão hibernada, na mesma conversa. Ver [MxTab.hibernated].
  ///
  /// Espera o processo anterior morrer de verdade antes de subir o próximo:
  /// [hibernate] não espera, e um clique logo depois dela chegaria aqui com
  /// o hangup ainda em curso -- dois processos no mesmo pty, com o `exitCode`
  /// do primeiro chegando depois do segundo subir. Ver [TermSession.relaunch].
  Future<void> wake(MxTab tab) async {
    if (!tab.hibernated) return;
    tab.hibernated = false;
    tab.hooks.status = ClaudeStatus.starting;
    notifyListeners();
    if (!tab.exited) await tab.term.kill();
    if (!tabs.contains(tab)) return;
    tab.term.terminal.write('\r\n');
    _launchClaude(tab, resumeId: tab.resumeId);
    _save();
    notifyListeners();
  }

  /// Hiberna o que está parado, fora da tela, há [hibernateMinutes] ou mais.
  /// O relógio de um segundo de [init] é quem chama.
  ///
  /// Parada é o prompt esperando -- [ClaudeStatus.ready], que é a sessão
  /// restaurada que ninguém tocou desde o launch, e as duas de
  /// [ClaudeStatusUi.atRest]. Fora da tela porque desligar o que você está
  /// olhando é o app fazendo coisa nas suas costas; e de fora ficam a que tem
  /// pendência com você, a que tem fila pra andar, a que espera agentes e a
  /// que outra fila vai chamar -- hibernar essa quebraria o fluxo no meio.
  ///
  /// [now] é pro teste, que não tem meia hora.
  @visibleForTesting
  void hibernateIdle({DateTime? now}) {
    if (!autoHibernate) return;
    final at = now ?? DateTime.now();
    final patience = Duration(minutes: hibernateMinutes);
    var changed = false;
    for (final tab in [...tabs]) {
      if (!canHibernate(tab) || isOpen(tab)) continue;
      final status = tab.status;
      if (status != ClaudeStatus.ready && !status.atRest) continue;
      if (tab.armed || tab.followUps.isNotEmpty || tab.hooks.busyForks) continue;
      if (tabs.any((t) => t.followUps.any((s) => s.targetTabId == tab.id))) continue;
      // Desde quando ela está parada: a virada pra repouso, senão o último
      // sinal dela, senão o launch.
      final since = tab.restedAt ?? tab.hooks.lastEventAt ?? tab.startedAt;
      if (at.difference(since) < patience) continue;
      hibernate(tab);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// O grupo de que este painel faz parte, se faz de algum.
  PaneGroup? groupOf(MxTab tab) => groupById(tab.groupId);

  /// A cor que alguém *escolheu* pra este painel: a do projeto de que ele é,
  /// ou a dele. Null quando ninguém escolheu nenhuma.
  ///
  /// O projeto na frente do painel, e não a mais específica na frente da mais
  /// geral. É deliberado: a cor de um projeto existe pra que as sessões dele
  /// sejam reconhecíveis *como um bloco*, e um painel destoando no meio
  /// desfaz justamente isso -- de relance ele lê como sendo de outro
  /// trabalho, que é o erro que a cor veio evitar.
  ///
  /// E a pasta por último das três, que é a ordem virando do avesso de novo.
  /// Também é deliberado, e pela mesma pergunta: de que bloco a cor fala. Um
  /// projeto é *um* trabalho, e por isso manda no painel; uma pasta é o lugar
  /// onde vários trabalhos acontecem, e uma cor que mandasse ali apagaria
  /// justamente a distinção entre eles. Ela é o fundo -- pinta quem ninguém
  /// pintou. Ver [Folder.tint].
  ///
  /// A cor do painel não some por baixo dela: ela fica guardada e volta a
  /// valer no dia em que o projeto ficar sem cor, ou em que o painel sair
  /// dele. E o menu do painel não finge que dá pra escolher enquanto o
  /// projeto manda -- ver `showPanelMenu`.
  ///
  /// Separada do [tintOf] porque a diferença entre escolhida e deduzida vale
  /// desenho: o que foi pedido é dito alto (ver `_TabRow`), o que a janela
  /// deduziu é dito baixo.
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

  /// A cor com que este painel se lava, quando tem uma -- o cartão dele, o
  /// cabeçalho e a linha dele na lateral.
  ///
  /// A regra de precedência mora aqui, e não nos quatro lugares que desenham:
  /// projeto, painel, grupo. As duas primeiras são escolhas (ver
  /// [chosenTintOf]); a do grupo é automática, diz "estes três andam juntos"
  /// e por isso vem por último -- um pedido ganha de uma dedução.
  ///
  /// Null é a maioria dos painéis, e é o cartão de sempre. Ver [MxTint].
  Color? tintOf(MxTab tab) => chosenTintOf(tab)?.color ?? groupOf(tab)?.color;

  /// O grupo que a tela está mostrando, quando ela está mostrando um.
  ///
  /// Derivado e não guardado num campo: é verdade enquanto *todo* painel na
  /// tela for daquele grupo, e nada mais precisa se lembrar de apagar a
  /// resposta. Arrastar uma sessão de fora pra dentro da grade, ou trocar o
  /// conteúdo de um dos quadros, já responde não na jogada seguinte -- sem
  /// invalidação espalhada por [dismiss], [dropTab] e [closeTab].
  ///
  /// É o que separa a grade que veio de um grupo da grade que você montou à
  /// mão: só na primeira é que escolher uma sessão de fora desmancha a tela
  /// toda. Ver [select].
  PaneGroup? get activeGroup {
    final open = openPanes;
    if (open.isEmpty) return null;
    final group = groupOf(open.first);
    if (group == null) return null;
    return open.every((t) => t.groupId == group.id) ? group : null;
  }

  /// Se a tela é a do grupo. Ver [activeGroup].
  bool showing(PaneGroup group) => activeGroup?.id == group.id;

  void renameGroup(PaneGroup group, String name) {
    final title = name.trim();
    if (title.isEmpty || title == group.name) return;
    group.name = title;
    _save();
    notifyListeners();
  }

  /// Esquece o grupo. Não fecha nada: o grupo era uma forma de dispor painéis,
  /// e os painéis continuam abertos onde estavam.
  void removeGroup(PaneGroup group) {
    groups.remove(group);
    _save();
    notifyListeners();
  }

  /// Esquece todos os grupos de uma vez -- o "limpar" da régua dos grupos.
  ///
  /// Não fecha nem move painel nenhum, como [removeGroup]: o que se apaga é a
  /// lista de arranjos guardados, e a tela de agora continua exatamente como
  /// está. As marcas saem junto, como no [ungroup]: um painel lavado da cor de
  /// um grupo que já não existe seria uma cor que não aponta pra lugar nenhum.
  ///
  /// Devolve quantos foram esquecidos, que é o que a janela tem pra dizer:
  /// nada mais mudou de lugar pra mostrar o que aconteceu.
  int clearGroups() {
    final gone = groups.length;
    if (gone == 0) return 0;
    for (final g in groups) {
      _stamp(g, const []);
    }
    groups.clear();
    _save();
    notifyListeners();
    return gone;
  }

  /// Põe o arranjo do grupo na tela: os painéis dele, cortados como estavam.
  ///
  /// O que estava na tela e não está no grupo sai dela sem morrer, que é o que
  /// o x do cabeçalho faz -- ver [dismiss]. Clicar num grupo é trocar de
  /// vista, e clicar numa sessão da lateral continua sendo o que sempre foi:
  /// aquela sessão no lugar em foco.
  void openGroup(PaneGroup group) {
    // Suspende a gravação como faz a restauração da última execução: abrir
    // seis painéis seriam seis gravações do config, e a que interessa é a do
    // arranjo pronto, no fim.
    _restoring = true;
    final taken = <String>{};
    final panels = <MxTab?>[];
    for (final pane in group.panes) {
      final tab = _adopt(pane, taken) ?? _openPane(pane);
      // Uma posição por receita, com null onde nada abriu: as folhas da árvore
      // são índices desta lista. Ver [_restoreLayout].
      panels.add(tab);
      if (tab != null) taken.add(tab.id);
    }
    _restoring = false;

    final first = panels.nonNulls.firstOrNull;
    if (first == null) {
      showBanner('o grupo "${group.name}" não tem mais nenhum painel pra abrir', sticky: true);
      return;
    }
    panes =
        Panes.fromJson(group.tree, (i) => i >= 0 && i < panels.length ? panels[i]?.id : null) ??
        PaneLeaf(first.id);
    focusedPaneId = Panes.order(panes).firstOrNull;
    // Abrir um grupo é querer os painéis dele rodando: o que entrou na tela
    // hibernado acorda. Ver [MxTab.hibernated].
    for (final t in openPanes) {
      if (t.hibernated) unawaited(wake(t));
    }
    // Os painéis que entraram são os painéis do grupo, inclusive os que foram
    // abertos agora no lugar dos que morreram. É esta marca que faz a linha
    // deles compartilhar a cor e abrir o grupo em vez de trocar o quadro.
    _stamp(group, panels.nonNulls.toList());
    _save();
    notifyListeners();
  }

  /// O painel que já está aberto e serve pra esta vaga do grupo, se houver.
  ///
  /// Um grupo é um arranjo, não uma leva de sessões novas: os três terminais
  /// que você tirou da tela pra olhar outra coisa continuam vivos na lateral,
  /// e voltar ao grupo é trazer *eles* de volta. Subir três shells novos ao
  /// lado dos que já estavam ali seria acumular uma leva por clique -- é a
  /// mesma razão pela qual [showDoc] reaproveita o leitor aberto em vez de
  /// abrir o sexto painel.
  ///
  /// [taken] são as vagas já preenchidas: três terminais na mesma pasta são
  /// três receitas idênticas, e sem isso as três cairiam no mesmo painel.
  MxTab? _adopt(Map<String, dynamic> pane, Set<String> taken) {
    if (pane['kind'] == 'reader') {
      // Um leitor é *o* leitor, ver [showDoc]: o grupo não pede um painel de
      // leitura novo, pede que o que existe mostre este documento.
      final doc = MxDoc.fromJson(
        (pane['doc'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      final reader = tabs.firstWhereOrNull((t) => t.isReader && !taken.contains(t.id));
      if (doc == null || reader == null) return null;
      reader.doc!.become(doc);
      // O apelido era o nome do documento anterior.
      reader.customLabel = null;
      return reader;
    }
    if (pane['kind'] == 'setup') {
      // A configuração de uma pasta é uma só: o grupo pede a que já existe
      // pra aquela raiz, ou nenhuma.
      final setup = MxSetup.fromJson(
        (pane['setup'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      if (setup == null) return null;
      final open = tabs.firstWhereOrNull(
        (t) => t.isSetup && t.setup!.root == setup.root && !taken.contains(t.id),
      );
      if (open == null) return null;
      open.setup!.become(setup);
      return open;
    }
    final root = pane['loose'] == true ? loose.root : pane['folderRoot'] as String?;
    final sessionId = pane['sessionId'] as String?;
    return tabs.firstWhereOrNull(
      (t) =>
          !taken.contains(t.id) &&
          t.kind.name == pane['kind'] &&
          t.folderRoot == root &&
          t.cwd == pane['cwd'] &&
          // Painel cujo processo saiu não é o painel de volta: o grupo abre um
          // no lugar dele -- e uma conversa do claude volta com `--resume`,
          // que é o arranjo de antes de verdade e não a casca dele.
          !t.exited &&
          // Com a conversa anotada na receita, é aquela conversa que o grupo
          // quer; sem ela, qualquer sessão viva naquela pasta serve.
          (sessionId == null || t.resumeId == sessionId),
    );
  }

  // --- panes and keyboard -------------------------------------------------

  /// Solta [tab] em cima do painel de [target], pelo lado [side].
  ///
  /// Uma sessão aparece numa posição só: arrastar uma que já está na tela é
  /// mudá-la de lugar, então ela sai de onde estava antes de entrar onde caiu
  /// -- e o buraco que ela deixa fecha sozinho, igual ao que o x faria.
  void dropTab(MxTab tab, {required MxTab target, required DropSide side}) {
    // Solta em cima de si mesma: o gesto não vai a lugar nenhum, e um drag de
    // mouse começa com um pixel, então é o clique que ele quase foi.
    if (tab.id == target.id || !Panes.has(panes, target.id)) {
      focusPane(tab);
      return;
    }
    _drop(tab);
    if (side == DropSide.center) {
      // Soltar em cima de um preso é trocar o que está no lugar preso, de
      // propósito -- o arraste é o gesto que o clique não é. O lugar continua
      // preso, agora com a sessão que chegou.
      if (isPinned(target)) tab.pinned = true;
      Panes.swap(panes, target.id, tab.id);
    } else {
      panes = Panes.insert(panes!, tabId: tab.id, targetId: target.id, side: side);
    }
    focusedPaneId = tab.id;
    _save();
    notifyListeners();
  }

  /// Manda o teclado pro painel que mostra [tab]: um clique dentro dele.
  void focusPane(MxTab tab) {
    if (focusedPaneId == tab.id || !Panes.has(panes, tab.id)) return;
    focusedPaneId = tab.id;
    notifyListeners();
  }

  /// Você está olhando pra [tab] agora?
  ///
  /// As três condições são as três de verdade: a janela na frente, o painel na
  /// tela, e o teclado nele. Numa grade de cinco todos estão na tela, e é o
  /// foco que separa o que você está lendo dos quatro no canto do olho -- sem
  /// ele, voltar pra janela marcaria os cinco como vistos de uma vez, que é
  /// exatamente o estado de que [MxTab.unseen] veio nos tirar.
  bool watching(MxTab tab) => windowActive && focusedPaneId == tab.id && Panes.has(panes, tab.id);

  /// Dá por visto o painel em foco. Chamado pelo relógio de um segundo.
  ///
  /// Pelo relógio, e não de dentro de cada lugar que mexe no foco, por duas
  /// razões: `focusedPaneId` é escrito em oito lugares e um deles vai ser
  /// esquecido, e um segundo parado em cima do painel é uma definição mais
  /// honesta de "vi" do que um ⌘→ que passou por ele a caminho do próximo.
  @visibleForTesting
  bool seeFocused() {
    final tab = _byId(focusedPaneId);
    if (tab == null || !watching(tab)) return false;
    // O sino pela mesma régua: um segundo olhando pro painel é ter visto o
    // que ele avisou.
    if (readNoticesOf(tab.id) && !tab.unseen) return true;
    if (!tab.unseen) return false;
    tab.unseen = false;
    notifyListeners();
    return true;
  }

  /// A janela ganhou ou perdeu a frente.
  ///
  /// A volta é o momento da pergunta que isto tudo responde -- "o que mudou
  /// enquanto eu estava fora" --, e ela tem resposta exata: os painéis que
  /// pararam depois de você sair. Só esses entram na conta, senão a faixa
  /// viraria um lembrete de pendência velha toda vez que você troca de app.
  void setWindowActive(bool active) {
    if (windowActive == active) return;
    windowActive = active;
    if (!active) {
      _awaySince = DateTime.now();
      for (final t in _toastTimers.values) {
        t.cancel();
      }
      _toastTimers.clear();
      notifyListeners();
      return;
    }
    for (final n in toasts) {
      _armToast(n);
    }
    final since = _awaySince;
    _awaySince = null;
    final landed = since == null
        ? const <MxTab>[]
        : [
            for (final t in tabs)
              if (t.unseen && t.restedAt != null && t.restedAt!.isAfter(since)) t,
          ];
    // Os cartões do sino que esperaram a volta já contam essa história, e com
    // nome; o recado é pra quando eles não contam -- e no não perturbe, nem
    // ele.
    final quiet = doNotDisturb || toasts.isNotEmpty;
    if (!quiet && landed.length == 1) {
      showBanner('${landed.first.title} terminou enquanto você estava fora');
    } else if (!quiet && landed.length > 1) {
      showBanner('${landed.length} painéis terminaram enquanto você estava fora');
    }
    notifyListeners();
  }

  /// Passa o foco pro painel seguinte na tela, ou pro anterior.
  void cyclePane(int delta) {
    final order = Panes.order(panes);
    if (order.length < 2) return;
    final at = order.indexOf(focusedPaneId ?? order.first);
    final next = (at + delta) % order.length;
    focusedPaneId = order[next < 0 ? next + order.length : next];
    notifyListeners();
  }

  /// A alça entre dois painéis, arrastada. [total] é o quanto o corte mede no
  /// sentido dele, em pixels -- é o que transforma o delta do mouse na fração
  /// que fica guardada.
  void resizeSplit(PaneSplit split, int gutter, double delta, double total) {
    Panes.resize(split, gutter, delta, total);
    _save();
    notifyListeners();
  }

  void selectIndex(int index) {
    if (index < 0 || index >= tabs.length) return;
    select(tabs[index]);
  }

  /// Move the focused pane through the panel list.
  void cycle(int delta) {
    if (tabs.isEmpty) return;
    final current = tabs.indexWhere((t) => t.id == focusedTab?.id);
    final next = (current + delta) % tabs.length;
    select(tabs[next < 0 ? next + tabs.length : next]);
  }

  /// Os painéis de uma pasta. As janelas de plugin ficam fora: elas moram na
  /// aba do plugin que as abriu (ver [viewsOf]), e não na pasta do painel
  /// que estava em foco quando alguém apertou o botão -- a central do Flutter
  /// de um app não é da pasta de outro.
  ///
  /// Os terminais com dono também ficam fora (ver [MxTab.owner]) -- a não ser
  /// que o dono tenha sido removido, e aí voltam pros avulsos em vez de sumir.
  List<MxTab> tabsOf(Folder p) => tabs
      .where(
        (t) =>
            t.folderRoot == p.root &&
            !t.isPluginView &&
            (t.owner == null || plugins.byId(t.owner!) == null),
      )
      .toList();

  /// Os terminais que [plugin] abriu pra ele. Ver [MxTab.owner].
  List<MxTab> ownedBy(MxPlugin plugin) =>
      tabs.where((t) => t.owner == plugin.id && !t.embedded).toList();

  int needingHuman(Folder p) => tabsOf(p).where((t) => !t.done && t.status.needsHuman).length;

  /// Quanto tempo um recado fica na tela antes de sair sozinho.
  ///
  /// Longo o bastante pra ser lido sem pressa, curto o bastante pra não virar
  /// mobília: a faixa some antes que você pare de notar que ela está lá.
  static const bannerLife = Duration(seconds: 6);

  Timer? _bannerTimer;

  /// Um recado na faixa flutuante, por [bannerLife].
  ///
  /// [sticky] é pra quando o recado é a única notícia de uma coisa que deu
  /// errado: um arquivo que sumiu, uma sessão que morreu na largada. Esses
  /// esperam o clique — some sozinho o que só confirma o que você acabou de
  /// mandar fazer.
  void showBanner(String text, {bool sticky = false}) {
    banner = text;
    _bannerTimer?.cancel();
    _bannerTimer = sticky ? null : Timer(bannerLife, clearBanner);
    notifyListeners();
  }

  void clearBanner() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    banner = null;
    notifyListeners();
  }

  // --- o sino -------------------------------------------------------------

  /// Uma linha nova no sino, já lida se você estava olhando pro painel.
  ///
  /// Entra mesmo lida: o sino é também o histórico do dia, e "o que terminou
  /// na última hora" inclui o que terminou na sua frente. O que ela não faz,
  /// lida, é contar no número do sino.
  void _notice(MxTab tab, MxNoticeKind kind) {
    // Um aviso novo do mesmo painel aposenta os de antes: a pergunta que ele
    // fez já foi respondida, ou ele não estaria parando de novo.
    readNoticesOf(tab.id, notify: false);
    final notice = MxNotice(tabId: tab.id, kind: kind, title: tab.title)..read = watching(tab);
    notices.insert(0, notice);
    if (notices.length > noticeCap) {
      for (final old in notices.sublist(noticeCap)) {
        _dropToast(old);
      }
      notices.removeRange(noticeCap, notices.length);
    }
    // Na tela só o que é novidade: o que terminou na sua frente você viu, e
    // com a lista aberta a linha já está à vista.
    if (!notice.read && !doNotDisturb && !noticesOpen) _toast(notice);
  }

  // --- os cartões na tela ---------------------------------------------------

  /// Quanto um cartão fica na tela antes de sair sozinho. Mais que o
  /// [bannerLife]: um recado confirma o que você fez, um aviso conta o que
  /// você não viu -- e ele tem nome e verbo pra ler.
  static const toastLife = Duration(seconds: 8);

  void _toast(MxNotice notice) {
    toasts.add(notice);
    while (toasts.length > toastCap) {
      _dropToast(toasts.first);
    }
    _armToast(notice);
  }

  /// O relógio do cartão só anda com você na janela: o que chegou enquanto
  /// você estava em outro app espera a volta pra ser lido, em vez de sumir
  /// sem plateia. Ver [setWindowActive].
  void _armToast(MxNotice notice) {
    _toastTimers.remove(notice)?.cancel();
    if (!windowActive) return;
    _toastTimers[notice] = Timer(toastLife, () => dismissToast(notice));
  }

  void _dropToast(MxNotice notice) {
    _toastTimers.remove(notice)?.cancel();
    toasts.remove(notice);
  }

  void _clearToasts() {
    for (final t in _toastTimers.values) {
      t.cancel();
    }
    _toastTimers.clear();
    toasts.clear();
  }

  /// Tira o cartão da tela. A linha fica no sino, como estava.
  void dismissToast(MxNotice notice) {
    if (!toasts.contains(notice)) return;
    _dropToast(notice);
    notifyListeners();
  }

  /// O cartão sob o ponteiro não sai sozinho: some quem está sendo lido é
  /// o cartão fugindo da mão. O relógio volta inteiro quando ela sai.
  void holdToast(MxNotice notice, bool hold) {
    if (!toasts.contains(notice)) return;
    if (hold) {
      _toastTimers.remove(notice)?.cancel();
    } else {
      _armToast(notice);
    }
  }

  void setDoNotDisturb(bool on) {
    if (on == doNotDisturb) return;
    doNotDisturb = on;
    // Ligar é pedir silêncio agora, não a partir do próximo.
    if (on) _clearToasts();
    _save();
    notifyListeners();
  }

  void toggleDoNotDisturb() => setDoNotDisturb(!doNotDisturb);

  /// Dá por lidos os avisos de um painel. Devolve se apagou algum.
  bool readNoticesOf(String tabId, {bool notify = true}) {
    var changed = false;
    for (final n in notices) {
      if (n.tabId == tabId && !n.read) {
        n.read = true;
        _dropToast(n);
        changed = true;
      }
    }
    if (changed && notify) notifyListeners();
    return changed;
  }

  void toggleNotices() {
    noticesOpen = !noticesOpen;
    sessionsOpen = false;
    // A lista aberta mostra as mesmas linhas, e maiores: os cartões saem pra
    // não ficar duas vezes a mesma coisa no mesmo canto.
    if (noticesOpen) _clearToasts();
    notifyListeners();
  }

  void closeNotices() {
    if (!noticesOpen) return;
    noticesOpen = false;
    notifyListeners();
  }

  void toggleSessions() {
    sessionsOpen = !sessionsOpen;
    if (sessionsOpen) noticesOpen = false;
    notifyListeners();
  }

  void closeSessions() {
    if (!sessionsOpen) return;
    sessionsOpen = false;
    notifyListeners();
  }

  /// O clique numa linha da lista das sessões: fecha a lista e põe a sessão
  /// na tela.
  void openSession(MxTab tab) {
    sessionsOpen = false;
    select(tab);
  }

  /// O clique numa linha do sino: leva você até o painel.
  ///
  /// Um painel que já foi fechado não tem pra onde levar; a linha fica, lida,
  /// dizendo o que ele fez antes de ir embora.
  void openNotice(MxNotice notice) {
    final tab = _byId(notice.tabId);
    _dropToast(notice);
    if (tab == null) {
      notice.read = true;
      notifyListeners();
      return;
    }
    readNoticesOf(tab.id, notify: false);
    noticesOpen = false;
    select(tab);
  }

  void dismissNotice(MxNotice notice) {
    _dropToast(notice);
    notices.remove(notice);
    notifyListeners();
  }

  void readAllNotices() {
    for (final n in notices) {
      n.read = true;
    }
    _clearToasts();
    notifyListeners();
  }

  void clearNotices() {
    _clearToasts();
    notices.clear();
    notifyListeners();
  }

  // --- incoming events ----------------------------------------------------

  /// One hook event, applied. Visible because the edge it watches for is the
  /// whole contract of a queue: one turn, one step.
  @visibleForTesting
  void applyHook(HookEvent e) {
    final tab = _byId(e.tabId);
    if (tab == null) return;
    final before = tab.hooks.status;
    final producedBefore = tab.hooks.touched.length;
    HookReducer.apply(tab.hooks, e.name, e.payload);
    // Cru, como o Claude Code mandou: o plugin que pediu hooks quer o evento,
    // não a leitura que a janela faz dele. Quem não declarou a permissão não
    // recebe -- o payload tem o prompt e os argumentos das ferramentas.
    plugins.emit(
      'hook',
      {'tabId': tab.id, 'name': e.name, 'payload': e.payload},
      activations: ['onHook:${e.name}', 'onHook:*'],
      needs: PluginPermission.hooks,
    );
    if (tab.hooks.status != before) {
      plugins.emit(
        'session.status',
        {'tabId': tab.id, 'status': tab.hooks.status.name, 'previous': before.name},
        activations: ['onSession'],
      );
    }
    // Asked for more, it is not finished any more. The mark is a judgement
    // about work that is over, and a prompt is the person who made it saying
    // it is not -- so the app takes their word for that too, rather than
    // leaving a tick on a session that is off doing something new.
    if (tab.done && e.name == 'UserPromptSubmit') {
      tab.done = false;
      _save();
    }
    if (tab.hooks.sessionId != null && tab.sessionId != tab.hooks.sessionId) {
      tab.sessionId = tab.hooks.sessionId;
      _save();
    }
    // A file the session just wrote is worth the debounced write: the whole
    // point of keeping the list is that it survives closing the window.
    if (tab.hooks.touched.length != producedBefore) _save();
    // The edge, not the state: `Stop` is the only event that reaches idle, but
    // a second one arriving while the panel is already idle must not spend
    // another step. Armar não é disparar -- quem escolhe a hora é [pumpFlows],
    // e o fim do turno é só o primeiro dos requisitos dela.
    final after = tab.hooks.status;
    // O sino ouve as mesmas viradas que a lateral pinta. A espera por input
    // não entra como aviso próprio: ela é o "terminou" visto um minuto depois
    // (ver [ClaudeStatusUi.atRest]), e dois avisos pra uma parada só é ruído.
    if (after != before) {
      if (after == ClaudeStatus.waitingAnswer) {
        _notice(tab, MxNoticeKind.question);
      } else if (after == ClaudeStatus.waitingPermission) {
        _notice(tab, MxNoticeKind.permission);
      } else if (!before.atRest && after.atRest) {
        _notice(tab, MxNoticeKind.finished);
      } else if (!after.needsHuman && !after.atRest) {
        // Voltou a trabalhar: o que ele pedia já foi dado.
        readNoticesOf(tab.id, notify: false);
      }
    }
    if (!before.atRest && tab.hooks.status.atRest) {
      if (tab.followUps.isNotEmpty) tab.armed = true;
      // A mesma virada responde "terminou quando" e "você viu?". Ver
      // [MxTab.restedAt] e [MxTab.unseen].
      tab.restedAt = DateTime.now();
      tab.unseen = !watching(tab);
    } else if (before.atRest && !tab.hooks.status.atRest) {
      // Voltou a trabalhar: a parada de antes deixou de ser a parada dela, e
      // uma novidade que você não viu não pode sobreviver ao turno seguinte.
      tab.restedAt = null;
      tab.unseen = false;
    }
    _checkAlerts();
    notifyListeners();
  }

  // --- follow-ups ---------------------------------------------------------

  /// Arm [tab] with what to do when it next goes quiet, replacing whatever
  /// was queued.
  ///
  /// [now] é pra fila armada sobre uma sessão que *já* está parada: sem ela o
  /// primeiro passo esperaria um turno que talvez não venha mais, porque o
  /// gatilho é a *virada* pra ocioso e ela já passou. É o que separa "arma
  /// isso pra quando ela terminar" de "toca isso agora".
  void queue(MxTab tab, List<FollowUp> steps, {bool now = false}) {
    tab.followUps
      ..clear()
      ..addAll(steps);
    tab.armed = steps.isNotEmpty && (now || tab.armed);
    notifyListeners();
  }

  /// Abre uma sessão já com um fluxo pendurado nela.
  ///
  /// O fluxo que não precisa de painel nenhum pra existir: o primeiro passo é
  /// a própria sessão -- o prompt com que ela nasce --, e a fila fica armada
  /// desde antes de ela dar o primeiro sinal de vida. Sem isto todo fluxo
  /// começava por um painel que você tinha que abrir e mandar trabalhar à
  /// mão, o que é justamente a parte que não precisava de você.
  MxTab startFlow({
    required Folder folder,
    required String prompt,
    required List<FollowUp> steps,
    String? cwd,
    String? label,
    FeatureOrHotfix? featureOrHotfix,
  }) {
    final tab = openClaude(
      folder,
      cwd: cwd ?? folder.root,
      label: label,
      featureOrHotfix: featureOrHotfix,
      prompt: prompt,
    );
    queue(tab, steps);
    showBanner(
      steps.isEmpty
          ? '${tab.title}: sessão aberta'
          : '${tab.title}: fluxo de ${steps.length} '
                '${steps.length == 1 ? 'passo' : 'passos'} armado',
    );
    return tab;
  }

  /// [tab] nasceu de [root], ou de algo que nasceu dele? Ver [MxTab.bornOf].
  bool descendsFrom(MxTab tab, MxTab root) {
    var up = _byId(tab.bornOf);
    // Um fluxo que abre uma sessão que abre outra é uma linhagem, não um
    // ciclo -- mas o teto é mais barato que a confiança.
    for (var depth = 0; up != null && depth < 8; depth++) {
      if (up.id == root.id) return true;
      up = _byId(up.bornOf);
    }
    return false;
  }

  /// Pendura [child] em [parent]: o painel que um passo de fluxo abriu é filho
  /// da sessão de onde o passo saiu.
  ///
  /// Mexer na lista é parte do vínculo, não enfeite: ela é a ordem da lateral
  /// *e* a numeração do ⌘1..9, e um filho nascido no fim dela apareceria a
  /// cinco linhas de quem o abriu. Ele entra atrás dos irmãos que já nasceram,
  /// que é a ordem em que o fluxo os produziu.
  void _descend(MxTab child, MxTab parent) {
    child.bornOf = parent.id;
    var at = tabs.indexOf(parent);
    final from = tabs.indexOf(child);
    if (at < 0 || from < 0) return;
    while (at + 1 < tabs.length && at + 1 != from && descendsFrom(tabs[at + 1], parent)) {
      at++;
    }
    if (from != at + 1) {
      tabs.removeAt(from);
      tabs.insert(at + 1, child);
    }
    _save();
    notifyListeners();
  }

  /// O que ainda segura o próximo passo de [tab]. [FlowHold.go] é "nada".
  ///
  /// O fim do turno era o critério inteiro, e ele é fraco por duas razões que
  /// custaram fluxo disparado cedo:
  ///
  ///  * uma sessão que larga dois agentes em segundo plano manda `Stop` na
  ///    hora e fica ociosa enquanto eles trabalham -- ver [HookState.forksOut];
  ///  * ociosa por um instante entre duas coisas continua sendo ociosa, e o
  ///    `Stop` não distingue o fim do trabalho de uma pausa dentro dele.
  ///
  /// Daí as duas condições além do turno: nenhum fork em aberto, e
  /// [flowQuiet] de silêncio -- silêncio de tudo, porque evento de fork
  /// também passa por aqui e adia a conta. [flowPatience] é a válvula: um
  /// fork que nunca avisa que terminou não pode segurar a fila pra sempre.
  ///
  /// Público porque o editor de fluxo mostra a resposta: uma fila que está
  /// esperando é indistinguível de uma que não vai disparar, e a diferença
  /// entre as duas é a única coisa que se quer saber ali.
  FlowHold holdFor(MxTab tab, {DateTime? at}) {
    if (tab.exited || !tab.status.atRest) return FlowHold.working;
    final last = tab.hooks.lastEventAt;
    final silence = last == null ? flowPatience : (at ?? DateTime.now()).difference(last);
    if (silence >= flowPatience) return FlowHold.go;
    if (tab.hooks.busyForks) return FlowHold.forks;
    return silence >= flowQuiet ? FlowHold.go : FlowHold.quiet;
  }

  /// Quanto tempo sem sinal nenhum -- da sessão ou dos agentes dela -- conta
  /// como ter parado de verdade.
  @visibleForTesting
  static const flowQuiet = Duration(seconds: 5);

  /// Até quando esperar um agente que não avisou que terminou.
  ///
  /// Uma fila que não dispara é pior que uma que dispara tarde: ela some sem
  /// dizer nada. Passado isto o passo sai, e o aviso diz que saiu sem a
  /// confirmação de todo mundo.
  @visibleForTesting
  static const flowPatience = Duration(minutes: 3);

  /// Um passo de cada painel armado que já pode dar o próximo. O relógio de um
  /// segundo de [init] é quem chama.
  @visibleForTesting
  void pumpFlows() {
    for (final tab in [...tabs]) {
      if (!tab.armed || tab.exited || tab.followUps.isEmpty) continue;
      if (holdFor(tab) != FlowHold.go) continue;
      advance(tab);
    }
  }

  /// Spend the next queued step, if there is one.
  ///
  /// Visible because the guarantee worth testing is that one turn spends one
  /// step -- a queue that emptied itself on a single `Stop` would fire a plan's
  /// third instruction before its first had been read.
  @visibleForTesting
  void advance(MxTab tab) {
    if (tab.exited || tab.followUps.isEmpty) return;
    final step = tab.followUps.removeAt(0);
    // Só o passo que devolve o turno pra esta sessão faz o seguinte esperar
    // outro: os outros três acontecem fora dela e a deixam parada do mesmo
    // jeito, então a fila segue andando sozinha -- ver [FollowUpKindUi.handsBack].
    // Sem isso um fluxo que começasse por um comando parava no primeiro passo,
    // esperando pra sempre um turno que não vinha mais.
    tab.armed = !step.kind.handsBack && tab.followUps.isNotEmpty;
    // Chegar aqui com fork em aberto é a paciência tendo estourado (ver
    // [holdFor]): a conta é dada por perdida, senão o resto da fila sairia
    // avisando de novo, passo a passo, do mesmo agente que não respondeu. Um
    // que volte a dar sinal segura o próximo passo outra vez, que é o certo.
    final late = tab.hooks.busyForks;
    if (late) {
      tab.hooks.forkIds.clear();
      tab.hooks.forksOut = 0;
    }
    unawaited(runFollowUp(step, from: tab, late: late));
    notifyListeners();
  }

  /// Carry out one step. See [FollowUpKind] for what each one means.
  ///
  /// [late] diz que a paciência com os agentes em aberto acabou antes de eles
  /// terminarem: o passo sai mesmo assim, e o aviso conta isso -- é a única
  /// chance de você saber que o fluxo pode ter visto trabalho pela metade.
  @visibleForTesting
  Future<void> runFollowUp(FollowUp step, {required MxTab from, bool late = false}) async {
    if (!tabs.contains(from)) return;
    final featureOrHotfix = featureOrHotfixOf(from);
    if (late) {
      showBanner(
        '${from.title}: os agentes dela não avisaram que terminaram — '
        'o fluxo seguiu assim mesmo',
        sticky: true,
      );
    }

    switch (step.kind) {
      case FollowUpKind.keepGoing:
        if (from.exited) return;
        await from.term.submit(step.text);
        showBanner('${from.title}: próximo passo enviado');

      case FollowUpKind.newSession:
        final tab = openClaude(
          from.folder,
          cwd: from.cwd,
          label: '${from.title} ▸ depois',
          featureOrHotfix: featureOrHotfix,
          prompt: step.text,
        );
        _descend(tab, from);
        showBanner('${from.title} terminou — abri ${tab.title} em seguida');

      case FollowUpKind.command:
        final shell = openShell(from.folder, cwd: from.cwd, command: step.text, featureOrHotfix: featureOrHotfix);
        // O comando, e não "X ▸ depois": dois passos de comando do mesmo fluxo
        // viravam duas linhas com o nome idêntico, e de onde elas vieram agora
        // quem diz é a lateral, que as pendura embaixo de quem as abriu.
        shell.customLabel = shellLabel(step.text);
        _descend(shell, from);
        showBanner('${from.title} terminou — rodando ${step.text}');

      case FollowUpKind.handoff:
        final target = _byId(step.targetTabId);
        // A target closed in the meantime is not worth a dialog -- but it is
        // worth saying, because a handoff quietly not happening is the one
        // failure you would never notice.
        if (target == null || target.exited) {
          showBanner(
            '${from.title} terminou, mas o painel que ia receber não está mais aberto',
            sticky: true,
          );
          return;
        }
        await target.term.submit(handoffText(from, step.text));
        showBanner('${from.title} passou a bola pra ${target.title}');
    }
  }

  /// O nome do painel que roda um comando: o comando, numa linha.
  @visibleForTesting
  static String shellLabel(String command) {
    final one = command.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 28 ? one : '${one.substring(0, 27).trimRight()}…';
  }

  /// What one panel says to the next.
  ///
  /// The closing message crosses verbatim and fenced, because the receiving
  /// session has no other way to know what happened: it is a different process
  /// in a different conversation, and all it shares with the sender is the
  /// checkout on disk.
  @visibleForTesting
  static String handoffText(MxTab from, String note) {
    final said = _clipHandoff(from.hooks.lastMessageFull);
    final out = StringBuffer('[maestria] o painel "${from.title}" acabou de terminar.');
    if (said != null && said.isNotEmpty) {
      out.write('\n\nO que ele disse ao terminar:\n"""\n$said\n"""');
    }
    if (note.trim().isNotEmpty) out.write('\n\n${note.trim()}');
    return out.toString();
  }

  /// A closing message is whatever the model felt like writing, and it is
  /// about to be typed into somebody's prompt. The tail is what gets kept:
  /// what a session says last is what it concluded.
  static String? _clipHandoff(String? said) {
    const max = 4000;
    if (said == null || said.isEmpty) return said;
    return said.length <= max ? said : '…${said.substring(said.length - max)}';
  }

  /// One poll, applied: our own panels learn the session id the CLI gave
  /// them, which is what makes a restored panel resumable.
  ///
  /// Sessions we did not launch are ignored on purpose. Their pty belongs to
  /// somebody else's terminal, so there was nothing the sidebar could offer
  /// for them beyond a row taking up space.
  @visibleForTesting
  void applyAgents(List<AgentInfo> list) {
    final ourPids = {
      for (final t in tabs)
        if (t.term.pid != null) t.term.pid!: t,
    };
    for (final a in list) {
      final mine = a.pid == null ? null : ourPids[a.pid];
      if (mine == null) continue;
      // O nome vem antes do id na vida de uma sessão e vale por si: é por ele
      // que se fala com ela.
      if (a.name != null && a.name!.isNotEmpty) mine.agentName = a.name;
      if (a.sessionId == null) continue;
      mine.sessionId = a.sessionId;
    }
    _checkAlerts();
  }

  /// Notify once per session that stops for a human, and keep the dock badge
  /// equal to how many are stopped right now.
  void _checkAlerts() {
    final waiting = <String, String>{};
    for (final t in tabs) {
      if (!t.done && t.status.needsHuman) {
        waiting['tab:${t.id}'] = '${t.title} · ${t.status.callToAction}';
      }
    }

    for (final entry in waiting.entries) {
      if (_alerted.add(entry.key)) {
        notifier.alert('maestria', entry.value);
      }
    }
    _alerted.removeWhere((key) => !waiting.containsKey(key));
    notifier.badge(waiting.isEmpty ? null : '${waiting.length}');
  }

  /// Sair: encerrar toda sessão antes que a janela vá embora.
  ///
  /// Nenhum painel é filho deste processo de um jeito que o sistema vá
  /// recolher. Cada um é uma sessão de terminal própria (ver
  /// [TermSession.kill]), então ninguém desliga a linha por nós quando o app
  /// some -- e o que ficou aberto sobrevive a ele, invisível, até a máquina
  /// reiniciar. Desligar é conosco, e é a última coisa que ainda dá pra fazer.
  ///
  /// Diferente de [dispose], isto espera: é chamado de `onExitRequested`, que
  /// segura o encerramento até responder. O teto é a carência que cada sessão
  /// dá ao próprio hangup, com todas correndo em paralelo -- alguns segundos.
  Future<void> shutdown() async {
    // A gravação vem antes das mortes, não depois: [_writeConfig] só salva
    // painel que ainda roda, então um save que caísse depois dos hangups
    // restauraria uma janela vazia na próxima abertura.
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce!.cancel();
      await _writeConfig();
    }
    agents.stop();
    await hooks.stop();
    await Future.wait([plugins.stopAll(), for (final t in tabs) _end(t)]);
  }

  /// Cancela o que a sessão ainda ia fazer e desliga a linha.
  Future<void> _end(MxTab tab) {
    tab.armed = false;
    return tab.term.kill();
  }

  /// Depois do fim, ninguém mais é avisado -- ver [_gone]. O `super` estoura
  /// nesse caso, e quem chegou atrasado não tem como saber que chegou.
  @override
  void notifyListeners() {
    if (_gone) return;
    // O relógio do `claude agents` anda no ritmo do que há pra descobrir, e
    // toda mudança de estado passa por aqui -- é o lugar mais barato de
    // perguntar se ainda falta o id de alguém. Ver [AgentsWatcher.eager].
    agents.eager = tabs.any((t) => t.kind == TabKind.claude && !t.exited && t.resumeId == null);
    super.notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    // A write that was still waiting out its debounce has nothing left to
    // write about: the panels it would describe are being killed right here.
    _saveDebounce?.cancel();
    _bannerTimer?.cancel();
    _clearToasts();
    floats.dispose();
    agents.stop();
    hooks.stop();
    plugins.killAll();
    for (final t in tabs) {
      t.armed = false;
      // Nada de await aqui: este é o caminho sem futuro nenhum pra rodar
      // depois dele. O hangup sai; quem escala é [shutdown].
      t.term.hangUp();
    }
    super.dispose();
  }
}
