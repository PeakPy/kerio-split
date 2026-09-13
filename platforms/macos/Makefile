.PHONY: build release dmg pkg clean open

ROOT := $(CURDIR)
REPO := $(abspath $(ROOT)/../..)
DIST := $(REPO)/dist
APP  := $(DIST)/KerioSplit.app

release:
	@$(REPO)/scripts/sync-branding.sh
	@$(ROOT)/Scripts/release.sh

build:
	@$(REPO)/scripts/sync-branding.sh
	@$(ROOT)/Scripts/release.sh --app-only

dmg: release

pkg: release

clean:
	rm -rf "$(DIST)"

open: build
	open "$(APP)"
