.PHONY: build release dmg clean

ROOT := $(CURDIR)
DIST := $(ROOT)/dist
APP  := $(DIST)/KerioSplit.app

build:
	@$(ROOT)/Scripts/release.sh --app-only

release:
	@$(ROOT)/Scripts/release.sh

dmg: release

clean:
	rm -rf "$(DIST)"

open: build
	open "$(APP)"
