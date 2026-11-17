# Curator — common tasks. Run `make` to see them.
VEROVIO_TAG := version-6.4.1
VEROVIO_DIR := packages/score_engine/third_party/verovio
# Written after the patches are applied; hook/build.dart refuses to build when a patch is newer.
VEROVIO_STAMP := $(VEROVIO_DIR)/.curated-score-patched
PATCHES := $(sort $(wildcard patches/*.patch))
# The web player, zipped (see web-player).
WEB_PLAYER := app/assets/web_player/player.zip
# Shown in Settings ▸ About.
COMMIT := --dart-define=CURATOR_COMMIT=$(shell git rev-parse --short HEAD 2>/dev/null)
# Curator Link, the ARA plug-in (docs/daw-link.md): the SDKs it is built on, at these tags, and
# the zip of its VST3 and Audio Unit the app bundles (Settings ▸ DAW Link installs them). Not in git.
ARA_TAG := releases/2.3.0
VST3_TAG := v3.8.0_build_66
AU_SDK_TAG := AudioUnitSDK-1.4.0
DAW_LINK_SDKS := daw_link/third_party
DAW_LINK_ZIP := app/assets/daw_link/CuratorLink.zip
APP_VERSION = $(shell sed -n 's/^version: *\([0-9.]*\)+.*/\1/p' app/pubspec.yaml)
APP_BUILD = $(shell sed -n 's/^version: *[0-9.]*+\([0-9]*\).*/\1/p' app/pubspec.yaml)
# The release's patch, kept apart from the build (the version's patch): updater.dart's appReleasePatch.
APP_RELEASE_PATCH = $(shell sed -n "s/^const appReleasePatch = '\(.*\)';/\1/p" app/lib/updater.dart)
XCODE := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR ?= $(if $(wildcard $(XCODE)),$(XCODE),)

.PHONY: help setup run build web-player daw-link l10n extension-docs plugin-docs test check versions smoke doctor clean

help:
	@echo "make setup   – one-time: fetch and patch Verovio $(VEROVIO_TAG), get Dart packages"
	@echo "make run     – launch the app (macOS)"
	@echo "make build   – build the release app (app/build/macos/Build/Products/Release)"
	@echo "make web-player – build the web player File ▸ Export to Web… copies (run and build do when it is out of date)"
	@echo "make daw-link – build Curator Link, the ARA plug-in (VST3, AU) for DAWs (run and build do when it is out of date)"
	@echo "make l10n    – put new interface text into the translation files (app/assets/l10n, synced with Crowdin)"
	@echo "make extension-docs – write docs/extension-api.md from the guide and the extension API's own list"
	@echo "make plugin-docs – write docs/plugin-api.md from the guide and the plugin API's own list"
	@echo "make test    – run the engine and app tests (builds the native engine on first run)"
	@echo "make check   – analyze both packages, then run every test"
	@echo "make versions – check that updater.dart says the version pubspec.yaml does (patch = build), and the release patch"
	@echo "make smoke   – build the app and run it: open the sample, engrave, draw, export (opens a window)"
	@echo "make doctor  – check that the required tools are installed"
	@echo "make clean   – remove build outputs"

setup: $(VEROVIO_STAMP)
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

run: setup $(WEB_PLAYER) $(DAW_LINK_ZIP)
	cd app && flutter run -d macos $(COMMIT)

# What the Release workflow (.github/workflows/release.yml) builds and zips.
build: setup $(WEB_PLAYER) $(DAW_LINK_ZIP)
	cd app && flutter build macos --release $(COMMIT)

# The web player File ▸ Export to Web… copies beside a page: the app package built for the web
# from lib/web_player/main.dart, zipped without what a page never loads (tool/pack_web_player.dart)
# into an asset the app bundles (WEB_PLAYER). Not in git; made again when any Dart source changes.
$(WEB_PLAYER): $(shell find app/lib packages/score_engine/lib -name '*.dart') app/web/index.html app/tool/pack_web_player.dart
	$(MAKE) web-player

web-player: setup
	cd app && flutter build web -t lib/web_player/main.dart --release --no-web-resources-cdn --no-wasm-dry-run -o build/web_player $(COMMIT)
	cd app && dart tool/pack_web_player.dart

# Curator Link (daw_link/, docs/daw-link.md): Celemony's ARA SDK, Steinberg's VST3 SDK and Apple's
# AudioUnitSDK fetched at the tags above, the plug-in built with Curator's version (universal,
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

$(DAW_LINK_ZIP): $(DAW_LINK_SDK_FILES) $(shell find daw_link/src daw_link/mac daw_link/test -type f) daw_link/CMakeLists.txt app/assets/daw_link/LICENSES.txt app/pubspec.yaml
	cmake -S daw_link -B daw_link/build -DLINK_VERSION=$(APP_VERSION) -DLINK_BUILD=$(APP_BUILD) -DLINK_RELEASE_PATCH=$(APP_RELEASE_PATCH) "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64"
	cmake --build daw_link/build -j 8
	daw_link/build/link_host "daw_link/build/out/Curator Link.vst3" "daw_link/build/out/Curator Link.component"
	rm -f $@
	cd daw_link/build/out && zip -qry "$(CURDIR)/$@" "Curator Link.vst3" "Curator Link.component"

daw-link: $(DAW_LINK_ZIP)

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
versions:
	@v=$$(sed -n 's/^version: *\([0-9.]*+[0-9]*\).*/\1/p' app/pubspec.yaml); \
	mm=$$(sed -n "s/^const _majorMinor = '\([0-9]*\.[0-9]*\)';/\1/p" app/lib/updater.dart); \
	b=$$(sed -n 's/^const appBuild = \([0-9]*\);/\1/p' app/lib/updater.dart); \
	r=$$(sed -n "s/^const appReleasePatch = '\([0-9A-Za-z-]*\)';/\1/p" app/lib/updater.dart); \
	[ -n "$$v" ] && [ "$$v" = "$$mm.$$b+$$b" ] \
		|| { echo "✗ app/pubspec.yaml says $${v:-no version}, app/lib/updater.dart $$mm.$$b+$$b: make them the same (the patch is the build)"; exit 1; }; \
	[ -n "$$r" ] || { echo "✗ app/lib/updater.dart's appReleasePatch is empty, or not letters, digits and -"; exit 1; }; \
	echo "✓ version $$v, release $$mm.$$r"

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
