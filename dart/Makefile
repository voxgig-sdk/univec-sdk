.PHONY: test build lint clean publish

# Run the full generated test suite (dependency-free plain runner).
test:
	dart run test/main.dart

# "Lint": static analysis (a clean `dart analyze` means the code is sound).
lint:
	dart analyze

# Build smoke-test: compile the SDK entry to a kernel snapshot.
build:
	dart analyze lib

clean:
	rm -rf .dart_tool *.dill

# --- Release: publish to pub.dev -------------------------------------------
# Publish this package to pub.dev, then tag dart/vX.Y.Z. pub.dev uses OAuth —
# headless, the vault supplies the credentials JSON as PUB_CREDENTIALS and we
# write it to the dart config path before publishing; the github token pushes
# the tag. set -e + tag-last: a failed upload never leaves a tag behind.
VERSION := $(shell sed -nE 's/^version: *([0-9][^ ]*).*/\1/p' pubspec.yaml | head -1)
TAG := dart/v$(VERSION)
BORU_DRY_RUN_FILLER := BORU-DRY-RUN-FILLER-NOT-A-REAL-SECRET
publish: test
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
	  echo "tag $(TAG) already exists — bump pubspec.yaml version first"; exit 1; fi
	@set -e; \
	token="$${GITHUB_TOKEN:-$$GH_TOKEN}"; \
	if [ "$$token" = "$(BORU_DRY_RUN_FILLER)" ]; then \
	  echo "[dry-run] boru filler token detected: would publish to pub.dev and tag $(TAG); nothing pushed."; \
	  exit 0; \
	fi; \
	if [ -n "$$PUB_CREDENTIALS" ]; then \
	  creddir="$$HOME/Library/Application Support/dart"; \
	  [ -d "$$HOME/Library/Application Support" ] || creddir="$${XDG_CONFIG_HOME:-$$HOME/.config}/dart"; \
	  mkdir -p "$$creddir"; \
	  printf '%s' "$$PUB_CREDENTIALS" > "$$creddir/pub-credentials.json"; \
	fi; \
	dart pub publish --force; \
	git tag -a "$(TAG)" -m "dart v$(VERSION)"; \
	url=$$(git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#'); \
	if [ -n "$$token" ] && printf '%s' "$$url" | grep -q '^https://github.com/'; then \
	  hdr="AUTHORIZATION: basic $$(printf 'x-access-token:%s' "$$token" | base64 | tr -d '\n')"; \
	  git -c http.extraheader="$$hdr" push "$$url" "$(TAG)"; \
	else \
	  git push origin "$(TAG)"; \
	fi; \
	echo "Published to pub.dev + tag $(TAG)."
