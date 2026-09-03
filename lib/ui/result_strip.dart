import 'dart:io';

import 'package:flutter/material.dart';

import '../services/docs.dart';
import '../services/notify.dart';
import '../services/store.dart';
import '../theme.dart';

/// What a session produced, as a list you can open.
///
/// A panel's whole output used to live in its scrollback: to answer "what did
/// it actually change" you scrolled back through the tool calls and hoped you
/// caught them all. The hooks already say — every write announces its path —
/// so the answer was being thrown away rather than being unavailable.
///
/// Deliberately files and nothing else. No diff, no summary, no status: the
/// question this answers is "what do I open now", and a row that opens the
/// thing is the shortest way to answer it.
class ResultStrip extends StatelessWidget {
  const ResultStrip({
    super.key,
    required this.store,
    required this.tab,
    required this.onClear,
  });

  final AppStore store;
  final MxTab tab;
  final VoidCallback onClear;

  /// Tall enough for six rows. Past that the list scrolls instead of eating
  /// the terminal it is reporting on.
  static const _maxHeight = 186.0;

  @override
  Widget build(BuildContext context) {
    final files = tab.hooks.touched;
    if (files.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: _maxHeight),
      decoration: BoxDecoration(
        color: Mx.bgSidebar,
        border: Border(top: BorderSide(color: Mx.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StripHeader(count: files.length, onClear: onClear),
          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 6),
              itemCount: files.length,
              // Newest first: the file the session just wrote is the one you
              // are waiting on, and it would otherwise be the row furthest
              // from the eye, below a fold.
              itemBuilder: (context, i) =>
                  _FileRow(store: store, tab: tab, path: files[files.length - 1 - i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _StripHeader extends StatelessWidget {
  const _StripHeader({required this.count, required this.onClear});
  final int count;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 6, 5),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 12, color: Mx.fgFaint),
          const SizedBox(width: 7),
          Text(
            count == 1 ? 'arquivo alterado' : 'arquivos alterados',
            style: TextStyle(fontSize: 11, color: Mx.fgFaint),
          ),
          const Spacer(),
          // Not a delete: the files stay, the *record* of them is what gets
          // dropped. A session you have already looked through should be able
          // to start counting again.
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('limpar', style: TextStyle(fontSize: 11, color: Mx.fgDim)),
          ),
        ],
      ),
    );
  }
}

/// One file. Click previews it; the button beside it goes to the Finder.
class _FileRow extends StatefulWidget {
  const _FileRow({required this.store, required this.tab, required this.path});
  final AppStore store;
  final MxTab tab;
  final String path;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  String get _name => widget.path.split('/').last;

  /// Where it sits, said the shortest way that is still unambiguous: inside
  /// the panel's own folder, the folder is a given and only the subpath is
  /// news. Panels routinely write to a handful of files with the same
  /// basename in different directories, so the path cannot just be dropped.
  String get _where {
    final dir = widget.path.contains('/')
        ? widget.path.substring(0, widget.path.lastIndexOf('/'))
        : '';
    final cwd = widget.tab.cwd;
    if (dir == cwd) return '';
    if (dir.startsWith('$cwd/')) return dir.substring(cwd.length + 1);
    return dir;
  }

  /// Checked on every build rather than cached: the session goes on working
  /// while the strip is open, and a file it renamed away is a row that has to
  /// stop pretending it can be opened.
  bool get _gone => !File(widget.path).existsSync();

  /// Markdown abre aqui dentro, num painel de leitura; o resto vai pro
  /// Quick Look como sempre foi.
  ///
  /// A distinção é a única que importa nesta lista: um `.md` que a sessão
  /// escreveu -- um plano salvo, um spec, um resumo -- é pra ler agora, ao lado
  /// da sessão, e o Quick Look o entregava como texto cru com as cerquilhas à
  /// mostra. Uma planilha continua sendo assunto de outro app.
  Future<void> _open() async {
    if (_gone) {
      widget.store.showBanner('esse arquivo não está mais lá: ${widget.path}');
      return;
    }
    if (AppStore.readable(widget.path)) {
      widget.store.showFile(widget.path, from: widget.tab);
      return;
    }
    await Notifier.quickLook(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    final gone = _gone;
    final where = _where;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: Container(
          color: _hover ? Mx.bgHover : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(
                gone ? Icons.help_outline : _iconFor(_name),
                size: 13,
                color: gone ? Mx.fgFaint : Mx.fgDim,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: gone ? Mx.fgFaint : Mx.fg,
                    decoration: gone ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (where.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  flex: 2,
                  child: Text(
                    where,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: Mx.fgFaint),
                  ),
                ),
              ],
              const Spacer(),
              // Only on hover: eight of these lined up read as a toolbar, and
              // the row already does the obvious thing when clicked.
              if (_hover && !gone)
                IconButton(
                  tooltip: 'mostrar no Finder',
                  iconSize: 13,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 20, height: 20),
                  style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: () => Notifier.reveal(widget.path),
                  icon: Icon(Icons.folder_open_outlined, color: Mx.fgDim),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Enough of a hint to scan the list by shape. The extensions that earn a
  /// case are the ones a session actually produces.
  static IconData _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'csv' || 'xlsx' || 'xls' || 'numbers' => Icons.table_chart_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' => Icons.image_outlined,
      'md' || 'txt' || 'rtf' || 'doc' || 'docx' || 'pages' => Icons.article_outlined,
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' => Icons.data_object,
      'ipynb' => Icons.science_outlined,
      '' => Icons.insert_drive_file_outlined,
      _ => Icons.code,
    };
  }
}


