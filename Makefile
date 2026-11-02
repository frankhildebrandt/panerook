.DEFAULT_GOAL := build

export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/clang-module-cache
SWIFT_TEST_FLAGS := --cache-path "$(CURDIR)/.build/cache"
ifeq ($(PANEROOK_DISABLE_BUILD_SANDBOX),1)
SWIFT_TEST_FLAGS += --disable-sandbox
endif

.PHONY: run dev build test clean

run: build
	open build/PaneRook.app

dev:
	./scripts/dev-app.sh

build:
	./scripts/build-app.sh release

test:
	swift test $(SWIFT_TEST_FLAGS)
	swift scripts/test-appcast.swift

clean:
	swift package clean
	rm -rf build
