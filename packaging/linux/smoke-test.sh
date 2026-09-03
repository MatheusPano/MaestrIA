#!/usr/bin/env bash
# O .deb instalado numa Ubuntu recém-nascida, e aberto.
#
# Existe porque o Mac de quem builda mente: toda máquina que já rodou um app
# gráfico tem EGL, GTK e meia dúzia de libs que ninguém declarou -- e foi
# exatamente um `libEGL.so.1` faltando no `Depends:` que passou pelo build
# inteiro, pelo `dpkg-deb --info` e só apareceu aqui.
set -euo pipefail

DEB="${1:-}"
if [ -z "$DEB" ]; then
  DEB=$(ls -1t "$(dirname "${BASH_SOURCE[0]}")/dist"/*.deb 2>/dev/null | head -1 || true)
fi
[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "nenhum .deb pra testar -- rode 'make deb' antes." >&2; exit 1; }

DEB_DIR=$(cd "$(dirname "$DEB")" && pwd)
DEB_NAME=$(basename "$DEB")
echo "==> testando $DEB_NAME numa ubuntu:22.04 limpa"

docker run --rm --platform linux/amd64 -v "$DEB_DIR":/dist:ro ubuntu:22.04 bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq '/dist/$DEB_NAME' >/tmp/apt.log 2>&1 || { echo 'FALHOU: apt não instalou'; tail -20 /tmp/apt.log; exit 1; }
echo '-- instalado; o apt resolveu as dependências sozinho'

# Xvfb dá a tela; o mesa faz as vezes da placa de vídeo que um container não
# tem. Num desktop de verdade os dois vêm com o sistema.
apt-get install -y -qq xvfb dbus-x11 libgl1-mesa-dri >/dev/null 2>&1

echo '-- abrindo por 20s'
set +e
xvfb-run -a timeout 20 maestria > /tmp/run.log 2>&1
code=\$?
if [ \$code -eq 124 ]; then
  echo 'OK: ficou de pé os 20 segundos'
  exit 0
fi
echo \"FALHOU: o app saiu sozinho com \$code\"
cat /tmp/run.log
exit 1
"
