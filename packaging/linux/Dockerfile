# A máquina Linux que o Mac não é.
#
# 22.04 e não uma mais nova de propósito: a glibc da imagem é o piso do .deb
# que sai dela, e um binário compilado contra a 2.35 roda em tudo que veio
# depois -- 24.04, Mint, Pop!_OS. O contrário não vale.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Duas listas que só parecem uma: as de cima constroem (o toolchain que o
# `flutter build linux` exige), as de baixo entram no build (gtk) ou empacotam.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip \
      clang cmake ninja-build pkg-config \
      libgtk-3-dev liblzma-dev g++ \
      dpkg-dev fakeroot \
    && rm -rf /var/lib/apt/lists/*

# Fixo, não `stable`: o canal se move e um build que muda de compilador sozinho
# não é reproduzível. 3.35.7 é a mesma versão do fvm da máquina de origem.
ARG FLUTTER_VERSION=3.35.7
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -C /opt -xf /tmp/flutter.tar.xz \
    && rm /tmp/flutter.tar.xz

ENV PATH="/opt/flutter/bin:${PATH}" \
    FLUTTER_SUPPRESS_ANALYTICS=true

# O SDK é um repo git de dono diferente do usuário do container, e o git novo
# recusa isso -- o que o flutter lê como "SDK corrompido".
RUN git config --global --add safe.directory /opt/flutter \
    && flutter config --enable-linux-desktop \
    && flutter precache --linux

COPY make-deb.sh /usr/local/bin/make-deb
RUN chmod +x /usr/local/bin/make-deb

ENTRYPOINT ["/usr/local/bin/make-deb"]
