import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/hooks.dart';

Map<String, dynamic> ev(String name, [Map<String, dynamic> extra = const {}]) => {
      'hook_event_name': name,
      'session_id': 'sess-1',
      'cwd': '/repo',
      ...extra,
    };

void main() {
  group('HookReducer', () {
    test('a turn walks from prompt to tool to idle', () {
      final s = HookState();
      HookReducer.apply(s, 'SessionStart', ev('SessionStart'));
      expect(s.status, ClaudeStatus.ready);

      HookReducer.apply(s, 'UserPromptSubmit',
          ev('UserPromptSubmit', {'user_input': 'troca o middleware  de sessão'}));
      expect(s.status, ClaudeStatus.working);
      expect(s.prompts, 1);
      expect(s.lastPrompt, 'troca o middleware de sessão');

      HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'Edit',
            'tool_input': {'file_path': '/repo/lib/auth/jwt.dart'},
          }));
      expect(s.status, ClaudeStatus.tool);
      expect(s.activeTool, 'Edit');
      expect(s.lastToolTarget, 'jwt.dart');
      expect(s.subtitle, startsWith('Edit(jwt.dart)'));

      HookReducer.apply(s, 'PostToolUse', ev('PostToolUse', {'tool_name': 'Edit'}));
      expect(s.status, ClaudeStatus.working);
      expect(s.activeTool, isNull);

      HookReducer.apply(
          s, 'Stop', ev('Stop', {'last_assistant_message': 'Troquei os 7 call sites.'}));
      expect(s.status, ClaudeStatus.idle);
      expect(s.subtitle, 'Troquei os 7 call sites.');
    });

    test('a permission prompt is the state that earns a badge', () {
      final s = HookState();
      HookReducer.apply(s, 'Notification',
          ev('Notification', {'notification_type': 'permission_prompt'}));
      expect(s.status, ClaudeStatus.waitingPermission);
      expect(s.status.needsHuman, isTrue);
    });

    test('a question is answered, not authorised', () {
      final s = HookState();
      HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'AskUserQuestion',
            'tool_input': {
              'questions': [
                {
                  'question': 'Com o formulário abrindo direto, como as receitas aparecem?',
                  'header': 'Receitas',
                },
                {'question': 'E o briefing?', 'header': 'Briefing'},
              ],
            },
          }));
      // Waiting from the call itself, not from the prompt that follows it.
      expect(s.status, ClaudeStatus.waitingAnswer);
      expect(s.status.needsHuman, isTrue);
      expect(s.subtitle, 'pergunta: Receitas (+1)');
      expect(s.status.callToAction, 'te faz uma pergunta');

      // The permission prompt fires for a question too, and must not turn the
      // row back into a lock.
      HookReducer.apply(s, 'Notification',
          ev('Notification', {'notification_type': 'permission_prompt'}));
      expect(s.status, ClaudeStatus.waitingAnswer);

      HookReducer.apply(s, 'PostToolUse', ev('PostToolUse', {'tool_name': 'AskUserQuestion'}));
      expect(s.status, ClaudeStatus.working);
      expect(s.question, isNull);
    });

    test('a question with no header is named by what it asks', () {
      final s = HookState();
      HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'AskUserQuestion',
            'tool_input': {
              'questions': [
                {'question': 'Sobrescrevo o arquivo?'},
              ],
            },
          }));
      expect(s.subtitle, 'pergunta: Sobrescrevo o arquivo?');
    });

    test('a tool that acts still gets the lock', () {
      final s = HookState();
      HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'Bash',
            'tool_input': {'command': 'rm -rf build'},
          }));
      HookReducer.apply(s, 'Notification',
          ev('Notification', {'notification_type': 'permission_prompt'}));
      expect(s.status, ClaudeStatus.waitingPermission);
      expect(s.status.callToAction, 'quer aprovação');
    });

    test('needing input is distinct from being merely idle', () {
      final s = HookState();
      HookReducer.apply(
          s,
          'Notification',
          ev('Notification', {
            'notification_type': 'agent_needs_input',
            'message': 'Posso rodar os testes?',
          }));
      expect(s.status, ClaudeStatus.waitingInput);
      expect(s.subtitle, 'Posso rodar os testes?');

      HookReducer.apply(s, 'Stop', ev('Stop'));
      expect(s.status.needsHuman, isFalse);
    });

    test('a bash command becomes a short target', () {
      final s = HookState();
      HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'tool_name': 'Bash',
            'tool_input': {'command': 'flutter test --reporter compact -j 4 --coverage'},
          }));
      expect(s.lastToolTarget!.length, lessThanOrEqualTo(29));
      expect(s.lastToolTarget, endsWith('…'));
    });

    test('session end is terminal only when it really ended', () {
      final s = HookState();
      HookReducer.apply(s, 'SessionEnd', ev('SessionEnd', {'end_reason': 'logout'}));
      expect(s.status, ClaudeStatus.ended);
    });

    // Caught on the first real run: fourteen live panels read "encerrada"
    // because resuming reports SessionEnd on the way in.
    test('a resume or a clear is a transition, not a death', () {
      for (final reason in ['resume', 'clear']) {
        final s = HookState();
        HookReducer.apply(s, 'SessionStart', ev('SessionStart'));
        HookReducer.apply(s, 'SessionEnd', ev('SessionEnd', {'end_reason': reason}));
        expect(s.status, ClaudeStatus.ready, reason: reason);
      }
    });
  });

  // No hook says "the prompt is up": SessionStart never reaches an `http`
  // hook, so a panel would sit on its launch spinner until you typed.
  group('settling', () {
    test('a session that has only just launched settles into ready', () {
      final s = HookState();
      expect(s.status, ClaudeStatus.starting);
      expect(s.settle(), isTrue);
      expect(s.status, ClaudeStatus.ready);
      expect(s.subtitle, 'pronto');
    });

    test('settling never walks a session that already spoke backwards', () {
      final s = HookState();
      HookReducer.apply(s, 'UserPromptSubmit', ev('UserPromptSubmit', {'user_input': 'vai'}));
      expect(s.settle(), isFalse);
      expect(s.status, ClaudeStatus.working);
    });
  });

  group('titles', () {
    test('a branch with a task id gives the panel its name', () {
      final w = WorktreeInfo(
          path: '/repo/.claude/worktrees/TASK-47730',
          branch: 'feature/TASK#47730',
          isMain: false);
      expect(w.shortLabel, 'TASK#47730');
    });

    test('a branch without one falls back to its last segment', () {
      final w = WorktreeInfo(path: '/repo', branch: 'chore/cleanup', isMain: true);
      expect(w.shortLabel, 'cleanup');
    });
  });

  // The list is read as the answer to "what did this session do", so what it
  // leaves out matters as much as what it keeps.
  group('touched files', () {
    Map<String, dynamic> wrote(String tool, Map<String, dynamic> input) =>
        ev('PostToolUse', {'tool_name': tool, 'tool_input': input});

    test('only the tools that write make the list', () {
      final s = HookState();
      for (final call in [
        ['Write', 'file_path', '/repo/relatorio.md'],
        ['Edit', 'file_path', '/repo/lib/auth.dart'],
        ['MultiEdit', 'file_path', '/repo/lib/theme.dart'],
        ['NotebookEdit', 'notebook_path', '/repo/analise.ipynb'],
        ['Read', 'file_path', '/repo/leu-e-nao-mexeu.md'],
        ['Grep', 'pattern', 'TODO'],
      ]) {
        HookReducer.apply(s, 'PostToolUse', wrote(call[0], {call[1]: call[2]}));
      }
      expect(s.touched, [
        '/repo/relatorio.md',
        '/repo/lib/auth.dart',
        '/repo/lib/theme.dart',
        '/repo/analise.ipynb',
      ]);
    });

    // Bash is the one that could write and is left out anyway: reading a
    // command line means guessing, and a guess here is worse than a gap.
    test('a bash command contributes nothing, however file-shaped it looks', () {
      final s = HookState();
      HookReducer.apply(s, 'PostToolUse',
          wrote('Bash', {'command': 'mv relatorio.md ~/Documents/relatorio.md'}));
      expect(s.touched, isEmpty);
    });

    // Quick Look is handed this path, and the Finder has no cwd to resolve
    // against.
    test('a relative path is resolved against the session cwd', () {
      final s = HookState();
      HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': './saida/lista.csv'}));
      HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': 'notas.md'}));
      expect(s.touched, ['/repo/saida/lista.csv', '/repo/notas.md']);
    });

    test('a file rewritten all afternoon is one row, where it first appeared', () {
      final s = HookState();
      HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': '/repo/a.md'}));
      HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': '/repo/b.md'}));
      HookReducer.apply(s, 'PostToolUse', wrote('Edit', {'file_path': '/repo/a.md'}));
      expect(s.touched, ['/repo/a.md', '/repo/b.md']);
    });

    test('past the cap it is the oldest paths that go', () {
      final s = HookState();
      for (var i = 0; i < HookState.maxTouched + 5; i++) {
        HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': '/repo/f$i.md'}));
      }
      expect(s.touched.length, HookState.maxTouched);
      expect(s.touched.first, '/repo/f5.md');
      expect(s.touched.last, '/repo/f${HookState.maxTouched + 4}.md');
    });

    test('a malformed payload is dropped, not recorded as a blank row', () {
      final s = HookState();
      HookReducer.apply(s, 'PostToolUse', wrote('Write', {'file_path': ''}));
      HookReducer.apply(s, 'PostToolUse', ev('PostToolUse', {'tool_name': 'Write'}));
      HookReducer.apply(s, 'PostToolUse', ev('PostToolUse', {}));
      expect(s.touched, isEmpty);
    });
  });

  // The payload shapes here are transcripts of real events from Claude Code
  // 2.1.251, not invented ones: two `Explore` forks in parallel, and one
  // launched with `run_in_background`.
  group('HookReducer subagents', () {
    Map<String, dynamic> agentCall(String description, String type, {bool background = false}) =>
        ev('PreToolUse', {
          'tool_name': 'Agent',
          'tool_use_id': 'toolu_$description',
          'tool_input': {
            'description': description,
            'subagent_type': type,
            'run_in_background': background,
          },
        });

    Map<String, dynamic> fromAgent(String name, String id, String type,
            [Map<String, dynamic> extra = const {}]) =>
        ev(name, {'agent_id': id, 'agent_type': type, ...extra});

    test('two forks started together each keep their own errand', () {
      final s = HookState();
      HookReducer.apply(s, 'UserPromptSubmit', ev('UserPromptSubmit', {'user_input': 'divide'}));

      HookReducer.apply(s, 'PreToolUse', agentCall('find HookServer', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a03', 'Explore'));
      HookReducer.apply(s, 'PreToolUse', agentCall('find AgentsWatcher', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a7e', 'Explore'));

      expect(s.subagents.keys, ['a03', 'a7e']);
      expect(s.subagents['a03']!.title, 'find HookServer');
      expect(s.subagents['a7e']!.title, 'find AgentsWatcher');
      expect(s.liveSubagents.length, 2);
      expect(s.subtitle, '2 agentes rodando');
    });

    test("a fork's tool call is the fork's, not the panel's", () {
      final s = HookState();
      HookReducer.apply(s, 'PreToolUse', agentCall('find HookServer', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a03', 'Explore'));
      final parked = s.activeTool;

      HookReducer.apply(
        s,
        'PreToolUse',
        fromAgent('PreToolUse', 'a03', 'Explore', {
          'tool_name': 'Grep',
          'tool_input': {'pattern': 'class HookServer'},
        }),
      );

      // The panel is still parked on the `Agent` call it made.
      expect(s.activeTool, parked);
      expect(s.subagents['a03']!.activeTool, 'Grep');
      expect(s.subagents['a03']!.subtitle, contains('Grep(class HookServer)'));
    });

    test('what a fork writes is still what the session produced', () {
      final s = HookState();
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a03', 'fork'));
      HookReducer.apply(
        s,
        'PostToolUse',
        fromAgent('PostToolUse', 'a03', 'fork', {
          'tool_name': 'Edit',
          'tool_input': {'file_path': '/repo/lib/services/store.dart'},
        }),
      );
      expect(s.touched, ['/repo/lib/services/store.dart']);
    });

    test('the Agent call closes its row with what it cost', () {
      final s = HookState();
      HookReducer.apply(s, 'PreToolUse', agentCall('find HookServer', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a03', 'Explore'));
      HookReducer.apply(
        s,
        'SubagentStop',
        fromAgent('SubagentStop', 'a03', 'Explore', {
          'last_assistant_message': 'HookServer fica em lib/services/hooks.dart',
        }),
      );
      HookReducer.apply(
        s,
        'PostToolUse',
        ev('PostToolUse', {
          'tool_name': 'Agent',
          'tool_input': {'description': 'find HookServer', 'subagent_type': 'Explore'},
          'tool_response': {
            'status': 'completed',
            'agentId': 'a03',
            'agentType': 'Explore',
            'totalDurationMs': 7895,
            'totalTokens': 12463,
          },
        }),
      );

      final agent = s.subagents['a03']!;
      expect(agent.running, isFalse);
      expect(agent.subtitle, 'Explore · 7s · 12.5k tokens');
      expect(s.liveSubagents, isEmpty);
    });

    test('a background fork survives the Stop that sends the panel back to the prompt', () {
      final s = HookState();
      HookReducer.apply(s, 'PreToolUse', agentCall('count dart files', 'Explore', background: true));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a71', 'Explore'));
      HookReducer.apply(
        s,
        'PostToolUse',
        ev('PostToolUse', {
          'tool_name': 'Agent',
          'tool_input': {
            'description': 'count dart files',
            'subagent_type': 'Explore',
            'run_in_background': true,
          },
          'tool_response': {'status': 'async_launched', 'agentId': 'a71'},
        }),
      );
      HookReducer.apply(
        s,
        'Stop',
        ev('Stop', {
          'last_assistant_message': 'launched',
          'background_tasks': [
            {
              'id': 'a71',
              'type': 'subagent',
              'status': 'running',
              'description': 'count dart files',
              'agent_type': 'Explore',
            },
          ],
        }),
      );

      expect(s.status, ClaudeStatus.idle);
      expect(s.subagents['a71']!.background, isTrue);
      expect(s.subagents['a71']!.running, isTrue);
      // The whole point: the panel does not get to say "pronto" over it.
      expect(s.subtitle, '1 agente rodando');

      HookReducer.apply(s, 'SubagentStop', fromAgent('SubagentStop', 'a71', 'Explore'));
      expect(s.liveSubagents, isEmpty);
      expect(s.subtitle, 'launched');
    });

    test('a background fork whose stop never lands is closed by the next Stop', () {
      final s = HookState();
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a71', 'Explore'));
      HookReducer.apply(
        s,
        'Stop',
        ev('Stop', {
          'background_tasks': [
            {'id': 'a71', 'type': 'subagent', 'status': 'running', 'description': 'x'},
          ],
        }),
      );
      expect(s.subagents['a71']!.running, isTrue);

      HookReducer.apply(s, 'Stop', ev('Stop', {'background_tasks': []}));
      expect(s.subagents['a71']!.running, isFalse);
    });

    test('finished forks clear on the next prompt, running ones stay', () {
      final s = HookState();
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a03', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a71', 'Explore'));
      HookReducer.apply(s, 'SubagentStop', fromAgent('SubagentStop', 'a03', 'Explore'));

      HookReducer.apply(s, 'UserPromptSubmit', ev('UserPromptSubmit', {'user_input': 'e agora'}));
      expect(s.subagents.keys, ['a71']);
    });

    test('an Agent call that never spawned does not misname the next fork', () {
      final s = HookState();
      HookReducer.apply(s, 'PreToolUse', agentCall('negado', 'Explore'));
      HookReducer.apply(s, 'Stop', ev('Stop', {'background_tasks': []}));
      expect(s.pendingAgents, isEmpty);

      HookReducer.apply(s, 'PreToolUse', agentCall('o certo', 'Explore'));
      HookReducer.apply(s, 'SubagentStart', fromAgent('SubagentStart', 'a99', 'Explore'));
      expect(s.subagents['a99']!.title, 'o certo');
    });
  });

  // The ghost rows: nameless lines reading "· 0s" that no fork accounted for.
  group('HookReducer subagents that were never really there', () {
    test('an event we do not handle never conjures a row', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'Notification',
        ev('Notification', {'agent_id': 'a99', 'notification_type': 'idle_prompt'}),
      );
      HookReducer.apply(s, 'SessionEnd', ev('SessionEnd', {'agent_id': 'a99'}));
      expect(s.subagents, isEmpty);
    });

    test('a result for a fork nobody saw start is dropped, not drawn', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'PostToolUse',
        ev('PostToolUse', {
          'tool_name': 'Agent',
          'tool_input': const <String, dynamic>{},
          'tool_response': {'status': 'completed', 'agentId': 'a99', 'totalDurationMs': 0},
        }),
      );
      expect(s.subagents, isEmpty);
    });

    test('a launch receipt does create one, because it carries the errand', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'PostToolUse',
        ev('PostToolUse', {
          'tool_name': 'Agent',
          'tool_input': {'description': 'contar arquivos', 'subagent_type': 'Explore'},
          'tool_response': {'status': 'async_launched', 'agentId': 'a71'},
        }),
      );
      expect(s.subagents['a71']!.title, 'contar arquivos');
      expect(s.subagents['a71']!.background, isTrue);
    });

    test('a row always has something to call itself', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'SubagentStart',
        ev('SubagentStart', {'agent_id': 'a0388a6f018cb508f', 'agent_type': ''}),
      );
      expect(s.subagents['a0388a6f018cb508f']!.title, 'subagente a0388a6f');
      expect(s.subagents['a0388a6f018cb508f']!.subtitle, isNot(startsWith(' · ')));
    });

    test('a duration the tool did not measure is not reported as zero', () {
      final s = HookState();
      HookReducer.apply(s, 'SubagentStart', ev('SubagentStart', {'agent_id': 'a03', 'agent_type': 'Explore'}));
      HookReducer.apply(
        s,
        'PostToolUse',
        ev('PostToolUse', {
          'tool_name': 'Agent',
          'tool_input': {'description': 'x'},
          'tool_response': {'status': 'completed', 'agentId': 'a03', 'totalDurationMs': 0},
        }),
      );
      expect(s.subagents['a03']!.durationMs, isNull);
      expect(s.subagents['a03']!.running, isFalse);
    });

    test('the brief and the trail are what the row cannot show', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'PreToolUse',
        ev('PreToolUse', {
          'tool_name': 'Agent',
          'tool_input': {
            'description': 'map invite flow',
            'subagent_type': 'Explore',
            'prompt': 'Mapeie o fluxo de convite no app. Não mude nada.',
          },
        }),
      );
      HookReducer.apply(s, 'SubagentStart', ev('SubagentStart', {'agent_id': 'a11', 'agent_type': 'Explore'}));
      HookReducer.apply(
        s,
        'PreToolUse',
        ev('PreToolUse', {
          'agent_id': 'a11',
          'agent_type': 'Explore',
          'tool_name': 'Grep',
          'tool_input': {'pattern': 'invite'},
        }),
      );
      HookReducer.apply(
        s,
        'PreToolUse',
        ev('PreToolUse', {
          'agent_id': 'a11',
          'agent_type': 'Explore',
          'tool_name': 'Read',
          'tool_input': {'file_path': '/repo/lib/invite.dart'},
        }),
      );

      final agent = s.subagents['a11']!;
      expect(agent.prompt, startsWith('Mapeie o fluxo'));
      expect(agent.trail, ['Grep(invite)', 'Read(invite.dart)']);
      expect(agent.tools, 2);
    });

    test('the trail is capped, keeping where it is over where it was', () {
      final s = HookState();
      HookReducer.apply(s, 'SubagentStart', ev('SubagentStart', {'agent_id': 'a11', 'agent_type': 'Explore'}));
      for (var i = 0; i < SubagentState.maxTrail + 3; i++) {
        HookReducer.apply(
          s,
          'PreToolUse',
          ev('PreToolUse', {
            'agent_id': 'a11',
            'agent_type': 'Explore',
            'tool_name': 'Read',
            'tool_input': {'file_path': '/repo/f$i.dart'},
          }),
        );
      }
      final trail = s.subagents['a11']!.trail;
      expect(trail.length, SubagentState.maxTrail);
      expect(trail.last, 'Read(f${SubagentState.maxTrail + 2}.dart)');
    });

    test('a background task the session cannot name is not a row', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'Stop',
        ev('Stop', {
          'background_tasks': [
            {'id': 'a99', 'type': 'subagent', 'status': 'pending'},
            {'id': 'a71', 'type': 'subagent', 'status': 'running', 'description': 'contar'},
            {'id': 'sh1', 'type': 'shell', 'status': 'running', 'command': 'sleep 30'},
          ],
        }),
      );
      expect(s.subagents.keys, ['a71']);
    });
  });
}
