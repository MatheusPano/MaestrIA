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

    // Bash entra só pra markdown, e só onde o comando diz o caminho: é assim
    // que metade dos documentos nasce (`cat > x.md <<'EOF'`), e uma sessão que
    // trabalha pelo shell tinha a fita de documentos sempre vazia.
    group('markdown escrito pela linha de comando', () {
      List<String> touchedBy(String command) {
        final s = HookState();
        HookReducer.apply(s, 'PostToolUse', wrote('Bash', {'command': command}));
        return s.touched;
      }

      test('o alvo de uma redireção', () {
        expect(touchedBy('printf "# oi\\n" > notas.md'), ['/repo/notas.md']);
        expect(touchedBy('echo linha >> docs/DIARIO.md'), ['/repo/docs/DIARIO.md']);
        expect(touchedBy("cat > 'meu plano.md' <<'EOF'\n# plano\nEOF"), ['/repo/meu plano.md']);
      });

      test('tee, sed -i, e o destino de um cp/mv', () {
        expect(touchedBy('cat x | tee resumo.md'), ['/repo/resumo.md']);
        expect(touchedBy("sed -i '' 's/a/b/' LEIAME.md"), ['/repo/LEIAME.md']);
        expect(touchedBy('cp modelo.md /tmp/copia.md'), ['/tmp/copia.md']);
      });

      test('o corpo do heredoc é texto, não comando', () {
        // A citação de markdown começa com `>` e não é uma redireção. Sem
        // pular o corpo, esta linha inventava um "inexistente.md".
        expect(
          touchedBy("cat > nota.md <<'MD'\n> veja o inexistente.md\nMD"),
          ['/repo/nota.md'],
        );
      });

      test('ler um markdown não é escrevê-lo', () {
        expect(touchedBy('cat PLANO.md'), isEmpty);
        expect(touchedBy('grep -n TODO docs/*.md'), isEmpty);
        expect(touchedBy('mv relatorio.md docs/'), isEmpty);
      });

      // O que entra na lista vira uma ficha clicável: um caminho que só o
      // shell sabe resolver abriria em nada.
      test('o que não é um caminho fica fora', () {
        expect(touchedBy(r'echo oi > "$OUT/nota.md"'), isEmpty);
        expect(touchedBy('sed -i "" s/a/b/ *.md'), isEmpty);
        expect(touchedBy('dart run tool/gen.dart 2>&1'), isEmpty);
      });

      // O resto do shell continua de fora: adivinhar o que um script escreveu
      // é pior que a omissão.
      test('um arquivo que não é markdown continua invisível', () {
        expect(touchedBy('dart format lib/main.dart > /dev/null'), isEmpty);
        expect(touchedBy('python3 gera.py > saida.json'), isEmpty);
      });
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

  // Um fork dispara os hooks do painel que o criou, marcados com `agent_id`.
  // O painel não mostra mais os forks, mas o que eles fizeram continua sendo
  // trabalho da sessão -- e o que eles *estão* fazendo continua não sendo o
  // estado dela.
  group('eventos vindos de um fork', () {
    Map<String, dynamic> fromAgent(String name, String id,
            [Map<String, dynamic> extra = const {}]) =>
        ev(name, {'agent_id': id, 'agent_type': 'Explore', ...extra});

    test("a chamada de ferramenta de um fork não é a do painel", () {
      final s = HookState();
      HookReducer.apply(s, 'PreToolUse', ev('PreToolUse', {
        'tool_name': 'Agent',
        'tool_input': {'description': 'find HookServer', 'subagent_type': 'Explore'},
      }));
      final parked = s.activeTool;

      HookReducer.apply(
        s,
        'PreToolUse',
        fromAgent('PreToolUse', 'a03', {
          'tool_name': 'Grep',
          'tool_input': {'pattern': 'class HookServer'},
        }),
      );

      // O painel segue parado na chamada `Agent` que ele mesmo fez.
      expect(s.activeTool, parked);
      expect(s.activeTool, 'Agent');
    });

    test('o que um fork escreve ainda é o que a sessão produziu', () {
      final s = HookState();
      HookReducer.apply(
        s,
        'PostToolUse',
        fromAgent('PostToolUse', 'a03', {
          'tool_name': 'Edit',
          'tool_input': {'file_path': '/repo/lib/services/store.dart'},
        }),
      );
      expect(s.touched, ['/repo/lib/services/store.dart']);
    });

    test('um evento de fork não mexe no status da sessão', () {
      final s = HookState();
      HookReducer.apply(s, 'UserPromptSubmit', ev('UserPromptSubmit', {'user_input': 'divide'}));
      HookReducer.apply(s, 'PostToolUse', fromAgent('PostToolUse', 'a03', {
        'tool_name': 'Read',
        'tool_input': {'file_path': '/repo/lib/models.dart'},
      }));
      expect(s.status, ClaudeStatus.working);
      expect(s.subtitle, 'divide');
    });
  });
}
