# OpenWisper build entry points. Heavy lifting lives in scripts/ so this file
# stays stable. SIZE picks the whisper model for `make model`.
#
# NOTE: this machine's Command Line Tools ship a broken SwiftPM ManifestAPI
# (libPackageDescription.dylib exports no symbols), so we prefer the Homebrew
# Swift toolchain when present.
SWIFT ?= $(shell ( ls -d $(HOME)/Library/Developer/Toolchains/swift-*.xctoolchain/usr/bin/swift 2>/dev/null; ls /opt/homebrew/opt/swift/bin/swift 2>/dev/null; echo swift ) | head -1)
SIZE ?= small.en
CONFIG ?= release
DIST := dist
APP := $(DIST)/OpenWisper.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all setup deps model build app run smoke test install clean distclean check-deps

all: build

setup:           ## Fresh clone -> working app: deps + model + install, then launch it
	@# Recursive $(MAKE) rather than prerequisites so the three steps stay
	@# ordered even under `make -j`; deps must finish before install builds.
	$(MAKE) deps
	$(MAKE) model
	$(MAKE) install
	@echo ""
	@echo "OpenWisper is running in your menu bar — there is no Dock icon."
	@echo "Nothing will work until the three permissions are granted:"
	@echo "  README.md -> Permissions, or click the menu bar icon ->"
	@echo "  \"Open OpenWisper...\" and work through the Permissions page."

check-deps:
	@[ -f Vendor/whisper-install/lib/libwhisper_merged.a ] || { echo "whisper.cpp is not vendored yet — run 'make deps' first."; exit 1; }

deps:            ## Fetch + build whisper.cpp static libs into Vendor/
	bash scripts/fetch_whisper.sh

model:           ## Download a ggml model (SIZE=tiny.en|base.en|small.en|small|medium.en|medium|large-v3-turbo)
	bash scripts/download_model.sh $(SIZE)

build: check-deps
	$(SWIFT) build -c $(CONFIG)

app: build       ## Assemble + ad-hoc sign dist/OpenWisper.app
	SWIFT="$(SWIFT)" bash scripts/make_app.sh $(CONFIG)

run: check-deps  ## Dev run from the terminal (TCC grants go to your terminal app, not OpenWisper!)
	$(SWIFT) run -c $(CONFIG) OpenWisper

smoke: check-deps ## End-to-end local whisper check (tiny.en + bundled jfk.wav)
	bash scripts/download_model.sh tiny.en
	$(SWIFT) run -c $(CONFIG) whisper-smoke

test:
	$(SWIFT) test

install: app     ## Replace /Applications/OpenWisper.app (quits a running copy first, relaunches after)
	@# Quit first: replacing the bundle under a running instance leaves a
	@# zombie whose single-instance guard then swallows every fresh launch —
	@# invisibly, because an LSUIElement app has no Dock icon.
	@if pgrep -x OpenWisper >/dev/null 2>&1; then \
		osascript -e 'tell application "OpenWisper" to quit' >/dev/null 2>&1 || true; \
		sleep 1; \
		pkill -x OpenWisper 2>/dev/null || true; \
	fi
	rm -rf /Applications/OpenWisper.app
	ditto $(APP) /Applications/OpenWisper.app
	@# One LaunchServices identity: (re)register the install and forget the
	@# dev build in dist/, so TCC and System Settings never see two OpenWispers.
	@$(LSREGISTER) -f /Applications/OpenWisper.app 2>/dev/null || true
	@$(LSREGISTER) -u "$(abspath $(APP))" 2>/dev/null || true
	open /Applications/OpenWisper.app
	@echo "Installed and launched. Grant permissions from the window (see README)."

clean:
	rm -rf .build $(DIST)

distclean: clean
	rm -rf Vendor
