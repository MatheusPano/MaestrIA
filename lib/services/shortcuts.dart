import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
// Pelo [SingleActivator], que mora nos widgets — é o único pedaço de Flutter
// que sabe casar uma tecla com o que foi segurado junto, e reescrevê-lo aqui
// seria reescrever a regra que o resto do app já obedece.
import 'package:flutter/widgets.dart';

/// Uma combinação de teclas: a tecla e os modificadores segurados junto.
///
/// Existe porque um [SingleActivator] sabe disparar e mais nada — não se
/// compara com outro, não sabe se dizer em ⌘⇧T e não cabe num json. As três
/// coisas que um atalho editável precisa fazer são exatamente essas.
@immutable
class MxChord {
  const MxChord(
    this.key, {
    this.meta = false,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  final LogicalKeyboardKey key;
  final bool meta;
  final bool control;
  final bool alt;
  final bool shift;

  /// O mesmo objeto que o Flutter já usava antes de isto ser configurável: a
  /// comparação de modificadores é exata (⌘T não responde a ⌘⇧T), e é dela que
  /// o mapa inteiro herda o comportamento que sempre teve.
  SingleActivator get activator =>
      SingleActivator(key, meta: meta, control: control, alt: alt, shift: shift);

  bool accepts(KeyEvent event) => activator.accepts(event, HardwareKeyboard.instance);

  /// Como se escreve na tela, na ordem em que o macOS escreve: ⌃⌥⇧⌘.
  String get label =>
      '${control ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${meta ? '⌘' : ''}$_glyph';

  /// Como se escreve no disco: `meta+shift+t`, `ctrl+tab`, `meta+alt+right`.
  ///
  /// Legível de propósito — o config é um arquivo que dá pra abrir, e um
  /// `keyId` de dez dígitos não diz nada pra quem o abrir.
  String get id => [
    if (control) 'ctrl',
    if (alt) 'alt',
    if (shift) 'shift',
    if (meta) 'meta',
    _name,
  ].join('+');

  /// Por que esta combinação não pode virar atalho — ou null, se puder.
  ///
  /// Recusar cedo é o ponto: um atalho impossível não falha na hora em que é
  /// escolhido, falha meses depois como "essa tecla parou de funcionar".
  String? get rejection {
    if (isModifier(key)) return null;
    if (!_known) return 'essa tecla não dá pra usar num atalho';
    if (reserved[this] case final why?) return why;
    if (!meta && !control && !alt && !_isFunction) {
      return 'precisa de ⌘, ⌃ ou ⌥ — sem modificador a tecla sumiria do terminal';
    }
    if (control && !meta && !alt && _printable) {
      return 'o terminal manda ⌃$_glyph pro processo como código de controle';
    }
    return null;
  }

  bool get valid => !isModifier(key) && rejection == null;

  static MxChord? parse(String? id) {
    if (id == null || id.isEmpty) return null;
    final parts = id.split('+');
    final key = _keyNamed(parts.removeLast());
    if (key == null) return null;
    const mods = {'ctrl', 'alt', 'shift', 'meta'};
    if (parts.any((p) => !mods.contains(p))) return null;
    return MxChord(
      key,
      control: parts.contains('ctrl'),
      alt: parts.contains('alt'),
      shift: parts.contains('shift'),
      meta: parts.contains('meta'),
    );
  }

  /// O que o teclado está fazendo agora, lido de uma tecla que desceu.
  ///
  /// Os modificadores vêm do [HardwareKeyboard] e não do evento porque é a
  /// pergunta certa: quais estão segurados *neste instante*, não qual foi a
  /// última a mudar de estado.
  static MxChord? fromEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final k = HardwareKeyboard.instance;
    return MxChord(
      event.logicalKey,
      meta: k.isMetaPressed,
      control: k.isControlPressed,
      alt: k.isAltPressed,
      shift: k.isShiftPressed,
    );
  }

  /// Um ⌘ sozinho não é atalho nenhum — é a metade de um sendo digitada.
  static bool isModifier(LogicalKeyboardKey key) => _modifiers.contains(key);

  /// Combinações que a janela nunca vai ver, com quem as leva.
  ///
  /// O AppKit resolve os equivalentes de menu contra a responder chain antes
  /// de oferecer a tecla a qualquer view (foi o que engoliu o ⌘V até o menu
  /// Editar sair do MainMenu.xib), e o ⌘V daqui é do painel.
  static final Map<MxChord, String> reserved = {
    const MxChord(LogicalKeyboardKey.keyQ, meta: true): 'o macOS encerra o app com ⌘Q',
    const MxChord(LogicalKeyboardKey.keyW, meta: true): 'o macOS fecha a janela com ⌘W',
    const MxChord(LogicalKeyboardKey.keyH, meta: true): 'o macOS esconde o app com ⌘H',
    const MxChord(LogicalKeyboardKey.keyM, meta: true): 'o macOS minimiza a janela com ⌘M',
    const MxChord(LogicalKeyboardKey.keyF, meta: true, control: true):
        'o macOS usa ⌃⌘F pra tela cheia',
    const MxChord(LogicalKeyboardKey.keyH, meta: true, alt: true):
        'o macOS usa ⌥⌘H pra esconder os outros apps',
    const MxChord(LogicalKeyboardKey.keyV, meta: true): 'o painel cola com ⌘V',
    const MxChord(LogicalKeyboardKey.keyC, meta: true): 'o painel copia a seleção com ⌘C',
  };

  @override
  bool operator ==(Object other) =>
      other is MxChord &&
      other.key == key &&
      other.meta == meta &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(key, meta, control, alt, shift);

  @override
  String toString() => label;

  bool get _known => _names.containsKey(key) || _printable;
  bool get _printable => key.keyLabel.length == 1;
  bool get _isFunction => _functions.contains(key);
  String get _name => _names[key] ?? key.keyLabel.toLowerCase();
  String get _glyph => _glyphs[key] ?? key.keyLabel.toUpperCase();

  static LogicalKeyboardKey? _keyNamed(String name) {
    if (name.length == 1) {
      // Uma tecla imprimível *é* o seu caractere: os ids lógicos das letras,
      // dígitos e pontuação são o próprio code point.
      return LogicalKeyboardKey.findKeyByKeyId(name.codeUnitAt(0));
    }
    return _names.entries.firstWhereOrNull((e) => e.value == name)?.key;
  }

  /// As teclas que não são um caractere, com o nome que vai pro disco.
  static final Map<LogicalKeyboardKey, String> _names = {
    LogicalKeyboardKey.tab: 'tab',
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.space: 'space',
    LogicalKeyboardKey.backspace: 'backspace',
    LogicalKeyboardKey.delete: 'delete',
    LogicalKeyboardKey.escape: 'escape',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.home: 'home',
    LogicalKeyboardKey.end: 'end',
    LogicalKeyboardKey.pageUp: 'pageup',
    LogicalKeyboardKey.pageDown: 'pagedown',
    LogicalKeyboardKey.f1: 'f1',
    LogicalKeyboardKey.f2: 'f2',
    LogicalKeyboardKey.f3: 'f3',
    LogicalKeyboardKey.f4: 'f4',
    LogicalKeyboardKey.f5: 'f5',
    LogicalKeyboardKey.f6: 'f6',
    LogicalKeyboardKey.f7: 'f7',
    LogicalKeyboardKey.f8: 'f8',
    LogicalKeyboardKey.f9: 'f9',
    LogicalKeyboardKey.f10: 'f10',
    LogicalKeyboardKey.f11: 'f11',
    LogicalKeyboardKey.f12: 'f12',
  };

  static final Map<LogicalKeyboardKey, String> _glyphs = {
    LogicalKeyboardKey.tab: '⇥',
    LogicalKeyboardKey.enter: '⏎',
    LogicalKeyboardKey.space: '␣',
    LogicalKeyboardKey.backspace: '⌫',
    LogicalKeyboardKey.delete: '⌦',
    LogicalKeyboardKey.escape: '⎋',
    LogicalKeyboardKey.arrowLeft: '←',
    LogicalKeyboardKey.arrowRight: '→',
    LogicalKeyboardKey.arrowUp: '↑',
    LogicalKeyboardKey.arrowDown: '↓',
    LogicalKeyboardKey.home: '↖',
    LogicalKeyboardKey.end: '↘',
    LogicalKeyboardKey.pageUp: '⇞',
    LogicalKeyboardKey.pageDown: '⇟',
    LogicalKeyboardKey.f1: 'F1',
    LogicalKeyboardKey.f2: 'F2',
    LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4',
    LogicalKeyboardKey.f5: 'F5',
    LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7',
    LogicalKeyboardKey.f8: 'F8',
    LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
  };

  static final Set<LogicalKeyboardKey> _functions = {
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  };

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };
}

