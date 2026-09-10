import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

/// Os ícones que vêm de um `.svg` em `assets/icons/`, e não de `Icons.*`.
///
/// O Material Icons é um conjunto fechado, e fechado ele obriga a escolher o
/// menos errado quando o desenho certo não existe: o painel de terminal
/// passou tempo demais com um `Icons.chevron_right`, que na mesma lista é a
/// seta que expande as pastas e os grupos. Um svg não tem esse teto -- o
/// desenho vem de um conjunto de fora (ver `assets/icons/README.md`) e o
/// arquivo é o ícone.
///
/// Isto não substitui o `Icons.*`, que continua certo para a maior parte do
/// chrome. É a saída para quando ele não tem o desenho.
///
/// Para acrescentar um: salve o `.svg` em `assets/icons/`, monocromático e em
/// viewBox 24×24, some uma constante em [MxIcons] e cite a origem no README
/// de lá. Sem `flutter pub get` -- a pasta inteira já é declarada no pubspec.
class MxIcons {
  const MxIcons._();

  /// O prompt dentro da janelinha, que é o que todo mundo já lê como
  /// "terminal". O `>` solto não servia: ver a nota de classe acima.
  static const String terminal = 'terminal';

  /// A rajada da Anthropic. Ver [ClaudeMark], que é quem a usa.
  static const String claude = 'claude';
}

/// Um dos [MxIcons], pintado como se fosse um [Icon].
///
/// Mesma API do [Icon] de propósito -- nome, `size`, `color` --, para que
/// trocar um pelo outro numa linha de widget seja trocar uma palavra. O
/// tamanho é o lado do quadrado, como no [Icon], e a cor recobre o desenho
/// inteiro (traço e preenchimento), então o svg não precisa vir com
/// `currentColor`.
class MxIcon extends StatelessWidget {
  const MxIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;

  /// Nulo herda a cor do texto ao redor, como o [Icon] faz.
  final Color? color;

  static String _path(String name) => 'assets/icons/$name.svg';

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    _path(name),
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color ?? Mx.fg, BlendMode.srcIn),
    // Um ícone é o desenho, não o texto: quem lê tela ouve o rótulo da linha
    // em volta, e o svg anunciando "claude" de novo seria eco.
    excludeFromSemantics: true,
  );

  /// Deixa os desenhos prontos antes do primeiro quadro.
  ///
  /// O `SvgPicture` compila o svg na primeira vez que o desenha, e sem isto a
  /// marca do claude -- que é o ícone mais repetido do app -- apareceria um
  /// quadro depois da linha em que ela mora. Chamado de `main()`.
  static Future<void> warm() => Future.wait([
    for (final name in const [MxIcons.terminal, MxIcons.claude])
      svg.cache.putIfAbsent(
        SvgAssetLoader(_path(name)).cacheKey(null),
        () => SvgAssetLoader(_path(name)).loadBytes(null),
      ),
  ]);
}
