import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../services/docs.dart';
import '../services/notify.dart';
import '../services/store.dart';
import '../theme.dart';
import 'panel.dart';

/// Um painel de leitura: markdown desenhado, no lugar de um terminal.
///
/// É um painel como qualquer outro — mesma moldura, mesmo cabeçalho de 42px,
/// mesma árvore de cortes, arrastável pela linha da lateral. O que ele não tem
/// é processo: nada aqui roda, nada aqui responde. Ver [TabKind.reader].
///
/// A razão de existir é o plano. Um plano do Claude é o documento mais lido de
/// uma sessão e o único que não existia em lugar nenhum: no terminal ele é uma
/// parede de texto que rola pra fora da tela — com `##`, `-` e crase à mostra —
/// e no disco ele não está. O leitor é onde ele passa a caber.
class DocPane extends StatefulWidget {
  const DocPane({
    super.key,
    required this.store,
    required this.tab,
    this.focused = true,
    this.showFocus = false,
    this.onFocus,
  });

  final AppStore store;
  final MxTab tab;
  final bool focused;
  final bool showFocus;
  final VoidCallback? onFocus;

  @override
  State<DocPane> createState() => _DocPaneState();
}

class _DocPaneState extends State<DocPane> {
  final ScrollController _scroll = ScrollController();
  Timer? _watch;

  /// Qual documento está na tela, pelo que o distingue de outro. Um leitor é um
  /// lugar e o documento dentro dele troca (ver [AppStore.showDoc]) — sem isto,
  /// abrir o segundo `.md` deixaria a rolagem do primeiro e o relógio do
  /// arquivo errado apontando pro anterior.
  String _showing = '';

  MxDoc get _doc => widget.tab.doc!;

  /// De segundo e meio em segundo e meio, e não por [File.watch]: um editor que
  /// salva por rename — que é a maioria — troca o inode e leva o watcher junto,
  /// então o arquivo pararia de atualizar exatamente depois do primeiro save.
  /// Um `stat` a cada tique custa nada e nunca perde o fio.
  static const _pulse = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  @override
  void didUpdateWidget(DocPane old) {
    super.didUpdateWidget(old);
    _adopt();
  }

  @override
  void dispose() {
    _watch?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Assume o documento que está no painel agora: relê, volta ao topo se ele
  /// mudou, e liga (ou desliga) a releitura.
  void _adopt() {
    final id = '${_doc.source.name}|${_doc.path ?? ''}|${_doc.title}';
    if (id == _showing) return;
    _showing = id;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _watch?.cancel();
    if (!_doc.source.onDisk) return;
    _reload();
    _watch = Timer.periodic(_pulse, (_) => _reload());
  }

  Future<void> _reload() async {
    final changed = await _doc.reload();
    if (changed && mounted) setState(() {});
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _doc.text));
    widget.store.showBanner('${_doc.title}: markdown copiado');
  }

  /// Um link do documento, seguido. Onde ele vai dar é [AppStore.followLink]:
  /// um link do texto de uma sessão abre no mesmo lugar, venha ele daqui ou do
  /// terminal em que a sessão o imprimiu.
  ///
  /// O que é daqui é a base: um caminho relativo escrito num `.md` é relativo
  /// à pasta do próprio arquivo, e não à da sessão — é o que o autor do link
  /// quis dizer.
  void _follow(String? href) {
    if (href == null) return;
    widget.store.followLink(
      href,
      from: widget.tab,
      base: _doc.path != null ? File(_doc.path!).parent.path : widget.tab.cwd,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => widget.onFocus?.call(),
      child: MxPanel(
        focused: widget.focused,
        showFocus: widget.showFocus,
        child: Column(
          children: [
            _DocHeader(
              store: widget.store,
              tab: widget.tab,
              dimmed: widget.showFocus && !widget.focused,
              onCopy: _copy,
              onReload: _reload,
            ),
            Expanded(child: _surface()),
          ],
        ),
      ),
    );
  }

  Widget _surface() {
    if (_doc.missing) {
      return _Notice(
        icon: Icons.help_outline,
        title: 'esse arquivo não está mais lá',
        detail: _doc.path ?? '',
      );
    }
    if (_doc.text.trim().isEmpty) {
      return _Notice(
        icon: Icons.description_outlined,
        title: _doc.source.onDisk ? 'arquivo vazio' : 'documento vazio',
        detail: _doc.path ?? '',
      );
    }
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 40),
        // Uma coluna de leitura tem largura máxima como um texto tem: passando
        // de uns oitenta caracteres o olho perde a volta da linha. Num painel
        // largo o texto fica centrado; num estreito, isto não faz nada.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: MxMarkdown(
              data: _doc.text,
              onFollow: _follow,
              // Os mesmos passos de ⌘+ do terminal, sobre a escala do
              // markdown: o corpo base do pty é de outra tipografia e não
              // manda aqui, mas "quero ler isto de perto" é o mesmo pedido.
              fontSize: MxMarkdown.baseSize + widget.tab.zoom,
            ),
          ),
        ),
      ),
    );
  }
}