/// Onde os atalhos ficam agrupados na tela de configurações.
enum MxGroup {
  sessions('sessões'),
  navigation('navegação'),
  view('exibição'),
  window('janela');

  const MxGroup(this.label);
  final String label;
}

/// Tudo que o teclado dispara, como uma lista de coisas com nome.
///
/// Antes disto o mapa era a própria lista de bindings em `main.dart`: a tecla
/// e o que ela faz eram a mesma linha, e trocar uma era editar código. O que
/// esta enum separa é a *ação* — o que ela é chamada de, onde aparece na tela,
/// e com que teclas vem de fábrica.
enum MxAction {
  newClaude(
    id: 'claude',
    label: 'nova sessão claude',
    hint: 'na pasta e no projeto do painel em foco',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyT, meta: true)],
  ),
  newShell(
    id: 'shell',
    label: 'novo shell',
    hint: 'um terminal comum, no mesmo lugar',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyT, meta: true, shift: true)],
  ),
  newTask(
    id: 'task',
    label: 'nova task',
    hint: 'abre a worktree e sobe uma sessão nela',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyN, meta: true)],
  ),
  renamePane(
    id: 'rename',
    label: 'renomear o painel em foco',
    hint: 'o título dele; em branco, volta a ser o da branch ou da pasta',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyE, meta: true)],
  ),
  closePane(
    id: 'close',
    label: 'fechar o painel em foco',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.backspace, meta: true)],
  ),
  closeSettled(
    id: 'close-settled',
    label: 'fechar as sessões resolvidas',
    hint: 'as que já foram marcadas como prontas',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyK, meta: true, shift: true)],
  ),
  nextPane(
    id: 'next-pane',
    label: 'próximo painel',
    hint: 'na ordem em que estão na tela',
    group: MxGroup.navigation,
    defaults: [
      MxChord(LogicalKeyboardKey.tab, control: true),
      MxChord(LogicalKeyboardKey.arrowDown, meta: true, alt: true),
    ],
  ),
  prevPane(
    id: 'prev-pane',
    label: 'painel anterior',
    group: MxGroup.navigation,
    defaults: [
      MxChord(LogicalKeyboardKey.tab, control: true, shift: true),
      MxChord(LogicalKeyboardKey.arrowUp, meta: true, alt: true),
    ],
  ),
  nextSession(
    id: 'next-session',
    label: 'próxima sessão',
    hint: 'percorre a lateral inteira, painel aberto ou não',
    group: MxGroup.navigation,
    defaults: [MxChord(LogicalKeyboardKey.arrowRight, meta: true, alt: true)],
  ),
  prevSession(
    id: 'prev-session',
    label: 'sessão anterior',
    group: MxGroup.navigation,
    defaults: [MxChord(LogicalKeyboardKey.arrowLeft, meta: true, alt: true)],
  ),
  search(
    id: 'search',
    label: 'buscar na lateral',
    hint: 'foca o campo de busca; Esc limpa e devolve o teclado',
    group: MxGroup.navigation,
    defaults: [MxChord(LogicalKeyboardKey.keyF, meta: true)],
  ),
  openMarkdown(
    id: 'markdown',
    label: 'abrir um markdown…',
    hint: 'escolhe um arquivo e o desenha num painel de leitura',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyO, meta: true)],
  ),
  // --- ditado (vocalização) — fora desta versão ------------------------------
  // Ver o cabeçalho de `services/dictation.dart`.
  // Fora da enum, o ⌘⇧D volta a ser uma tecla livre — e um config
  // gravado com ele preso ao ditado é lido e descartado sozinho.
  // dictate(
    // id: 'dictate',
    // label: 'ditar no painel em foco',
    // hint: 'abre o microfone; aperte de novo pra transcrever e colar no prompt',
    // group: MxGroup.sessions,
    // defaults: [MxChord(LogicalKeyboardKey.keyD, meta: true, shift: true)],
  // ),
  readPlan(
    id: 'plan',
    label: 'ver o plano da sessão em foco',
    hint: 'abre o último plano num painel de leitura, ao lado dela',
    group: MxGroup.sessions,
    defaults: [MxChord(LogicalKeyboardKey.keyL, meta: true, shift: true)],
  ),
  refreshGit(
    id: 'refresh',
    label: 'reler o git',
    hint: 'worktrees e branches, sem esperar os dez segundos',
    group: MxGroup.window,
    defaults: [MxChord(LogicalKeyboardKey.keyR, meta: true)],
  ),
  dailyReport(
    id: 'report',
    label: 'relatório do dia',
    hint: 'reúne o dia e pede a prosa ao claude, num painel de leitura',
    group: MxGroup.window,
    defaults: [MxChord(LogicalKeyboardKey.keyR, meta: true, shift: true)],
  ),
  zoomIn(
    id: 'zoom-in',
    label: 'aumentar o corpo do painel',
    hint: 'só o painel em foco; a base de todos está em aparência',
    group: MxGroup.view,
    // Duas por padrão porque ⌘+ *é* ⌘⇧= no teclado: quem pensa "mais" segura
    // o shift sem perceber, e quem pensa "⌘=" não segura. As duas são a mesma
    // tecla física, e recusar uma delas seria recusar metade das mãos.
    defaults: [
      MxChord(LogicalKeyboardKey.equal, meta: true),
      MxChord(LogicalKeyboardKey.equal, meta: true, shift: true),
    ],
  ),
  zoomOut(
    id: 'zoom-out',
    label: 'diminuir o corpo do painel',
    group: MxGroup.view,
    defaults: [MxChord(LogicalKeyboardKey.minus, meta: true)],
  ),
  zoomReset(
    id: 'zoom-reset',
    label: 'voltar o painel ao corpo base',
    hint: '⌘0 fica livre: ⌘1 a ⌘9 são as nove sessões da lateral',
    group: MxGroup.view,
    defaults: [MxChord(LogicalKeyboardKey.digit0, meta: true)],
  ),
  settings(
    id: 'settings',
    label: 'configurações',
    hint: 'esta tela',
    group: MxGroup.window,
    defaults: [
      MxChord(LogicalKeyboardKey.comma, meta: true),
      MxChord(LogicalKeyboardKey.keyP, meta: true, shift: true),
    ],
  );

  const MxAction({
    required this.id,
    required this.label,
    required this.group,
    required this.defaults,
    this.hint,
  });

  /// A chave no config. Não é o `name` de propósito: renomear a constante é
  /// refactor, e um refactor não pode apagar os atalhos de ninguém.
  final String id;
  final String label;
  final String? hint;
  final MxGroup group;
  final List<MxChord> defaults;
}

