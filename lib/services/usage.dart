/// Quanto do plano já foi gasto -- a mesma leitura que o `/usage` do Claude
/// Code mostra, feita daqui.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'paths.dart';
import 'shell.dart';

/// Uma das janelas em que o plano é contado: a sessão de 5 horas, a semana, e
/// a semana de um modelo em separado.
class UsageWindow {
  const UsageWindow({required this.label, required this.percent, this.resetsAt});

  final String label;

  /// Quanto da janela já foi, em pontos percentuais. Pode passar de 100: a api
  /// continua contando o que rodou além do teto em vez de parar em cem.
  final int percent;

  /// Quando ela zera, ou nulo quando a resposta não disse -- uma janela sem
  /// data ainda vale pelo número.
  final DateTime? resetsAt;
}

/// De quem é o plano.
///
/// Vem do config do `claude` e não da resposta de uso, que responde números e
/// mais nada. Todos os campos são opcionais porque um config de uma versão
/// diferente pode não ter nenhum deles, e três nomes a menos não é motivo pra
/// esconder as barras.
class UsageAccount {
  const UsageAccount({this.email, this.organization, this.plan});

  final String? email;
  final String? organization;
  final String? plan;

  bool get isEmpty => email == null && organization == null && plan == null;
}

/// O resultado de uma leitura: as janelas, ou o motivo de não ter dado.
///
/// O motivo é uma frase pra ler na tela, e não um código: quem abre esta
/// seção quer saber se pode continuar trabalhando, e "a credencial venceu" é
/// uma resposta a isso -- `401` não é.
class UsageReading {
  const UsageReading.ok(this.windows, {this.account = const UsageAccount(), this.credits})
    : problem = null;

  const UsageReading.failed(this.problem)
    : windows = const [],
      account = const UsageAccount(),
      credits = null;

  final List<UsageWindow> windows;
  final UsageAccount account;

  /// A linha dos créditos extras, já escrita, quando eles estão ligados. Nulo
  /// é o caso comum, e aí não há linha nenhuma a mostrar.
  final String? credits;

  /// Por que não deu, ou nulo quando deu.
  final String? problem;

  bool get ok => problem == null;
}

/// A leitura de uso, tirada de onde o próprio Claude Code a tira.
class Usage {
  /// O mesmo endereço que o `/usage` consulta. Fora da documentação pública,
  /// então uma resposta em formato novo é uma possibilidade real e não uma
  /// hipótese -- ver [parse], que ignora o que não reconhece em vez de estourar.
  static const endpoint = 'https://api.anthropic.com/api/oauth/usage';

  static const _keychainItem = 'Claude Code-credentials';

  /// Um teto pra não deixar a seção girando: sem rede, um `HttpClient` fica
  /// pendurado no tempo do sistema, que é medido em minutos.
  static const _patience = Duration(seconds: 10);

  /// A leitura, pra quem desenha.
  ///
  /// Uma casca em cima de [reader] pra que a tela chame sempre a mesma coisa
  /// e o teste de widget possa trocar o que está por baixo.
  static Future<UsageReading> read() => reader();

  /// De onde [read] tira a resposta.
  ///
  /// O ponto de troca do teste de widget, que precisa das barras desenhadas
  /// sem uma volta na rede -- e que não pode chamar a de verdade nem em
  /// último caso, porque ela leria a credencial de quem rodou a suíte. Quem
  /// troca devolve com [resetReader].
  @visibleForTesting
  static Future<UsageReading> Function() reader = _fetch;

  @visibleForTesting
  static void resetReader() => reader = _fetch;

