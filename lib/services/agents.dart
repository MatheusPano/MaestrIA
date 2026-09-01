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
class AgentsWatcher {
  Timer? _timer;
  final _controller = StreamController<List<AgentInfo>>.broadcast();
  bool _inFlight = false;

  Stream<List<AgentInfo>> get updates => _controller.stream;
  List<AgentInfo> latest = const [];

  void start({Duration every = const Duration(seconds: 2)}) {
    _timer?.cancel();
    _tick();
    _timer = Timer.periodic(every, (_) => _tick());
  }

  void stop() => _timer?.cancel();

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
