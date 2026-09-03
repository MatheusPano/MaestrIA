# Teste do leitor de markdown

Um arquivo só pra olhar o painel de leitura com todos os elementos que a folha de
estilo do `MxMarkdown` veste. Abrir num painel inteiro e depois num diálogo de
560px: a escala toda sai do corpo do texto, então os dois têm que ficar certos.

## Cabeçalhos

# H1 — o título do documento
## H2 — a seção
### H3 — a subseção
#### H4
##### H5
###### H6

## Texto corrido

Parágrafo normal, longo de propósito pra ver a entrelinha de 1.62 e onde a linha
quebra: *itálico*, **negrito**, ***os dois juntos***, ~~riscado~~ (GFM), `código
inline` no meio da frase, e uma palavra com _sublinhado como ênfase_.

Segundo parágrafo, pra ver o espaço entre blocos. Uma quebra forçada com dois
espaços no fim da linha vem aqui:  
esta linha devia estar logo abaixo, sem parágrafo novo.

Caracteres escapados: \*não é itálico\*, \_nem isso\_, 100% & "aspas" — travessão,
reticências… acentuação: ção, ãã, ê, ü, ñ.

Um token gigante sem espaço nenhum, pra ver se estoura a largura do painel:
`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`

## Links

- Link externo: [docs do Flutter](https://docs.flutter.dev)
- Autolink: https://github.com/flutter/flutter
- Link relativo pra outro `.md`: [o README](../../README.md)
- Link absoluto pra arquivo: [/etc/hosts](/etc/hosts)
- Link que não existe: [arquivo sumido](./NAO-EXISTE.md)
- Imagem (deve virar nada ou um quadrado quebrado): ![alt de teste](./nao-existe.png)

## Listas

- primeiro item
- segundo item, com um texto mais comprido pra ver como o recuo de 22 se comporta
  quando a linha quebra e continua embaixo do marcador
  - aninhado um nível
    - aninhado dois níveis
      - aninhado três níveis
- terceiro item

1. passo um
2. passo dois
   1. sub-passo a
   2. sub-passo b
3. passo três

7. lista ordenada começando em 7
8. e continuando

## Lista de tarefas

- [ ] pendente
- [x] feito
- [ ] pendente com `código` e **negrito**
  - [x] sub-item feito
  - [ ] sub-item pendente

## Citação

> Uma citação de uma linha.

> Uma citação de duas linhas, com **negrito** e `código` dentro,
> pra ver a barra do lado esquerdo e o fundo.
>
> Segundo parágrafo da mesma citação.
>
> > Citação aninhada.

## Código

Bloco com linguagem:

```dart
void main() {
  final doc = MxDoc.file('/repo/PLANO.md');
  // um comentário comprido de propósito pra ver se o bloco rola na horizontal ou quebra a linha
  print(doc.title);
}
```

Bloco sem linguagem:

```
$ flutter test test/reader_test.dart
00:03 +19: All tests passed!
```

Bloco indentado por quatro espaços:

    const x = 1;
    const y = 2;

## Tabelas

| coluna | o que faz | atalho |
|---|---|---|
| `plano` | o que a sessão escreveu ao sair do modo plano | — |
| `arquivo` | um `.md` do disco, relido a cada tique | ⌘O |
| `recado` | o último `last_assistant_message` | — |
| `relatório` | o relatório do dia | ⌘R |

Alinhamento:

| esquerda | centro | direita |
|:---|:---:|---:|
| a | b | 1 |
| aaa | bbb | 1000 |
| aaaaa | bbbbb | 1000000 |

Tabela larga, pra ver a rolagem horizontal:

| id | título | origem | caminho | hora | estado | observação |
|---|---|---|---|---|---|---|
| 1 | PLANO.md | plano | /repo/PLANO.md | 09:12 | aberto | primeiro painel |
| 2 | relatório de 01/09 | relatório | — | 18:40 | fechado | vem do DailyReport |
| 3 | recado da sessão 4 | recado | — | 11:07 | aberto | markdown desde sempre |

## Régua

Antes da régua.

---

Depois da régua.

***

E depois de outra.

## Fim

Última linha do arquivo, sem quebra depois dela.