  static Future<UsageReading> _fetch() async {
    final token = await accessToken();
    if (token == null) {
      return const UsageReading.failed(
        'não achei a credencial do claude nesta máquina — faça login com `claude` uma vez',
      );
    }

    final client = HttpClient()..connectionTimeout = _patience;
    try {
      final request = await client.getUrl(Uri.parse(endpoint));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close().timeout(_patience);
      final body = await utf8.decoder.bind(response).join().timeout(_patience);

      // 401 é o caso que vai acontecer: o token de oauth vence, e quem o
      // renova é o `claude`, não nós -- renovar por conta própria invalidaria
      // o que a cli tem na mão.
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const UsageReading.failed(
          'a credencial venceu — ela se renova sozinha da próxima vez que você usar o claude',
        );
      }
      if (response.statusCode != 200) {
        return UsageReading.failed('a api respondeu ${response.statusCode}');
      }
      return parse(body, account: await account());
    } on SocketException {
      return const UsageReading.failed('sem rede pra perguntar');
    } on TimeoutException {
      // Separado do resto porque a frase de um `TimeoutException` cru --
      // "after 0:00:10.000000: Future not completed" -- não é pra ninguém ler.
      return const UsageReading.failed('a api demorou demais pra responder');
    } on Exception catch (e) {
      return UsageReading.failed('não deu pra ler: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// A resposta virada em janelas.
  ///
  /// A lista lida é a `limits`, e não os campos soltos (`five_hour`,
  /// `seven_day`, ...) que vêm ao lado dela: é a mesma informação, mas ali
  /// cada janela traz o que é, então uma que a api passe a mandar aparece
  /// aqui sem este arquivo saber o nome dela. Ver [_labelFor].
  @visibleForTesting
  static UsageReading parse(String body, {UsageAccount account = const UsageAccount()}) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return const UsageReading.failed('a api respondeu uma coisa que não é json');
    }

    final limits = json['limits'];
    if (limits is! List) return const UsageReading.failed('a resposta não trouxe limite nenhum');

    final windows = <UsageWindow>[];
    for (final limit in limits.whereType<Map<String, dynamic>>()) {
      final percent = limit['percent'];
      if (percent is! num) continue;
      windows.add(
        UsageWindow(
          label: _labelFor(limit),
          percent: percent.round(),
          resetsAt: DateTime.tryParse(limit['resets_at'] as String? ?? '')?.toLocal(),
        ),
      );
    }
    if (windows.isEmpty) return const UsageReading.failed('a resposta não trouxe limite nenhum');

    return UsageReading.ok(windows, account: account, credits: _creditsOf(json));
  }

  /// Como uma janela se chama na tela.
  ///
  /// A `weekly_scoped` é a única que precisa olhar pra dentro: o que a separa
  /// da semanal comum é o modelo no `scope`, e é esse nome -- "Fable" -- que
  /// a linha tem de dizer, senão são duas barras "semanal" sem diferença
  /// visível entre elas.
  static String _labelFor(Map<String, dynamic> limit) {
    final kind = limit['kind'] as String? ?? '';
    final scope = limit['scope'];
    final model = scope is Map ? _displayName(scope['model']) : null;
    return switch (kind) {
      'session' => 'sessão (5h)',
      'weekly_all' => 'semanal (7 dias)',
      'weekly_scoped' when model != null => 'semanal $model',
      'weekly_scoped' => 'semanal por modelo',
      // Uma janela que a api passou a mandar e este código não conhece entra
      // com o nome cru: uma linha estranha é melhor que uma linha faltando,
      // porque é a faltando que faz a soma na cabeça de quem lê dar errado.
      '' => 'limite',
      _ => kind.replaceAll('_', ' '),
    };
  }

  static String? _displayName(Object? model) =>
      model is Map ? model['display_name'] as String? : null;

  /// Os créditos extras, escritos, e só quando estão ligados.
  ///
  /// Quem não os habilitou não tem uma linha "desabilitado" pra ler: isso é
  /// uma oferta, e a seção é um medidor.
  static String? _creditsOf(Map<String, dynamic> json) {
    final spend = json['spend'];
    if (spend is! Map || spend['enabled'] != true) return null;
    final used = _money(spend['used']);
    final limit = _money(spend['limit']);
    if (used == null) return null;
    return limit == null ? 'créditos extras: $used' : 'créditos extras: $used de $limit';
  }

