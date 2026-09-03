#!/usr/bin/env bash
# Do fonte ao .dmg que se arrasta pro Applications.
#
#   ./packaging/macos/make-dmg.sh              # compila e empacota
#   ./packaging/macos/make-dmg.sh --no-build   # só empacota o que já está em build/
#
# Só roda num Mac: quem compila app da Apple é o Xcode. O .deb tem o caminho
# inverso -- um container Linux -- e por isso os dois empacotadores não se
# parecem em nada além do nome do arquivo que produzem.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST="$REPO/packaging/macos/dist"
APP="$REPO/build/macos/Build/Products/Release/maestria.app"

cd "$REPO"

# `1.0.2+1` no pubspec vira `1.0.2-1` no nome do arquivo -- o mesmo que o .deb
# faz, pra que as duas metades de uma release se leiam como uma só.
VERSION=$(sed -n 's/^version: *\([0-9][^+ ]*\).*/\1/p' pubspec.yaml | head -1)
REVISION=$(sed -n 's/^version: *[0-9][^+]*+\([0-9]*\).*/\1/p' pubspec.yaml | head -1)
FULL="${VERSION}-${REVISION:-1}"

if [ "${1:-}" != "--no-build" ]; then
  echo "==> flutter build macos --release"
  flutter build macos --release
fi

test -d "$APP" || { echo "não achei $APP -- rode sem --no-build." >&2; exit 1; }

# Universal ou nada: um .dmg só pra Intel e Apple Silicon é o que permite ter
# um link só na página de releases. O `flutter build` já sai assim; se um dia
# parar de sair, é melhor falhar aqui que descobrir pelo Mac de outra pessoa.
ARCHS=$(lipo -info "$APP/Contents/MacOS/maestria" | sed 's/.*: //')
for want in x86_64 arm64; do
  case " $ARCHS " in
    *" $want "*) ;;
    *) echo "o binário não tem $want (só: $ARCHS)" >&2; exit 1 ;;
  esac
done

echo "==> maestria ${FULL} (${ARCHS})"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# `ditto` e não `cp`: ele preserva os metadados do bundle -- e a assinatura
# ad-hoc mora neles. Um `cp -R` entrega um .app que o macOS diz estar corrompido.
ditto "$APP" "$STAGE/maestria.app"
ln -s /Applications "$STAGE/Applications"

# A assinatura sobreviveu à cópia? É a última hora de saber: depois disto o
# arquivo já está a caminho de outra máquina, onde o erro é do outro.
codesign --verify --deep "$STAGE/maestria.app" \
  || { echo "a assinatura do .app não confere depois da cópia" >&2; exit 1; }

mkdir -p "$DIST"
OUT="$DIST/maestria_${FULL}_macos.dmg"
rm -f "$OUT"

echo "==> hdiutil"
hdiutil create -quiet -volname "maestria ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$OUT"

echo
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
