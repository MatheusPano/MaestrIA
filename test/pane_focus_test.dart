import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/panes.dart';

/// Uma sessão montada à mão: o que está em teste é quem fica com o teclado, e
/// pra isso não é preciso subir processo nenhum -- ver typing_test.
MxTab session(AppStore store, String id) {
  final tab = MxTab(
    id: id,
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: id,
  );
  store.tabs.add(tab);
  return tab;
}

/// Tudo o que esta sessão teria escrito no pty, na ordem.
List<String> watch(MxTab tab) {
  final written = <String>[];
  tab.term.terminal.onOutput = written.add;
  return written;
}

Future<void> pumpArea(WidgetTester tester, AppStore store) => tester.pumpWidget(
  MaterialApp(
    home: AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        body: SizedBox(width: 900, height: 400, child: PaneArea(store: store)),
      ),
    ),
  ),
);

/// Uma tecla batida onde quer que o teclado esteja.
///
/// Enter e não uma letra: letra entra pelo [TextInput] e depende de haver
/// conexão de IME aberta; o Enter o próprio [TerminalView] traduz no
/// `onKeyEvent`, então o que chega ao pty diz sem rodeios qual painel estava
/// escutando.
Future<void> enter(WidgetTester tester) async {
  await simulateKeyDownEvent(LogicalKeyboardKey.enter);
  await simulateKeyUpEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  // O painel novo abre em foco: é nele que se estava prestes a digitar, e
  // pedir um clique antes da primeira letra é pedir um gesto que só existe
  // porque o programa esqueceu de mudar o teclado de lugar.
  //
  // O `autofocus` do [TerminalView] não dava conta disto sozinho: ele só vale
  // quando ninguém no escopo está em foco, e abrir o segundo painel é
  // justamente o caso em que alguém está -- o painel de onde você pediu o
  // novo. O anel acendia no painel novo e a letra ia pro velho.
  testWidgets('o painel recém-aberto já nasce com o teclado', (tester) async {
    final store = AppStore();
    addTearDown(store.dispose);

    final first = session(store, 'um');
    store.panes = PaneLeaf(first.id);
    store.focusedPaneId = first.id;
    final toFirst = watch(first);
    await pumpArea(tester, store);
    await tester.pump();

    await enter(tester);
    expect(toFirst, ['\r'], reason: 'o único painel da tela escuta o teclado');

    // O segundo painel, aberto ao lado -- o mesmo caminho de [AppStore.dropTab].
    final second = session(store, 'dois');
    final toSecond = watch(second);
    store.dropTab(second, target: first, side: DropSide.right);
    await tester.pump();
    await tester.pump();

    await enter(tester);
    expect(toSecond, ['\r']);
    expect(toFirst, ['\r'], reason: 'a tecla não pode cair no painel de onde se veio');

    // O save do store é debounced: sem deixar o relógio andar até ele, o
    // teste acaba com um timer pendente.
    await tester.pump(const Duration(milliseconds: 500));
  });

  // O caso do dia a dia: a sessão nova é aberta pela lateral, e quem estava
  // com o teclado era a busca -- um campo de texto que fica em foco depois do
  // clique. O painel nasce, acende o anel, e a primeira linha do prompt ia
  // parar na busca.
  testWidgets('e toma o teclado de quem estava com ele fora dos painéis', (tester) async {
    final store = AppStore();
    addTearDown(store.dispose);
    final search = FocusNode(debugLabel: 'busca');
    addTearDown(search.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Scaffold(
            body: Column(
              children: [
                SizedBox(width: 300, child: TextField(focusNode: search)),
                Expanded(child: SizedBox(width: 900, child: PaneArea(store: store))),
              ],
            ),
          ),
        ),
      ),
    );
    search.requestFocus();
    await tester.pump();
    expect(search.hasFocus, isTrue);

    // A sessão escolhida na lateral, posta na tela.
    final tab = session(store, 'um');
    final written = watch(tab);
    store.select(tab);
    await tester.pump();
    await tester.pump();

    expect(search.hasFocus, isFalse, reason: 'o teclado saiu da busca');
    await enter(tester);
    expect(written, ['\r']);

    await tester.pump(const Duration(milliseconds: 500));
  });

  // E o caso do diálogo: "nova task" e "abrir pasta" abrem a sessão depois de
  // fechar a caixa, e fechar uma caixa devolve o teclado a quem o tinha antes
  // dela. É uma devolução que acontece sozinha, num quadro que não é o nosso.
  testWidgets('e sobrevive ao teclado que o diálogo devolve ao fechar', (tester) async {
    final store = AppStore();
    addTearDown(store.dispose);
    final search = FocusNode(debugLabel: 'busca');
    addTearDown(search.dispose);
    late BuildContext ctx;

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: store,
          builder: (context, _) {
            ctx = context;
            return Scaffold(
              body: Column(
                children: [
                  SizedBox(width: 300, child: TextField(focusNode: search)),
                  Expanded(child: SizedBox(width: 900, child: PaneArea(store: store))),
                ],
              ),
            );
          },
        ),
      ),
    );
    search.requestFocus();
    await tester.pump();

    final answered = showDialog<bool>(
      context: ctx,
      builder: (context) => AlertDialog(
        content: TextField(autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('ok')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ok'));
    await tester.pumpAndSettle();
    expect(await answered, isTrue);

    final tab = session(store, 'um');
    final written = watch(tab);
    store.select(tab);
    // Sem `pumpAndSettle`: o cursor do terminal pisca pra sempre, e uma tela
    // que nunca fica parada nunca assenta.
    await tester.pump();
    await tester.pump();

    await enter(tester);
    expect(written, ['\r'], reason: 'o painel aberto pelo diálogo escuta o teclado');

    await tester.pump(const Duration(milliseconds: 500));
  });
}
