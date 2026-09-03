# maestria no macOS

## 1. Claude Code primeiro

O maestria não substitui o Claude Code — ele abre sessões do `claude` em
painéis e escuta os hooks delas. Sem o CLI instalado e logado com a **sua**
conta, o app abre e não sobe sessão nenhuma.

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude          # loga na primeira execução
```

## 2. Instalar

Abra o `.dmg` e arraste o **maestria** pro Applications.

## 3. O aviso do Gatekeeper

O app é assinado *ad-hoc*: a assinatura prova que o binário não foi alterado
depois de compilado, mas não diz de quem ele é — isso exigiria uma conta paga
de desenvolvedor da Apple e a notarização. Num app que veio de download, o
macOS recusa a primeira abertura por causa disso ("não foi possível verificar",
ou "está danificado").

O que tira o carimbo de quarentena do download:

```bash
xattr -dr com.apple.quarantine /Applications/maestria.app
```

Uma vez só. Pelo mouse dá no mesmo: tente abrir, recuse o aviso, e vá em
**Ajustes do Sistema → Privacidade e Segurança** — o "Abrir Assim Mesmo" fica
lá, logo abaixo, por alguns minutos depois da tentativa.

## 4. Primeiro uso

Não vem com pasta nenhuma: **adicionar pasta** e aponte pra um repo git seu.
As configurações ficam em `~/.maestria/config.json`.
