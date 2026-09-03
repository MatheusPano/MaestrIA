#!/usr/bin/env bash
# Do fonte em /src ao .deb em /dist. Roda dentro do container.
set -euo pipefail

SRC=/src
WORK=/work
DIST=/dist

# O fonte é copiado, não usado no lugar. Duas razões: `build/` e `.dart_tool/`
# do Mac colidem com os do Linux (SDK diferente, artefatos diferentes), e o
# volume vem montado como leitura -- o build precisa escrever.
echo "==> copiando o fonte"
mkdir -p "$WORK"
tar -C "$SRC" \
    --exclude=./build --exclude=./.dart_tool --exclude=./.git \
    --exclude=./macos --exclude=./packaging/linux/dist \
    -cf - . | tar -C "$WORK" -xf -

cd "$WORK"

# `1.0.0+1` no pubspec vira `1.0.0-1` no dpkg: o `+` é separador de outra coisa
# na versão do Debian, e o que vem depois dele é exatamente uma revisão.
VERSION=$(sed -n 's/^version: *\([0-9][^+ ]*\).*/\1/p' pubspec.yaml | head -1)
REVISION=$(sed -n 's/^version: *[0-9][^+]*+\([0-9]*\).*/\1/p' pubspec.yaml | head -1)
DEB_VERSION="${VERSION}-${REVISION:-1}"
ARCH=$(dpkg --print-architecture)
echo "==> maestria ${DEB_VERSION} (${ARCH})"

echo "==> flutter pub get"
flutter pub get

echo "==> flutter build linux --release"
flutter build linux --release

BUNDLE=$(echo build/linux/*/release/bundle)
test -x "$BUNDLE/maestria" || { echo "bundle não saiu em $BUNDLE"; exit 1; }

# A árvore do pacote, montada à mão -- é mais curta que qualquer ferramenta que
# a montaria.
ROOT=/tmp/pkgroot
rm -rf "$ROOT"
APP_ID=br.com.marrow.maestria

install -d "$ROOT/opt/maestria" "$ROOT/usr/bin" \
           "$ROOT/usr/share/applications" "$ROOT/DEBIAN"
cp -a "$BUNDLE/." "$ROOT/opt/maestria/"

# O rpath do binário é `$ORIGIN/lib`, e $ORIGIN é o caminho real do arquivo --
# o link em /usr/bin é resolvido antes, então as libs continuam sendo achadas.
ln -sf /opt/maestria/maestria "$ROOT/usr/bin/maestria"

# O ícone do macOS serve: é PNG quadrado, que é tudo que o hicolor pede.
for size in 512 256 128 64 32; do
  icon="$SRC/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
  [ -f "$icon" ] || continue
  install -d "$ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
  install -m644 "$icon" "$ROOT/usr/share/icons/hicolor/${size}x${size}/apps/${APP_ID}.png"
done

# `StartupWMClass` casa com o `g_set_prgname(APPLICATION_ID)` do runner: sem
# ele a janela aberta vira um segundo ícone genérico na dock do GNOME, solto do
# lançador.
cat > "$ROOT/usr/share/applications/${APP_ID}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=maestria
Comment=Cockpit para sessões do Claude Code
Exec=/opt/maestria/maestria
Icon=${APP_ID}
Terminal=false
Categories=Development;
StartupWMClass=${APP_ID}
DESKTOP

# As dependências de biblioteca, perguntadas ao próprio binário em vez de
# listadas de cabeça: `dpkg-shlibdeps` lê o que o ELF pede e diz de que pacote
# cada coisa vem, com a versão mínima junto.
echo "==> calculando dependências"
SHLIB=/tmp/shlibdeps
rm -rf "$SHLIB"; mkdir -p "$SHLIB/debian"
printf 'Source: maestria\n\nPackage: maestria\nArchitecture: %s\n' "$ARCH" > "$SHLIB/debian/control"
LIB_DEPS=$(cd "$SHLIB" && dpkg-shlibdeps -O --ignore-missing-info \
             "$ROOT/opt/maestria/maestria" "$ROOT/opt/maestria/lib/"*.so 2>/dev/null \
           | sed 's/^shlibs:Depends=//' || true)
: "${LIB_DEPS:=libgtk-3-0 (>= 3.24), libglib2.0-0}"

# O que o shlibdeps não tem como ver: o embedder do Flutter abre EGL e GLES com
# `dlopen`, então nenhum ELF os declara e nenhuma ferramenta os deduz. Sem esta
# linha o app instala limpo e aborta na abertura com
# "Couldn't open libEGL.so.1" -- invisível em qualquer máquina com driver de
# vídeo, fatal numa recém-instalada.
GL_DEPS="libegl1, libgles2"

# `git`, `libnotify-bin` e `xdg-utils` são o que o app shella em runtime; o
# `claude` não está aqui porque não vem do apt -- quem o instala é o usuário.
RUN_DEPS="git, libnotify-bin, xdg-utils"

cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: maestria
Version: ${DEB_VERSION}
Section: devel
Priority: optional
Architecture: ${ARCH}
Depends: ${LIB_DEPS}, ${GL_DEPS}, ${RUN_DEPS}
Recommends: dbus-x11
Maintainer: Matheus Pano <matheus@marrow.com.br>
Description: Cockpit para sessões do Claude Code
 Painéis lado a lado, cada um com uma sessão do Claude Code viva dentro,
 worktrees do git por tarefa e um leitor de markdown para o que as sessões
 escrevem. Requer o Claude Code CLI (claude) instalado e no PATH.
CONTROL

# Os índices de ícone e de .desktop são cache: sem atualizar, o app só aparece
# no menu depois do próximo login.
cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ -x /usr/bin/gtk-update-icon-cache ]; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
if [ -x /usr/bin/update-desktop-database ]; then
  update-desktop-database -q /usr/share/applications || true
fi
POSTINST
chmod 755 "$ROOT/DEBIAN/postinst"
cp "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

mkdir -p "$DIST"
OUT="$DIST/maestria_${DEB_VERSION}_${ARCH}.deb"
fakeroot dpkg-deb --root-owner-group --build "$ROOT" "$OUT"

echo
echo "==> $OUT"
dpkg-deb --info "$OUT" | sed -n '2,12p'