  /// `{amount_minor: 1234, currency: 'BRL', exponent: 2}` virado em `BRL 12,34`.
  ///
  /// O expoente vem na resposta em vez de ser deduzido da moeda porque nem
  /// toda moeda tem duas casas -- e a api já sabe qual é a certa.
  static String? _money(Object? value) {
    if (value is! Map) return null;
    final minor = value['amount_minor'];
    if (minor is! num) return null;
    final exponent = (value['exponent'] as num?)?.toInt() ?? 2;
    final amount = minor / _pow10(exponent);
    final currency = value['currency'] as String? ?? '';
    return '$currency ${amount.toStringAsFixed(exponent).replaceAll('.', ',')}'.trim();
  }

  static num _pow10(int exponent) {
    var out = 1;
    for (var i = 0; i < exponent; i++) {
      out *= 10;
    }
    return out;
  }

  /// O token que o `claude` guardou ao logar.
  ///
  /// Dois lugares porque são dois sistemas: no Linux a credencial é um arquivo
  /// em `~/.claude`, no macOS ela está no chaveiro e o `security` é quem a tira
  /// de lá. O arquivo vem primeiro porque é o teste mais barato dos dois -- e
  /// porque a chamada ao chaveiro é a que pode abrir um diálogo do sistema.
  ///
  /// O `HOME` sai de [mxStateHome] e não do ambiente pelo mesmo motivo de
  /// sempre: sob teste ele aponta pra uma pasta descartável, e assim a suíte
  /// não lê a credencial de verdade de quem a rodou.
  @visibleForTesting
  static Future<String?> accessToken() async {
    final file = File('$mxStateHome/.claude/.credentials.json');
    if (file.existsSync()) {
      final fromFile = _tokenIn(await file.readAsString());
      if (fromFile != null) return fromFile;
    }
    // O chaveiro é a única coisa aqui que [mxStateHome] não desvia, e ler o
    // token de verdade num `flutter test` é o tipo de efeito que uma suíte não
    // deve ter -- ainda mais um que pode abrir um diálogo do sistema no meio
    // dela. Ver [reader]: quem testa a tela troca a leitura inteira.
    if (!Platform.isMacOS || Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final r = await Sh.run('security find-generic-password -s ${Sh.q(_keychainItem)} -w');
    return r.ok ? _tokenIn(r.stdout) : null;
  }

  /// O `accessToken` de dentro do json da credencial, seja de que lado vier.
  /// Credencial pela metade é o mesmo que credencial nenhuma.
  static String? _tokenIn(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final oauth = json['claudeAiOauth'] as Map<String, dynamic>?;
      final token = oauth?['accessToken'] as String?;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// Quem está logado, lido do config do `claude`.
  ///
  /// Um extra: se o arquivo não estiver lá, ou tiver mudado de forma, a seção
  /// perde três linhas de cabeçalho e mantém o que ela existe pra mostrar.
  @visibleForTesting
  static Future<UsageAccount> account() async {
    try {
      final file = File('$mxStateHome/.claude.json');
      if (!file.existsSync()) return const UsageAccount();
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final who = json['oauthAccount'] as Map<String, dynamic>?;
      if (who == null) return const UsageAccount();
      return UsageAccount(
        email: who['emailAddress'] as String?,
        organization: who['organizationName'] as String?,
        plan: _planOf(who['organizationType'] as String?),
      );
    } catch (_) {
      return const UsageAccount();
    }
  }

  /// `claude_team` virado em `Claude team`. O que não estiver no mapa entra
  /// como veio, sem sublinhados -- é um rótulo, não uma decisão.
  static String? _planOf(String? type) {
    if (type == null || type.isEmpty) return null;
    return switch (type) {
      'claude_team' => 'Claude team',
      'claude_enterprise' => 'Claude enterprise',
      'claude_max' => 'Claude Max',
      'claude_pro' => 'Claude Pro',
      _ => type.replaceAll('_', ' '),
    };
  }
}
