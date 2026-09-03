Cockpit para sessões do Claude Code: painéis lado a lado, worktrees do git por
tarefa e um leitor de markdown pro que as sessões escrevem.

## Baixar

| | arquivo |
|---|---|
| **macOS** (Intel e Apple Silicon) | `maestria_*_macos.dmg` |
| **Linux** (Ubuntu 22.04+, Mint, Pop!_OS) | `maestria_*_amd64.deb` |

## Antes de tudo: o Claude Code

O maestria não substitui o `claude` — ele abre sessões do CLI em painéis e
escuta os hooks delas. Sem o Claude Code instalado e logado com a **sua** conta,
o app abre e não sobe sessão nenhuma.

```
curl -fsSL https://claude.ai/install.sh | bash
claude          # loga na primeira execução
```

## macOS

Abra o `.dmg`, arraste o **maestria** pro Applications. Na primeira abertura o
macOS vai reclamar: o app é assinado *ad-hoc*, sem conta paga de desenvolvedor
da Apple, então ele não passa pelo Gatekeeper de um download. Uma vez, no
terminal:

```
xattr -dr com.apple.quarantine /Applications/maestria.app
```

Depois disso abre normal, e não se reclama de novo. (Alternativa pelo mouse:
**Ajustes do Sistema → Privacidade e Segurança**, e "Abrir Assim Mesmo" no
aviso que aparece logo depois da tentativa recusada.)

## Linux

```
sudo apt install ./maestria_*_amd64.deb
```

O apt puxa o que falta. Depois é "maestria" no menu de aplicativos, ou
`maestria` no terminal. Detalhes e as diferenças em relação ao Mac estão em
[INSTALAR.md](https://github.com/MatheusPano/MaestrIA/blob/main/packaging/linux/INSTALAR.md).

## Primeiro uso

Não vem com pasta nenhuma: **adicionar pasta** e aponte pra um repo git seu. As
configurações ficam em `~/.maestria/config.json`.
