.PHONY: build release dmg pkg clean open help version

MACOS := platforms/macos

help:
	@echo "Kerio Split"
	@echo "  make build    macOS app → dist/KerioSplit.app"
	@echo "  make release  pkg + uninstall pkg + DMG → dist/"
	@echo "  make version  print VERSION"
	@echo "  make clean    remove dist/"

version:
	@cat VERSION

build:
	@$(MAKE) -C $(MACOS) build

release:
	@$(MAKE) -C $(MACOS) release

dmg: release

pkg: release

clean:
	@$(MAKE) -C $(MACOS) clean
	rm -rf dist

open:
	@$(MAKE) -C $(MACOS) open
