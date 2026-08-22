.PHONY: test build clean publish

# The gradle wrapper's distribution download may be blocked in sandboxes;
# use a system gradle by default (override with `make test GRADLE=./gradlew`).
GRADLE ?= gradle

test:
	$(GRADLE) test

build:
	$(GRADLE) compileKotlin

clean:
	$(GRADLE) clean

# --- Release: tag kotlin/vX.Y.Z ---------------------------------------------
# Maven Central publication (Sonatype Central Portal) is pending for this
# target; publishing a version currently means pushing the kotlin/vX.Y.Z git
# tag. Run headless under the boru key vault, which injects the GitHub token
# so nothing lands on disk or argv:
#   boru vault exec --for=github=<alias> -- make publish
# boru `--dry-run` injects a filler token we detect to rehearse (no tag/push).
VERSION := $(shell cat VERSION)
TAG := kotlin/v$(VERSION)
BORU_DRY_RUN_FILLER := BORU-DRY-RUN-FILLER-NOT-A-REAL-SECRET
publish:
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
	  echo "tag $(TAG) already exists — bump VERSION first"; exit 1; fi
	@set -e; \
	token="$${GITHUB_TOKEN:-$$GH_TOKEN}"; \
	if [ "$$token" = "$(BORU_DRY_RUN_FILLER)" ]; then \
	  echo "[dry-run] boru filler token detected: would tag $(TAG); nothing pushed."; \
	  exit 0; \
	fi; \
	git tag -a "$(TAG)" -m "kotlin v$(VERSION)"; \
	url=$$(git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#'); \
	if [ -n "$$token" ] && printf '%s' "$$url" | grep -q '^https://github.com/'; then \
	  hdr="AUTHORIZATION: basic $$(printf 'x-access-token:%s' "$$token" | base64 | tr -d '\n')"; \
	  git -c http.extraheader="$$hdr" push "$$url" "$(TAG)"; \
	else \
	  git push origin "$(TAG)"; \
	fi; \
	echo "Tagged $(TAG)."
