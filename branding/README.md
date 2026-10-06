# Marca

A MaestrIA tem dois desenhos, um para cada papel:

| arquivo | o que é | onde vai |
|---|---|---|
| `app-icon.svg` | o M regente apontando o painel aceso, sobre a grade de painéis | o ícone do app no macOS e, pelo `make-deb.sh`, no Linux |
| `app-icon-windows.svg` | o mesmo, sem a margem e a sombra do gabarito da Apple | o `app_icon.ico` do Windows |
| `mark.svg`, `mark-light.svg` | o M regente sozinho: o M num traço só, com a última perna saindo como batuta até a ponta acesa | a marca, onde o nome não cabe |
| `logo.svg`, `logo-light.svg` | a marca ao lado do nome | README, release, página |

As versões `-light` são para fundo claro: a ponta deixa de ser branca com brilho
e passa a ser o azul do acento.

O ícone do app leva a grade porque tem espaço para ela, e a marca não leva porque
em tamanho pequeno a grade some. O M é o mesmo nos dois.

Cores: o acento vai de `#7AA2F7` a `#C3A6FF`, o azul e o roxo do tema Dark
(`lib/theme.dart`). O nome no logotipo é a [Geist](https://github.com/vercel/geist-font)
(SIL OFL 1.1), em 500 no "Maestr" e 600 no "IA", convertida em curvas: o svg não
depende de a fonte estar instalada.

## Gerar de novo

Tudo aqui sai do `build.py`, inclusive os PNGs do `AppIcon.appiconset` e o
`app_icon.ico`. Ele precisa de `resvg`, `magick` e, no Python, de `fonttools` e
`uharfbuzz`, além do `Geist[wght].ttf` (o variável, do
[Google Fonts](https://github.com/google/fonts/tree/main/ofl/geist)):

```sh
python build.py caminho/Geist[wght].ttf saida/
```

A saída tem `branding/` (os arquivos desta pasta) e `png/` (os tamanhos do macOS
e o `.ico`), que vão para `macos/Runner/Assets.xcassets/AppIcon.appiconset/` e
`windows/runner/resources/`.
