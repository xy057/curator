# Curator — common tasks. Run `make` to see them.
VEROVIO_TAG := version-6.3.0
VEROVIO_DIR := packages/score_engine/third_party/verovio
# Written after the patches are applied; hook/build.dart refuses to build when a patch is newer.
VEROVIO_STAMP := $(VEROVIO_DIR)/.curated-score-patched
PATCHES := $(sort $(wildcard patches/*.patch))
XCODE := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR ?= $(if $(wildcard $(XCODE)),$(XCODE),)

.PHONY: help setup run build test check doctor clean

help:
	@echo "make setup   – one-time: fetch and patch Verovio $(VEROVIO_TAG), get Dart packages"
	@echo "make run     – launch the app (macOS)"
	@echo "make build   – build the release app (app/build/macos/Build/Products/Release)"
	@echo "make test    – run the engine and app tests (builds the native engine on first run)"
	@echo "make check   – analyze both packages, then run every test"
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

run: setup
	cd app && flutter run -d macos

# What the Release workflow (.github/workflows/release.yml) builds and zips.
build: setup
	cd app && flutter build macos --release

# Every test runs on the bundled demo project (app/assets/demo), so a fresh clone can run them all.
test: setup
	cd packages/score_engine && flutter test
	cd app && flutter test

check: setup
	cd packages/score_engine && flutter analyze
	cd app && flutter analyze
	$(MAKE) test

doctor:
	@xcodebuild -license check >/dev/null 2>&1 && echo "✓ Xcode ready" \
		|| { echo "✗ Xcode not ready. Run once in Terminal:"; \
		     echo "    sudo xcode-select -s $(XCODE) && sudo xcodebuild -license accept"; exit 1; }
	@command -v flutter >/dev/null && echo "✓ $$(flutter --version | head -1)" || echo "✗ flutter missing: brew install --cask flutter"
	@command -v cmake >/dev/null && echo "✓ $$(cmake --version | head -1)" || echo "✗ cmake missing: brew install cmake"

clean:
	cd app && flutter clean
	cd packages/score_engine && flutter clean