/// Os documentos desta sessão, numa fita colada no rodapé do terminal.
///
/// A diferença entre isto e a [ResultStrip] é o que a lista responde. A tira
/// responde "o que essa sessão mexeu" -- toda ela, dobrada atrás de uma ficha,
/// porque quarenta arquivos não são uma coisa pra ficar na tela. Esta responde
/// "o que essa sessão escreveu pra eu *ler*", que são um plano e um punhado de
/// `.md` — e essa resposta tem que estar visível sem clique, senão a sessão
/// escreve um documento, diz o caminho dele no meio de um parágrafo, e o
/// parágrafo rola pra fora da tela levando o documento com ele.
///
/// Só aparece quando há o que ler, então um painel que não escreve markdown
/// não perde um pixel pra ela.
class DocBar extends StatelessWidget {
  const DocBar({super.key, required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  /// Quantos `.md` cabem antes de a fita virar uma lista. Passando disso, os
  /// mais antigos continuam na tira de arquivos alterados.
  static const _max = 8;

  /// Os markdown que a sessão escreveu, do mais novo pro mais velho: o que ela
  /// acabou de escrever é o que você está esperando.
  static List<String> filesOf(MxTab tab) =>
      tab.hooks.touched.reversed.where(AppStore.readable).take(_max).toList();

  /// Se há alguma coisa pra esta fita mostrar. Quem monta o painel pergunta
  /// isto antes de gastar altura com ela.
  static bool has(MxTab tab) => tab.hooks.plan != null || filesOf(tab).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final plan = tab.hooks.plan;
    final files = filesOf(tab);
    final open = store.reading;

    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: Mx.bgSidebar,
        border: Border(top: BorderSide(color: Mx.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.menu_book_outlined, size: 12, color: Mx.fgFaint),
          const SizedBox(width: 8),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(vertical: 5),
              children: [
                if (plan != null)
                  _DocPill(
                    icon: Icons.checklist_rtl,
                    label: tab.hooks.plans.length > 1
                        ? 'plano ·${tab.hooks.plans.length}'
                        : 'plano',
                    tooltip: plan.headline,
                    // O plano não tem caminho pra comparar: o que identifica o
                    // que está aberto é ser um plano com o mesmo texto.
                    open: open != null && open.source == DocSource.plan && open.text == plan.text,
                    onTap: () => store.showPlan(tab),
                  ),
                for (final path in files)
                  _DocPill(
                    icon: Icons.article_outlined,
                    label: path.split('/').last,
                    tooltip: path,
                    open: open?.path == path,
                    gone: !File(path).existsSync(),
                    onTap: () => store.showFile(path, from: tab),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Uma ficha da fita: um documento, e se é ele que está aberto no leitor.
class _DocPill extends StatefulWidget {
  const _DocPill({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.open = false,
    this.gone = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool open;

  /// O arquivo saiu do disco depois de ter sido escrito -- renomeado, movido,
  /// apagado. A ficha fica, riscada: some do nada é pior.
  final bool gone;

  @override
  State<_DocPill> createState() => _DocPillState();
}

class _DocPillState extends State<_DocPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.gone
        ? Mx.fgFaint
        : widget.open
        ? Mx.accent
        : (_hover ? Mx.fg : Mx.fgDim);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: widget.gone ? '${widget.tooltip}\n(não está mais lá)' : widget.tooltip,
        child: MouseRegion(
          cursor: widget.gone ? SystemMouseCursors.basic : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.gone ? null : widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: widget.open
                    ? Mx.accent.withValues(alpha: 0.12)
                    : (_hover ? Mx.bgHover : Colors.transparent),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: widget.open ? Mx.accent.withValues(alpha: 0.5) : Mx.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 11, color: color),
                  const SizedBox(width: 5),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      decoration: widget.gone ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip's handle, in the pane header.
///
/// Says the one number worth a glance and nothing else — the list is a click
/// away, and a header that spelled out filenames would be competing with the
/// title for the same 300 pixels.
class ResultChip extends StatelessWidget {
  const ResultChip({super.key, required this.count, required this.open, required this.onTap});

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = open ? Mx.accent : Mx.green;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: open ? 'esconder o que mudou' : 'ver o que mudou',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.inventory_2_outlined, size: 11, color: color),
                const SizedBox(width: 4),
                Text(
                  count == 1 ? '1 arquivo' : '$count arquivos',
                  style: TextStyle(color: color, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
