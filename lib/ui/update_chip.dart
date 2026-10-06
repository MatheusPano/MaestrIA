import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/store.dart';
import '../services/updater.dart';
import '../theme.dart';

/// "2.5.0" na barra de status, ao lado do sino, quando há versão nova pronta.
///
/// Não é um aviso do sino: o sino conta o que os painéis fizeram, e some
/// quando você lê. Isto fica até a versão entrar -- é um estado do app, não
/// uma notícia.
class UpdateChip extends StatefulWidget {
  const UpdateChip({super.key, required this.store});
  final AppStore store;

  @override
  State<UpdateChip> createState() => _UpdateChipState();
}

class _UpdateChipState extends State<UpdateChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final u = widget.store.updater;
    final busy = u.stage == UpdateStage.installing;
    if (u.release == null || (u.stage != UpdateStage.ready && !busy)) {
      return const SizedBox.shrink();
    }
    final color = _hover ? Mx.fg : Mx.accent;
    return Tooltip(
      message: busy
          ? 'Instalando a ${u.release!.version}…'
          : u.installsOnQuit
          ? 'maestria ${u.release!.version} pronta · entra quando você fechar o app'
          : 'maestria ${u.release!.version} pronta pra instalar',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: busy ? null : () => confirmUpdate(context, widget.store),
          child: Container(
            height: 20,
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_circle_up_rounded, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  busy ? 'instalando…' : u.release!.version,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O clique no chip: reiniciar agora, sabendo o que isso fecha.
Future<void> confirmUpdate(BuildContext context, AppStore store) async {
  final u = store.updater;
  final version = u.release?.version;
  if (version == null) return;
  final live = store.tabs.where((t) => t.kind == TabKind.claude && !t.exited).length;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Text('Atualizar pra $version?', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _line(
              Icons.restart_alt_rounded,
              live == 0
                  ? 'O app fecha e abre de novo, já na $version'
                  : 'O app fecha e abre de novo: as $live sessões abertas são encerradas, '
                        'e os painéis voltam como estavam',
            ),
            if (u.installsOnQuit)
              _line(
                Icons.schedule_rounded,
                'Sem pressa: ela entra sozinha quando você fechar o app',
              )
            else
              _line(
                Icons.lock_outline_rounded,
                'O sistema vai pedir a sua senha pra instalar o pacote',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Depois')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reiniciar agora'),
        ),
      ],
    ),
  );
  if (go != true) return;

  if (Platform.isLinux) {
    final error = await u.install();
    if (error != null) {
      store.showBanner(error, sticky: true);
      return;
    }
  }
  u.relaunchAfterQuit();
  // Pelo mesmo caminho do ⌘Q: é ele que encerra as sessões e depois chama o
  // [Updater.onQuit].
  await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
}

Widget _line(IconData icon, String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: Mx.fgDim),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
    ],
  ),
);