/// O mapa de teclas, do jeito que o usuário deixou.
///
/// Uma ação tem uma *lista* de combinações porque duas delas sempre tiveram:
/// ⌃⇥ e ⌘⌥↓ são o mesmo "próximo painel", uma pra mão que está no terminal e
/// outra pra mão que está nas setas. Um campo só teria forçado escolher.
class MxKeymap {
  final Map<MxAction, List<MxChord>> _bound = {
    for (final a in MxAction.values) a: [...a.defaults],
  };

  List<MxChord> operator [](MxAction action) => List.unmodifiable(_bound[action]!);

  /// Quem responde por esta combinação hoje.
  MxAction? owner(MxChord chord) =>
      MxAction.values.firstWhereOrNull((a) => _bound[a]!.contains(chord));

  /// A ação que este evento de teclado dispara, se alguma.
  MxAction? match(KeyEvent event) =>
      MxAction.values.firstWhereOrNull((a) => _bound[a]!.any((c) => c.accepts(event)));

  /// Dá [chord] a [action] e devolve de quem ela foi tirada.
  ///
  /// Roubar em vez de recusar: duas ações na mesma tecla é um estado em que
  /// uma delas simplesmente não acontece, e nada na tela explicaria qual. Quem
  /// perdeu o atalho é dito em voz alta pela tela que chamou isto.
  ///
  /// [replacing] é a combinação que estava naquele lugar da lista — passar ela
  /// é o que faz "trocar este atalho" trocar, em vez de virar um segundo.
  MxAction? bind(MxAction action, MxChord chord, {MxChord? replacing}) {
    final previous = owner(chord);
    if (previous != null) _bound[previous]!.remove(chord);
    final list = _bound[action]!;
    final at = replacing == null ? -1 : list.indexOf(replacing);
    if (at >= 0) {
      list[at] = chord;
    } else if (!list.contains(chord)) {
      list.add(chord);
    }
    return previous == action ? null : previous;
  }

