# maestria no Linux

## 1. Claude Code primeiro

O maestria não substitui o Claude Code — ele abre sessões do `claude` em
painéis e escuta os hooks delas. Sem o CLI instalado e logado com a **sua**
conta, o app abre e não sobe sessão nenhuma.

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude          # loga na primeira execução
```

O `claude` precisa estar no PATH do seu **login shell** — o instalador cuida
disso no `.bashrc`/`.zshrc`. Confira fechando e reabrindo o terminal e rodando
`claude --version`. Um app gráfico não herda PATH de terminal aberto: se só
funciona depois de um `export` manual, o maestria não vai achar.

## 2. Instalar

```bash
sudo apt install ./maestria_1.0.0-1_amd64.deb
```

O apt puxa o que falta (`git`, `libnotify-bin`, `xdg-utils`). Depois é
"maestria" no menu de aplicativos, ou `maestria` no terminal.

## 3. Primeiro uso

Não vem com pasta nenhuma: **adicionar pasta** e aponte pra um repo git seu.
As configurações ficam em `~/.maestria/config.json`.

## O que é diferente do Mac

- **Atalhos**: vêm de fábrica em ⌘, que no Linux é a tecla **Super** — e o
  GNOME já usa quase todas. Remapeie nos ajustes antes de qualquer coisa.
- **Sem contador no ícone da dock**: as notificações do sistema dizem qual
  sessão parou; o número de paradas só aparece dentro da janela.
- **Sem Quick Look**: clicar num arquivo da tira abre no app que já lê o tipo,
  em vez de pré-visualizar.
- **Abrir um markdown pelo seletor de arquivos ainda não existe** no Linux. Os
  `.md` que as sessões escrevem continuam abrindo pela tira de alterados.
