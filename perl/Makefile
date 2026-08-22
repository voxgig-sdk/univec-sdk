.PHONY: test build clean publish

PERL ?= perl

# Run the WHOLE suite (entity, direct, utility, pipeline, feature and
# netsim tests) with prove (TAP). -Ilib puts the generated SDK module on
# @INC; helper .pm files in t/ are loaded by path.
test:
	prove -Ilib t/

# No build step - pure-Perl module.
build:
	@echo "No build step for Perl"

clean:
	@rm -rf .release
	@find . -name '*.bak' -delete

# --- Release: git tag (CPAN registry pending) ------------------------------
# Build a CPAN dist in a throwaway .release/ dir to validate the package,
# then tag perl/vX.Y.Z (version from $VERSION in lib/*SDK.pm). The CPAN
# registry entry for this port is declared but pending, so publish is
# tag-only: no upload happens. Run headless under the boru key vault, which
# injects the GitHub token (never on disk or argv):
#   boru vault exec --for=github=<alias> -- make publish
# boru `--dry-run` injects a filler token we detect to rehearse (build only,
# no tag). set -e + tag-last: a failed build never leaves a tag behind.
#
# NOTE: `perl Makefile.PL` (ExtUtils::MakeMaker) GENERATES a file named
# `Makefile`, which would OVERWRITE this hand-written Makefile - so the
# dist build always happens inside .release/, never in place.
VERSION := $(shell sed -nE "s/.*VERSION *= *'([^']+)'.*/\1/p" lib/*SDK.pm | head -1)
TAG := perl/v$(VERSION)
BORU_DRY_RUN_FILLER := BORU-DRY-RUN-FILLER-NOT-A-REAL-SECRET
publish: test
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
	  echo "tag $(TAG) already exists — bump VERSION in lib/*SDK.pm first"; exit 1; fi
	@set -e; \
	token="$${GITHUB_TOKEN:-$$GH_TOKEN}"; \
	rm -rf .release && mkdir -p .release; \
	cp -r lib core utility feature entity t Makefile.PL config.pm features.pm .release/ 2>/dev/null || true; \
	{ [ -f README.md ] && cp README.md .release/ || true; }; \
	(cd .release && $(PERL) Makefile.PL >/dev/null && echo "dist metadata OK"); \
	rm -rf .release; \
	if [ "$$token" = "$(BORU_DRY_RUN_FILLER)" ]; then \
	  echo "[dry-run] boru filler token detected: would tag $(TAG); nothing pushed."; \
	  exit 0; \
	fi; \
	git tag -a "$(TAG)" -m "perl v$(VERSION)"; \
	url=$$(git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#'); \
	if [ -n "$$token" ] && printf '%s' "$$url" | grep -q '^https://github.com/'; then \
	  hdr="AUTHORIZATION: basic $$(printf 'x-access-token:%s' "$$token" | base64 | tr -d '\n')"; \
	  git -c http.extraheader="$$hdr" push "$$url" "$(TAG)"; \
	else \
	  git push origin "$(TAG)"; \
	fi; \
	echo "Published tag $(TAG) (CPAN registry pending — tag-only)."