/// O markdown do maestria, desenhado: um widget, uma folha de estilo.
///
/// Público e fora do [DocPane] porque markdown não é só do painel de leitura:
/// qualquer tela que mostre o texto de uma sessão usa esta folha de estilo,
/// pra que todas pareçam a mesma coisa. Não rola: quem rola é quem o embrulha.
class MxMarkdown extends StatelessWidget {
  const MxMarkdown({super.key, required this.data, this.onFollow, this.fontSize = baseSize});

  /// O corpo do texto corrido, de que todo o resto da escala é derivado — os
  /// títulos, a crase, a tabela. Ver [sheet].
  static const baseSize = 13.5;

  final String data;

  /// O que fazer com um link clicado. Sem isto os links são desenhados e
  /// inertes, que é o certo num diálogo de 560px.
  final void Function(String? href)? onFollow;

  /// O corpo do texto. O resto da escala sai dele.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: sheet(fontSize),
      onTapLink: onFollow == null ? null : (text, href, title) => onFollow!(href),
      // GFM: tabela, lista de tarefas e ~riscado~ são o que o Claude escreve
      // num plano. Sem isto um `- [ ]` sai como um traço e um colchete.
      extensionSet: md.ExtensionSet.gitHubWeb,
    );
  }

  /// O markdown vestido com a paleta da janela.
  ///
  /// Montado a cada build de propósito: o tema é trocável em tempo de execução
  /// e uma folha de estilo guardada continuaria pintando a paleta antiga.
  static MarkdownStyleSheet sheet(double fontSize) {
    final body = TextStyle(fontSize: fontSize, height: 1.62, color: Mx.fg);
    // A mono do app é a Hack, e ela desenha mais alta que a de interface no
    // mesmo corpo: um ponto e meio menos deixa `código` do tamanho da frase
    // em que ele está.
    final mono = TextStyle(
      fontFamily: Mx.mono,
      fontSize: fontSize - 1.7,
      height: 1.5,
      color: Mx.fg,
      // A mesma cor do fundo do bloco: dentro de um bloco de código os dois se
      // sobrepõem e o retângulo por trás das letras some, enquanto `assim`, no
      // meio de um parágrafo, ele é a única coisa que marca a crase.
      backgroundColor: Mx.bgActive,
    );
    TextStyle heading(double size, {Color? color}) => TextStyle(
      fontSize: size,
      height: 1.3,
      fontWeight: FontWeight.w600,
      color: color ?? Mx.fg,
      letterSpacing: -0.2,
    );

    return MarkdownStyleSheet(
      p: body,
      pPadding: const EdgeInsets.only(bottom: 2),
      a: TextStyle(
        color: Mx.accent,
        decoration: TextDecoration.underline,
        decorationColor: Mx.accent.withValues(alpha: 0.45),
      ),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: TextStyle(fontWeight: FontWeight.w600, color: Mx.fg),
      del: TextStyle(decoration: TextDecoration.lineThrough, color: Mx.fgFaint),
      // Toda a escala sai do corpo do texto, e não de números soltos: o mesmo
      // markdown é desenhado num painel inteiro e dentro de um diálogo de
      // 560px, e o segundo é o primeiro um ponto menor.
      h1: heading(fontSize + 7.5),
      h1Padding: const EdgeInsets.only(top: 6, bottom: 6),
      h2: heading(fontSize + 3),
      h2Padding: const EdgeInsets.only(top: 16, bottom: 4),
      h3: heading(fontSize + 1, color: Mx.fgDim),
      h3Padding: const EdgeInsets.only(top: 12, bottom: 2),
      h4: heading(fontSize, color: Mx.fgDim),
      h5: heading(fontSize - 0.5, color: Mx.fgDim),
      h6: heading(fontSize - 1, color: Mx.fgFaint),
      code: mono,
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: Mx.bgActive,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Mx.border),
      ),
      blockquote: body.copyWith(color: Mx.fgDim),
      blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      blockquoteDecoration: BoxDecoration(
        color: Mx.bgHover,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: Mx.accent.withValues(alpha: 0.55), width: 3)),
      ),
      listBullet: body,
      listIndent: 22,
      listBulletPadding: const EdgeInsets.only(right: 6, top: 1),
      blockSpacing: 11,
      checkbox: TextStyle(fontSize: fontSize, color: Mx.accent),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: Mx.border)),
      ),
      tableHead: TextStyle(fontSize: fontSize - 1, fontWeight: FontWeight.w600, color: Mx.fg),
      tableBody: TextStyle(fontSize: fontSize - 1, height: 1.4, color: Mx.fg),
      tableBorder: TableBorder.all(color: Mx.border),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      tableHeadCellsDecoration: BoxDecoration(color: Mx.bgSidebar),
      tableColumnWidth: const IntrinsicColumnWidth(),
    );
  }
}