  void unbind(MxAction action, MxChord chord) => _bound[action]!.remove(chord);

  void reset() {
    for (final a in MxAction.values) {
      _bound[a]!
        ..clear()
        ..addAll(a.defaults);
    }
  }

  void resetAction(MxAction action) {
    // O padrão pode estar na mão de outra ação — devolver sem tirar de lá
    // deixaria a tecla com dois donos.
    for (final chord in action.defaults) {
      if (owner(chord) case final other? when other != action) _bound[other]!.remove(chord);
    }
    _bound[action]!
      ..clear()
      ..addAll(action.defaults);
  }

  bool isDefault(MxAction action) =>
      const ListEquality<MxChord>().equals(_bound[action]!, action.defaults);

  bool get allDefault => MxAction.values.every(isDefault);

  /// Só o que difere do padrão vai pro disco.
  ///
  /// Assim um atalho novo que apareça numa versão futura chega em quem já tem
  /// config gravado — o que um dump do mapa inteiro teria congelado.
  Map<String, dynamic> toJson() => {
    for (final a in MxAction.values)
      if (!isDefault(a)) a.id: _bound[a]!.map((c) => c.id).toList(),
  };

  void load(Object? json) {
    if (json is! Map) return;
    for (final action in MxAction.values) {
      final saved = json[action.id];
      if (saved is! List) continue;
      // Uma combinação que esta versão não sabe ler é descartada sozinha; o
      // resto da linha continua valendo.
      final chords = saved
          .whereType<String>()
          .map(MxChord.parse)
          .nonNulls
          .where((c) => c.valid)
          .toList();
      _bound[action]!
        ..clear()
        ..addAll(chords);
    }
    // Duas ações podem ter saído do disco com a mesma tecla se o arquivo foi
    // editado à mão. A primeira na ordem da enum fica com ela.
    final seen = <MxChord>{};
    for (final a in MxAction.values) {
      _bound[a]!.retainWhere(seen.add);
    }
  }
}
