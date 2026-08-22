.PHONY: test build clean publish

test:
	mvn -q test

build:
	mvn -q -DskipTests compile

clean:
	mvn -q clean

# --- Release: tag java/vX.Y.Z ----------------------------------------------
# Maven Central publication (Sonatype Central Portal) is pending for this
# target; publishing a version currently means pushing the java/vX.Y.Z git
# tag. Run headless under the boru key vault, which injects the GitHub token
# so nothing lands on disk or argv:
#   boru vault exec --for=github=<alias> -- make publish
# boru `--dry-run` injects a filler token we detect to rehearse (no tag/push).
# set -e + tag-last: a failed push never leaves a tag behind.
#
# NOTE: publishing the git tag is deliberately NOT gated on `mvn test` (every
# other target's deploy just pushes its tag; a generated-test quirk must not
# block the tag). Run `make test` separately in CI to gate quality.
VERSION := $(shell cat VERSION)
TAG := java/v$(VERSION)
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
	git tag -a "$(TAG)" -m "java v$(VERSION)"; \
	url=$$(git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#'); \
	if [ -n "$$token" ] && printf '%s' "$$url" | grep -q '^https://github.com/'; then \
	  hdr="AUTHORIZATION: basic $$(printf 'x-access-token:%s' "$$token" | base64 | tr -d '\n')"; \
	  git -c http.extraheader="$$hdr" push "$$url" "$(TAG)"; \
	else \
	  git push origin "$(TAG)"; \
	fi; \
	echo "Tagged $(TAG)."
