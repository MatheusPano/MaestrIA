import 'dart:async';
import 'dart:convert';

import '../models.dart';
import 'shell.dart';

/// Polls `claude agents --json`.
///
/// Documented and machine-readable: it is where a panel of ours learns the
/// session id the CLI gave it, without which a restored panel could not
/// resume the conversation. Sessions the cockpit did not launch are listed
/// too, and ignored -- see [AppStore.applyAgents].
///
/// Em dois ritmos, porque cada volta é cara: `claude agents` é o CLI inteiro
/// subindo -- um processo de node de uns 170MB que vive um sexto de segundo,
/// dentro de um zsh de login que relê o perfil. A cada dois segundos isso é
/// trinta processos por minuto pra ler uma lista que quase nunca muda. O
/// ritmo [eagerEvery] só vale enquanto há uma sessão nossa sem id -- a
/// primeira volta depois de um launch é a que traz o id, e é dela que a
/// restauração depende; o resto do tempo o `SessionStart` dos hooks já disse
/// tudo isso, e a lista serve só pra saber o que está vivo fora daqui (ver
/// [AppStore.standingOf]), que pode esperar [idleEvery].
class AgentsWatcher {
  Timer? _timer;
  final _controller = StreamController<List<AgentInfo>>.broadcast();
  bool _inFlight = false;
  bool _eager = true;

  /// Com uma sessão esperando id.
  static const eagerEvery = Duration(seconds: 2);

  /// Sem nada esperando.
  static const idleEvery = Duration(seconds: 30);

  Stream<List<AgentInfo>> get updates => _controller.stream;
  List<AgentInfo> latest = const [];

  /// Se alguma sessão ainda está esperando o id dela. Quem sabe é a store,
  /// que olha a lista de painéis; aqui só se troca o relógio.
  bool get eager => _eager;

  set eager(bool value) {
    if (value == _eager) return;
    _eager = value;
    if (_timer == null) return;
    _schedule();
    // Voltar ao ritmo rápido é porque acabou de nascer uma sessão: a volta
    // que ela espera sai agora, não daqui a dois segundos.
    if (value) _tick();
  }

  void start() {
    _tick();
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_eager ? eagerEvery : idleEvery, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      final r = await Sh.run('claude agents --json');
      if (!r.ok) return;
      final start = r.stdout.indexOf('[');
      if (start < 0) return;
      final parsed = jsonDecode(r.stdout.substring(start));
      if (parsed is! List) return;
      latest = parsed
          .whereType<Map<String, dynamic>>()
          .map(AgentInfo.fromJson)
          .toList(growable: false);
      _controller.add(latest);
    } catch (_) {
      // Version skew in the CLI output must not take the UI down.
    } finally {
      _inFlight = false;
    }
  }
}
