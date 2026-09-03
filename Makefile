# maestria -- atalhos de build e empacotamento.
#
# `make` sozinho mostra o que dá pra fazer. O alvo do dia a dia é `make deb`.

.DEFAULT_GOAL := help
SHELL := /bin/bash

# A versão do Flutter, num lugar só: daqui ela vai tanto pra análise local
# quanto pro container que compila o .deb. Se as duas divergirem, o erro
# aparece depois de sete minutos de build em vez de um segundo de analyze.
FLUTTER_VERSION ?= 3.35.7
export FLUTTER_VERSION

# O flutter da máquina: o do PATH, se houver; senão o que o fvm guarda -- e o
# caminho do cache é perguntado ao próprio fvm, que é quem sabe.
# `make FLUTTER=/caminho/do/flutter x` passa por cima de tudo isto.
FVM_CACHE := $(shell fvm api context 2>/dev/null | sed -n 's/.*"cachePath": *"\([^"]*\)".*/\1/p')
FLUTTER   ?= $(shell command -v flutter 2>/dev/null || \
               ls -1 "$(FVM_CACHE)/versions/$(FLUTTER_VERSION)/bin/flutter" 2>/dev/null || \
               ls -1d "$(FVM_CACHE)"/versions/*/bin/flutter 2>/dev/null | sort -V | tail -1)

DIST     := packaging/linux/dist
MAC_DIST := packaging/macos/dist
VERSION  := $(shell sed -n 's/^version: *\([0-9][^+]*\)+\([0-9]*\).*/\1-\2/p' pubspec.yaml)
# Sem a revisão: é o que vira a tag, e `v1.0.2-1` não é uma versão de release.
RAW_VERSION := $(shell sed -n 's/^version: *\([0-9][^+ ]*\).*/\1/p' pubspec.yaml)
DEB      := $(DIST)/maestria_$(VERSION)_amd64.deb

.PHONY: help deb deb-only deb-test dmg release analyze test bump clean tag

help:
	@echo "maestria $(VERSION)"
	@echo
	@echo "  make deb        analisa e gera o .deb em $(DIST)/ (~7 min)"
	@echo "  make deb-only   gera o .deb sem analisar antes"
	@echo "  make deb-test   instala o .deb numa ubuntu limpa e abre o app"
	@echo "  make dmg        gera o .dmg do Mac em $(MAC_DIST)/"
	@echo "  make release    analisa, testa, gera e testa o .deb -- o caminho completo"
	@echo
	@echo "  make tag        publica a v$(RAW_VERSION) no GitHub (.deb e .dmg saem do CI)"
	@echo
	@echo "  make analyze    flutter analyze"
	@echo "  make test       flutter test"
	@echo "  make bump V=1.0.1   sobe a versão no pubspec (o apt só atualiza se ela mudar)"
	@echo "  make clean      apaga os .deb gerados"
	@echo
	@echo "  o .deb precisa do Docker de pé (OrbStack ou Docker Desktop)."
	@echo "  quem for usar o app precisa do Claude Code instalado -- veja"
	@echo "  packaging/linux/INSTALAR.md, que vai junto com o pacote."

# Analisar antes de empacotar não é zelo: o build roda num container e leva
# sete minutos pra descobrir um erro que o analisador acha em um segundo.
analyze:
ifeq ($(FLUTTER),)
	@echo "flutter não encontrado -- pulando a análise. (make FLUTTER=/caminho/do/flutter)"
else
	@$(FLUTTER) analyze
endif

test:
ifeq ($(FLUTTER),)
	@echo "flutter não encontrado -- pulando os testes. (make FLUTTER=/caminho/do/flutter)"
else
	@$(FLUTTER) test
endif

deb: analyze deb-only

deb-only:
	@./packaging/linux/build-deb.sh

deb-test:
	@./packaging/linux/smoke-test.sh

dmg:
	@./packaging/macos/make-dmg.sh

release: analyze test deb-only deb-test
	@echo
	@echo "pronto: $(DEB)"
	@echo "-- pra publicar em vez de mandar por mensagem, veja 'make tag'."

# O caminho normal de uma versão nova: quem empacota é o CI, e o que se faz
# aqui é dizer que a versão está pronta. Ver .github/workflows/release.yml.
tag:
	@git diff --quiet || { echo "há alterações não commitadas -- commite antes de taguear."; exit 1; }
	@git tag "v$(RAW_VERSION)"
	@git push origin "v$(RAW_VERSION)"
	@echo
	@echo "v$(RAW_VERSION) empurrada. o .deb e o .dmg aparecem em"
	@echo "https://github.com/MatheusPano/MaestrIA/releases/tag/v$(RAW_VERSION) em ~15 min."

# O apt se recusa a instalar por cima da mesma versão. Toda leva nova que sair
# pra alguém que já tem o app instalado precisa passar por aqui primeiro.
bump:
ifndef V
	@echo "uso: make bump V=1.0.1"; exit 1
endif
	@perl -pi -e 's/^version: .*/version: $(V)+1/' pubspec.yaml
	@echo "pubspec: $$(grep '^version:' pubspec.yaml)"

clean:
	@rm -rf $(DIST) $(MAC_DIST)
	@echo "$(DIST) e $(MAC_DIST) limpos"