/// O cabeçalho: o mesmo desenho do cabeçalho de um terminal, com os botões que
/// fazem sentido pra uma folha de papel.
class _DocHeader extends StatelessWidget {
  const _DocHeader({
    required this.store,
    required this.tab,
    required this.dimmed,
    required this.onCopy,
    required this.onReload,
  });

  final AppStore store;
  final MxTab tab;
  final bool dimmed;
  final VoidCallback onCopy;
  final VoidCallback onReload;

  static IconData iconOf(DocSource source) => switch (source) {
    DocSource.plan => Icons.checklist_rtl,
    DocSource.file => Icons.article_outlined,
    DocSource.message => Icons.chat_bubble_outline,
    DocSource.report => Icons.summarize_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final doc = tab.doc!;
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: Mx.bgSidebar,
          border: Border(bottom: BorderSide(color: Mx.border)),
        ),
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Row(
          children: [
            Icon(iconOf(doc.source), size: 17, color: Mx.fgDim),
            const SizedBox(width: 9),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Row(
                  children: [
                    Flexible(
                      child: Text(
                        tab.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    if (box.maxWidth >= 190) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        flex: 2,
                        child: Text(
                          tab.subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Mx.fgDim, fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (doc.source.onDisk && doc.path != null) ...[
              _Action(
                icon: Icons.refresh,
                tooltip: 'reler do disco — ele já relê sozinho enquanto está aberto',
                onPressed: onReload,
              ),
              _Action(
                icon: Icons.folder_open_outlined,
                tooltip: 'mostrar no Finder',
                onPressed: () => Notifier.reveal(doc.path!),
              ),
              _Action(
                icon: Icons.edit_outlined,
                tooltip: 'abrir no vscode',
                onPressed: () => store.openInEditor(doc.path!),
              ),
            ],
            _Action(icon: Icons.copy_all_outlined, tooltip: 'copiar o markdown', onPressed: onCopy),
            _Action(
              icon: Icons.close,
              tooltip: 'fechar este leitor',
              // Fechar de verdade, não [AppStore.dismiss]: um leitor não tem
              // processo nem conversa pra guardar na lateral, então um que sai
              // do painel não seria nada — só uma linha a mais na lista.
              onPressed: () => store.closeTab(tab),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 15,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: onPressed,
      icon: Icon(icon, color: Mx.fgDim),
    );
  }
}

/// O painel quando não há o que desenhar. Diz qual das duas coisas aconteceu,
/// porque um retângulo vazio parece o leitor quebrado.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, this.detail = ''});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: Mx.fgFaint),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(fontSize: 13, color: Mx.fgDim)),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 340,
              child: Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: Mx.mono, fontSize: 10.5, color: Mx.fgFaint),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
