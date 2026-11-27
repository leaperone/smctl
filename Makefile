# Pulse — build, package and release.
#
# The CI release (.github/workflows/release.yml) runs the same targets, so a
# release can be reproduced locally. `make release` is the manual fallback.

VERSION ?=
TAP_DIR ?= $(CURDIR)/../homebrew-tap
REPO    := fstormacq/pulse

.DEFAULT_GOAL := help
.PHONY: help build test app readme-images package next-version notes tap release clean

define require-version
	@test -n "$(VERSION)" || { echo "error: pass VERSION=x.y.z (make next-version suggests one)"; exit 1; }
	@printf '%s' '$(VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "error: VERSION '$(VERSION)' is not x.y.z"; exit 1; }
endef

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build pulse and pulsed (debug)
	swift build

test: ## Run the tests of both packages
	swift test
	swift test --package-path App

app: ## Build dist/Pulse.app (development version)
	scripts/build-app.sh

readme-images: ## Regenerate the README's screenshots, light and dark, from the current code
	scripts/readme-images.sh

package: ## Build the release assets into dist/release (VERSION=x.y.z)
	$(require-version)
	scripts/package.sh $(VERSION)

next-version: ## Print the version the next release would get (empty: none due)
	@scripts/next-version.sh

notes: ## Print the release notes (VERSION=x.y.z)
	$(require-version)
	@scripts/release-notes.sh $(VERSION)

tap: ## Write the cask and the formula into TAP_DIR (after `make package`)
	$(require-version)
	scripts/update-tap.sh $(VERSION) $(TAP_DIR)

release: ## Manual release from an up-to-date main: package, tag, GitHub release, tap (VERSION=x.y.z)
	$(require-version)
	@command -v gh >/dev/null || { echo "error: the gh CLI is required"; exit 1; }
	@test -d "$(TAP_DIR)/.git" || { echo "error: clone fstormacq/homebrew-tap into $(TAP_DIR) (or pass TAP_DIR=…)"; exit 1; }
	@git fetch -q origin
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "error: HEAD is not origin/main"; exit 1; }
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo "error: uncommitted changes"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "error: v$(VERSION) already exists"; exit 1; }
	scripts/package.sh $(VERSION)
	scripts/release-notes.sh $(VERSION) > dist/release/NOTES.md
	gh release create v$(VERSION) --repo $(REPO) --target "$$(git rev-parse HEAD)" --title "Pulse $(VERSION)" \
		--notes-file dist/release/NOTES.md dist/release/Pulse-$(VERSION).zip dist/release/pulse-cli-$(VERSION)-arm64.tar.gz dist/release/SHA256SUMS
	git -C "$(TAP_DIR)" pull -q --rebase
	scripts/update-tap.sh $(VERSION) $(TAP_DIR)
	git -C "$(TAP_DIR)" add README.md Casks/pulse.rb Formula/pulse-cli.rb
	git -C "$(TAP_DIR)" diff --cached --quiet || git -C "$(TAP_DIR)" commit -q -m "pulse $(VERSION)"
	git -C "$(TAP_DIR)" push -q
	@echo "Released $(VERSION)"

clean: ## Remove build products
	rm -rf .build App/.build dist
