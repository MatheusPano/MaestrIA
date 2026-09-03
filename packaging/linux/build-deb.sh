#!/usr/bin/env bash
# Gera o .deb do maestria a partir de um Mac (ou de qualquer máquina com Docker).
#
#   ./packaging/linux/build-deb.sh              # amd64, que é o PC de todo mundo
#   PLATFORM=linux/arm64 ./packaging/linux/build-deb.sh
#
# Num Apple Silicon o build amd64 roda emulado e é lento -- conte dezenas de
# minutos na primeira vez. O que demora é o Dart AOT sob qemu; a imagem fica em
# cache e a segunda rodada é só o build.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HERE="$REPO/packaging/linux"
DIST="$HERE/dist"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE="maestria-deb:${PLATFORM##*/}"

if ! docker info >/dev/null 2>&1; then
  echo "o daemon do Docker não está de pé -- abra o OrbStack (ou o Docker Desktop) e rode de novo." >&2
  exit 1
fi

mkdir -p "$DIST"

# A versão vem de fora quando o Makefile a manda, pra que o SDK que compila o
# .deb seja o mesmo que analisou o código aqui fora.
FLUTTER_VERSION="${FLUTTER_VERSION:-3.35.7}"

echo "==> imagem ($PLATFORM, flutter $FLUTTER_VERSION)"
docker build --platform "$PLATFORM" --build-arg "FLUTTER_VERSION=$FLUTTER_VERSION" -t "$IMAGE" "$HERE"

echo "==> build"
docker run --rm --platform "$PLATFORM" \
  -v "$REPO":/src:ro \
  -v "$DIST":/dist \
  "$IMAGE"

echo
echo "pronto: $(ls -1 "$DIST"/*.deb | tail -1)"
