.PHONY: build release release-all release-macos release-linux release-windows \
	dmg pkg clean open help version test-core test-linux-docker

MACOS := platforms/macos
PYTHONPATH_CORE := core:platforms/linux:platforms/windows

help:
	@echo "Kerio Split"
	@echo "  make build              macOS app → dist/KerioSplit.app"
	@echo "  make release-macos      macOS pkg + uninstall + DMG → dist/"
	@echo "  make release-linux      Linux CLI tar.gz → dist/"
	@echo "  make release-windows    Windows CLI zip → dist/"
	@echo "  make release / release-all   all platform archives"
	@echo "  make test-core          shared Python unit tests (dry-run)"
	@echo "  make test-linux-docker  Linux iproute2 smoke in Docker"
	@echo "  make version            print VERSION"
	@echo "  make clean              remove dist/"

version:
	@cat VERSION

build:
	@$(MAKE) -C $(MACOS) build

release-macos:
	@$(MAKE) -C $(MACOS) release

release-linux:
	@chmod +x scripts/package-cli.sh
	@./scripts/package-cli.sh linux

release-windows:
	@chmod +x scripts/package-cli.sh
	@./scripts/package-cli.sh windows

release-all: release-macos release-linux release-windows

release: release-all

dmg: release-macos

pkg: release-macos

test-core:
	PYTHONPATH=$(PYTHONPATH_CORE) python3 core/tests/test_core.py

test-linux-docker:
	docker compose -f platforms/linux/docker-compose.yml run --rm --build linux-smoke

clean:
	@$(MAKE) -C $(MACOS) clean
	rm -rf dist

open:
	@$(MAKE) -C $(MACOS) open
