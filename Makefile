# Curator — common tasks. Run `make` to see them.
VEROVIO_TAG := version-6.4.1
VEROVIO_DIR := packages/score_engine/third_party/verovio
# Written after the patches are applied; hook/build.dart refuses to build when a patch is newer.
VEROVIO_STAMP := $(VEROVIO_DIR)/.curated-score-patched
PATCHES := $(sort $(wildcard patches/*.patch))
# flutter_soloud (playback, and every sample read of a recording), patched: this version's archive
# from pub.dev, checked against its SHA-256, unpacked where app/pubspec.yaml's path says, with
# patches/flutter_soloud/*.patch applied (a recording's samples read from every channel, not the
# first alone). Not in git.
SOLOUD_VERSION := 5.2.3
SOLOUD_SHA256 := 9a439ebd477ee7b1c5cdf0f70765fbfae21b484b5b5bfd1446057f61b4111003
SOLOUD_DIR := packages/third_party/flutter_soloud
SOLOUD_ARCHIVE := packages/third_party/flutter_soloud-$(SOLOUD_VERSION).tar.gz
SOLOUD_STAMP := $(SOLOUD_DIR)/.curated-score-patched-$(SOLOUD_VERSION)
SOLOUD_PATCHES := $(sort $(wildcard patches/flutter_soloud/*.patch))
# The web player, zipped (see web-player).
WEB_PLAYER := app/assets/web_player/player.zip
# Shown in Settings ▸ About.
COMMIT := --dart-define=CURATOR_COMMIT=$(shell git rev-parse --short HEAD 2>/dev/null)
# Attacca, the ARA plug-in (docs/daw-link.md): the SDKs it is built on, at these tags, and
# the zip of its VST3 and Audio Unit the app bundles (Settings ▸ DAW Link installs them). Not in git.
ARA_TAG := releases/2.3.0
VST3_TAG := v3.8.0_build_66
AU_SDK_TAG := AudioUnitSDK-1.4.0
DAW_LINK_SDKS := daw_link/third_party
DAW_LINK_ZIP := app/assets/daw_link/Attacca.zip
# Attacca for Windows, built on a Mac (daw-link-windows): llvm-mingw (github.com/mstorsjo/llvm-mingw:
# Clang, LLD and mingw-w64, which make Windows programs on a Mac), this release of it and the
# SHA-256 of its macOS download; and the zip of the two VST3s, which the Release workflow hands
# its Windows build as that app's Attacca.zip.
LLVM_MINGW_VERSION := 20261020
LLVM_MINGW_SHA256 := e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e
LLVM_MINGW := $(DAW_LINK_SDKS)/llvm-mingw-$(LLVM_MINGW_VERSION)
DAW_LINK_WINDOWS := daw_link/build-windows
DAW_LINK_WINDOWS_ZIP := $(DAW_LINK_WINDOWS)/Attacca.zip
# Attacca's own version, a whole number apart from Curator's (docs/daw-link.md ▸ Its version):
# where it is written, what it is, and the plug-in's sources as one SHA-256, which `make versions`
# compares with the one `make attacca-seal` wrote down (daw_link/sources.sha256).
ATTACCA_VERSION_FILE := app/lib/attacca_version.dart
ATTACCA_VERSION = $(shell sed -n 's/^const attaccaVersion = \([0-9]*\);/\1/p' $(ATTACCA_VERSION_FILE))
ATTACCA_SEAL := daw_link/sources.sha256
ATTACCA_SOURCES = find daw_link/CMakeLists.txt daw_link/src daw_link/mac -type f ! -name '.*' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1
XCODE := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR ?= $(if $(wildcard $(XCODE)),$(XCODE),)

.PHONY: help setup run build web-player web-plugins web-plugin-docs daw-link daw-link-windows attacca-seal l10n extension-docs plugin-docs script-docs formats test check versions smoke doctor clean

help:
	@echo "make setup   – one-time: fetch and patch Verovio $(VEROVIO_TAG) and flutter_soloud $(SOLOUD_VERSION), get Dart packages"
	@echo "make run     – launch the app (macOS)"
	@echo "make build   – build the release app (app/build/macos/Build/Products/Release)"
	@echo "make web-player – build the web player File ▸ Export to Web… copies (run and build do when it is out of date)"
	@echo "make web-plugins – build the web player's plugin host and Curator's own web plugins from their TypeScript (needs bun; what it writes is in git)"
	@echo "make web-plugin-docs – write docs/web-plugin-api.md from the guide and the web plugin API's types"
	@echo "make daw-link – build Attacca, the ARA plug-in (VST3, AU) for DAWs (run and build do when it is out of date)"
	@echo "make daw-link-windows – build Attacca for Windows (VST3, x86_64) on this Mac, into $(DAW_LINK_WINDOWS_ZIP)"
	@echo "make l10n    – put new interface text into the translation files (app/assets/l10n, synced with Crowdin)"
	@echo "make extension-docs – write docs/extension-api.md from the guide and the extension API's own list"
	@echo "make plugin-docs – write docs/plugin-api.md from the guide and the plugin API's own list"
	@echo "make script-docs – write docs/lane-script.md from the guide and the script language's own list"
	@echo "make formats – after changing what a project or settings file holds: keep what this build writes as a format of its own (app/test/formats)"
	@echo "make test    – run the engine and app tests (builds the native engine on first run)"
	@echo "make check   – analyze both packages, then run every test"
	@echo "make versions – check that updater.dart says the version pubspec.yaml does (patch = build), the release patch, and Attacca's seal"
	@echo "make attacca-seal – after raising Attacca's version ($(ATTACCA_VERSION_FILE)): write down what its sources are now"
	@echo "make smoke   – build the app and run it: open the sample, engrave, draw, export (opens a window)"
	@echo "make doctor  – check that the required tools are installed"
	@echo "make clean   – remove build outputs"

setup: $(VEROVIO_STAMP) $(SOLOUD_STAMP)
	cd packages/score_engine && flutter pub get
	cd app && flutter pub get

$(VEROVIO_DIR)/src/toolkit.cpp:
	git clone --depth 1 --branch $(VEROVIO_TAG) https://github.com/rism-digital/verovio.git $(VEROVIO_DIR)

# Whenever a patch is added or changed, start again from Verovio as released and apply them all,
# so the sources always match patches/. A patch that doesn't apply stops here.
$(VEROVIO_STAMP): $(VEROVIO_DIR)/src/toolkit.cpp $(PATCHES)
	git -C $(VEROVIO_DIR) checkout -q -- .
	git -C $(VEROVIO_DIR) clean -fdq
	@set -e; for p in $(PATCHES); do echo "applying $$p"; git -C $(VEROVIO_DIR) apply "$(CURDIR)/$$p"; done
	touch $@

$(SOLOUD_ARCHIVE):
	mkdir -p $(@D)
	curl -fL --retry 3 -o $@.part https://pub.dev/api/archives/flutter_soloud-$(SOLOUD_VERSION).tar.gz
	echo "$(SOLOUD_SHA256)  $@.part" | shasum -a 256 -c -
	mv $@.part $@

# Likewise: whenever a patch is added or changed (or the version), flutter_soloud as released
# again, every patch applied to it.
$(SOLOUD_STAMP): $(SOLOUD_ARCHIVE) $(SOLOUD_PATCHES)
	rm -rf $(SOLOUD_DIR)
	mkdir -p $(SOLOUD_DIR)
	tar -xzf $(SOLOUD_ARCHIVE) -C $(SOLOUD_DIR)
	@set -e; for p in $(SOLOUD_PATCHES); do echo "applying $$p"; git apply --directory=$(SOLOUD_DIR) "$$p"; done
	touch $@

run: setup $(WEB_PLAYER) $(DAW_LINK_ZIP)
	cd app && flutter run -d macos $(COMMIT)

# What the Release workflow (.github/workflows/release.yml) builds and zips.
build: setup $(WEB_PLAYER) $(DAW_LINK_ZIP)
	cd app && flutter build macos --release $(COMMIT)

# The web player File ▸ Export to Web… copies beside a page: the app package built for the web
# from lib/web_player/main.dart, zipped without what a page never loads (tool/pack_web_player.dart)
# into an asset the app bundles (WEB_PLAYER). Not in git; made again when any Dart source changes.
$(WEB_PLAYER): $(shell find app/lib packages/score_engine/lib -name '*.dart') app/web/index.html app/web/plugin_host.js app/tool/pack_web_player.dart
	$(MAKE) web-player

web-player: setup
	cd app && flutter build web -t lib/web_player/main.dart --release --no-web-resources-cdn --no-wasm-dry-run -o build/web_player $(COMMIT)
	cd app && dart tool/pack_web_player.dart

# The web player's plugin host (web_plugins/host.ts → app/web/plugin_host.js, which the player loads when a page
# has plugins) and Curator's own web plugins (app/assets/web_plugins/<id>/src/main.ts → main.js), built from
# their TypeScript with bun, then checked by TypeScript itself. What it writes is in git, with what it was built
# from written down (web_plugins/sources.sha256, which in_step_test checks), so building the web player and the
# app needs neither: run it after changing any of their sources.
web-plugins:
	bun web_plugins/build.ts
	cd web_plugins && bunx -p typescript tsc -p tsconfig.json

# Attacca (daw_link/, docs/daw-link.md): Celemony's ARA SDK, Steinberg's VST3 SDK and Apple's
# AudioUnitSDK fetched at the tags above, the plug-in built with its own version (universal,
# ad-hoc signed), checked by a DAW in miniature (daw_link/test/link_host.cpp) and both bundles zipped into the asset Settings ▸ DAW Link installs from.
$(DAW_LINK_SDKS)/ARA_SDK/ARA_Library/PlugIn/ARAPlug.h:
	git clone --depth 1 --branch $(ARA_TAG) --recurse-submodules --shallow-submodules https://github.com/Celemony/ARA_SDK.git $(DAW_LINK_SDKS)/ARA_SDK

$(DAW_LINK_SDKS)/vst3sdk/public.sdk/source/main/macmain.cpp:
	git clone --depth 1 --branch $(VST3_TAG) https://github.com/steinbergmedia/vst3sdk.git $(DAW_LINK_SDKS)/vst3sdk
	git -C $(DAW_LINK_SDKS)/vst3sdk submodule update --init --depth 1 -- base pluginterfaces public.sdk

$(DAW_LINK_SDKS)/AudioUnitSDK/src/AudioUnitSDK/AUBase.cpp:
	git clone --depth 1 --branch $(AU_SDK_TAG) https://github.com/apple/AudioUnitSDK.git $(DAW_LINK_SDKS)/AudioUnitSDK

DAW_LINK_SDK_FILES := $(DAW_LINK_SDKS)/ARA_SDK/ARA_Library/PlugIn/ARAPlug.h $(DAW_LINK_SDKS)/vst3sdk/public.sdk/source/main/macmain.cpp \
	$(DAW_LINK_SDKS)/AudioUnitSDK/src/AudioUnitSDK/AUBase.cpp

$(DAW_LINK_ZIP): $(DAW_LINK_SDK_FILES) $(shell find daw_link/src daw_link/mac daw_link/test -type f) daw_link/CMakeLists.txt app/assets/daw_link/LICENSES.txt $(ATTACCA_VERSION_FILE)
	cmake -S daw_link -B daw_link/build -DLINK_VERSION=$(ATTACCA_VERSION) "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64"
	cmake --build daw_link/build -j 8
	daw_link/build/link_host "daw_link/build/out/Attacca.vst3" "daw_link/build/out/Attacca Capturer.vst3" "daw_link/build/out/Attacca.component"
	rm -f $@
	cd daw_link/build/out && zip -qry "$(CURDIR)/$@" "Attacca.vst3" "Attacca Capturer.vst3" "Attacca.component"

daw-link: $(DAW_LINK_ZIP)

# Attacca for Windows (docs/daw-link.md ▸ Building and checking it): the same sources, built here
# with llvm-mingw for x86_64 Windows as two VST3 bundles (no Audio Unit there), nothing but
# Windows' own libraries needed where a DAW loads them. The DAW in miniature is built beside them
# (link_host.exe): it runs on Windows (the Release workflow runs it there before the app is built).
$(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang++:
	mkdir -p $(LLVM_MINGW)
	curl -fL --retry 3 -o $(LLVM_MINGW).tar.xz https://github.com/mstorsjo/llvm-mingw/releases/download/$(LLVM_MINGW_VERSION)/llvm-mingw-$(LLVM_MINGW_VERSION)-ucrt-macos-universal.tar.xz
	echo "$(LLVM_MINGW_SHA256)  $(LLVM_MINGW).tar.xz" | shasum -a 256 -c -
	tar -xf $(LLVM_MINGW).tar.xz -C $(LLVM_MINGW) --strip-components 1
	rm $(LLVM_MINGW).tar.xz

$(DAW_LINK_WINDOWS_ZIP): $(DAW_LINK_SDKS)/ARA_SDK/ARA_Library/PlugIn/ARAPlug.h $(DAW_LINK_SDKS)/vst3sdk/public.sdk/source/main/macmain.cpp \
		$(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang++ $(shell find daw_link/src daw_link/test -type f) daw_link/CMakeLists.txt app/assets/daw_link/LICENSES.txt $(ATTACCA_VERSION_FILE)
	cmake -S daw_link -B $(DAW_LINK_WINDOWS) -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
		-DCMAKE_C_COMPILER=$(CURDIR)/$(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang -DCMAKE_CXX_COMPILER=$(CURDIR)/$(LLVM_MINGW)/bin/x86_64-w64-mingw32-clang++ \
		-DLINK_VERSION=$(ATTACCA_VERSION)
	cmake --build $(DAW_LINK_WINDOWS) -j 8
	rm -f $@
	cd $(DAW_LINK_WINDOWS)/out && zip -qr "$(CURDIR)/$@" "Attacca.vst3" "Attacca Capturer.vst3"

daw-link-windows: $(DAW_LINK_WINDOWS_ZIP)

# Attacca's sources as they are now, written down: `make versions` fails once they are anything
# else, so a changed plug-in can't go out under the version of the one before it. Run it after
# raising attaccaVersion.
attacca-seal:
	@$(ATTACCA_SOURCES) > $(ATTACCA_SEAL)
	@echo "✓ Attacca $(ATTACCA_VERSION) sealed"

# The interface's text: new `.tr` / `.fill` texts into the template Crowdin translates from
# (app/assets/l10n/curator.pot), and every language's file in step with it (tool/l10n.dart;
# docs/translating.md). test/in_step_test.dart fails until it has been run.
l10n:
	cd app && dart run tool/l10n.dart

# docs/extension-api.md: the extension editor's guide (app/assets/help/extensions.md) and the
# reference of the API, from ExtensionApi. test/in_step_test.dart fails until it has been run.
extension-docs:
	cd app && dart run tool/extension_docs.dart

# docs/plugin-api.md: the plugin editor's guide (app/assets/help/plugins.md) and the reference
# of the API, from PluginApi. test/in_step_test.dart fails until it has been run.
plugin-docs:
	cd app && dart run tool/plugin_docs.dart

# docs/web-plugin-api.md: the guide to writing a web plugin (app/assets/help/web-plugins.md) and
# the API as TypeScript declares it (app/assets/web_plugins/curator-web.d.ts).
# test/in_step_test.dart fails until it has been run.
web-plugin-docs:
	cd app && dart run tool/web_plugin_docs.dart

# docs/lane-script.md: the guide to curating by script (app/assets/help/script.md) and the
# language's statements, from LaneScriptApi. test/in_step_test.dart fails until it has been run.
script-docs:
	cd app && dart run tool/script_docs.dart

# app/test/formats: a project and a settings file in every format a Curator has saved in since
# layout 2, which every later build must open as the same project (docs/project-format.md). After
# a change to what they hold, and the build raised, this keeps what this build writes as
# <build>.ccs and <build>.ccf, never over a folder kept already.
# test/project_file_test.dart fails until it has been run.
formats:
	cd app && flutter test test/project_file_test.dart --plain-name 'older formats' --update-goldens

# Every test runs on the bundled demo project (app/assets/demo), so a fresh clone can run them all.
test: setup
	cd packages/score_engine && flutter test
	cd app && flutter test

check: setup versions
	cd packages/score_engine && flutter analyze
	cd app && flutter analyze
	$(MAKE) test

# The version is written twice: app/pubspec.yaml's `version: 0.5.3+70`, and appVersion / appBuild in
# app/lib/updater.dart, which the app reports and the updater compares with the latest release
# (one left behind would offer the app its own release). The Release workflow runs this too.
# Attacca's version is its own (attaccaVersion), raised only when the plug-in changes: its
# sources must be the ones sealed at that version (attacca-seal), or a changed Attacca would go
# out looking like the one DAWs already have, and never be told it is outdated.
versions:
	@v=$$(sed -n 's/^version: *\([0-9.]*+[0-9]*\).*/\1/p' app/pubspec.yaml); \
	mm=$$(sed -n "s/^const _majorMinor = '\([0-9]*\.[0-9]*\)';/\1/p" app/lib/updater.dart); \
	b=$$(sed -n 's/^const appBuild = \([0-9]*\);/\1/p' app/lib/updater.dart); \
	r=$$(sed -n "s/^const appReleasePatch = '\([0-9A-Za-z-]*\)';/\1/p" app/lib/updater.dart); \
	[ -n "$$v" ] && [ "$$v" = "$$mm.$$b+$$b" ] \
		|| { echo "✗ app/pubspec.yaml says $${v:-no version}, app/lib/updater.dart $$mm.$$b+$$b: make them the same (the patch is the build)"; exit 1; }; \
	[ -n "$$r" ] || { echo "✗ app/lib/updater.dart's appReleasePatch is empty, or not letters, digits and -"; exit 1; }; \
	echo "✓ version $$v, release $$mm.$$r"
	@a="$(ATTACCA_VERSION)"; \
	[ -n "$$a" ] && [ "$$a" -gt 0 ] || { echo "✗ $(ATTACCA_VERSION_FILE) has no attaccaVersion (a whole number)"; exit 1; }; \
	[ "$$($(ATTACCA_SOURCES))" = "$$(cat $(ATTACCA_SEAL) 2>/dev/null)" ] \
		|| { echo "✗ Attacca (daw_link/) changed since its version $$a was sealed: raise attaccaVersion in $(ATTACCA_VERSION_FILE) by one, then make attacca-seal"; exit 1; }; \
	echo "✓ Attacca $$a"

# The app as built, not the test runner: integration_test/app_smoke_test.dart.
smoke: setup
	cd app && flutter test integration_test -d macos

doctor:
	@xcodebuild -license check >/dev/null 2>&1 && echo "✓ Xcode ready" \
		|| { echo "✗ Xcode not ready. Run once in Terminal:"; \
		     echo "    sudo xcode-select -s $(XCODE) && sudo xcodebuild -license accept"; exit 1; }
	@command -v flutter >/dev/null && echo "✓ $$(flutter --version | head -1)" || echo "✗ flutter missing: brew install --cask flutter"
	@command -v cmake >/dev/null && echo "✓ $$(cmake --version | head -1)" || echo "✗ cmake missing: brew install cmake"

clean:
	cd app && flutter clean
	cd packages/score_engine && flutter clean
