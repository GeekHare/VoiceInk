# All build entry points use the same dependency/bootstrap implementation.
.DEFAULT_GOAL := local
ROOT := $(CURDIR)
SCRIPT := $(ROOT)/scripts/build-local-macos.sh
APP := $(ROOT)/.local-build/output/VoiceInk.app

.PHONY: all local build check healthcheck whisper setup dev run clean help
all local build:
	@bash "$(SCRIPT)"

check healthcheck:
	@bash "$(SCRIPT)" --check

whisper setup:
	@bash "$(SCRIPT)" --whisper-only

dev:
	@bash "$(SCRIPT)" --debug
	@open "$(APP)"

run:
	@open "$(APP)"

clean:
	@echo "Removing project-local tools, dependencies and build products..."
	@rm -rf "$(ROOT)/.local-build"

help:
	@echo "make local/build/all  Build a locally signed Release app"
	@echo "make check            Check Xcode without installing anything"
	@echo "make whisper/setup    Prepare pinned macOS whisper XCFramework"
	@echo "make dev              Build Debug and launch"
	@echo "make run              Launch the last exported app"
	@echo "make clean            Remove only this repository's .local-build"
	@echo "Install: ./scripts/build-local-macos.sh --install"
	@echo "More options: ./scripts/build-local-macos.sh --help"
