# Ícones

Desenhos que o Material Icons não tem, ou tem errado. Cada `.svg` aqui é
servido por `lib/ui/icons.dart` — veja lá como um novo entra.

Regra do que cabe aqui: o arquivo é um ícone monocromático de 24×24, sem cor
fixa dentro (o `MxIcon` pinta por fora, e o que for pra vazar tem que ser
transparente de verdade — máscara ou `fill-rule`, nunca a cor do fundo
chumbada), e vem de um conjunto com licença permissiva. Nada de PNG e nada de
ilustração colorida.

| arquivo | origem | licença |
|---|---|---|
| `claude.svg` | [Simple Icons](https://simpleicons.org/?q=claude), `claude` | CC0 1.0 |
| `terminal.svg` | desenho próprio | — |

O `claude.svg` é a marca da Anthropic. Ela está aqui pelo mesmo motivo pelo
qual o nome "claude" está: é o programa que o painel roda, e é assim que se
diz qual é. O CC0 é do arquivo; a marca continua sendo deles.

O `terminal.svg` é desenhado aqui, e não pego pronto, porque os conjuntos
livres só têm o motivo em duas formas que não serviam: contorno fino (Lucide
`square-terminal`, que some ao lado da rajada do claude) ou retângulo deitado
(Remix, Bootstrap, Phosphor, que é uma janela, não uma tela). O que se queria
era a tela quadrada e cheia, com o `>_` recortado dela — e isso são seis
linhas de svg.
