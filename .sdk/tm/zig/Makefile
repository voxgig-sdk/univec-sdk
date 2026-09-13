.PHONY: build test lint fmt-check clean

build:
	zig build

# Run all tests.
# The zig test framework can crash with signal 11 during cleanup *after* all
# tests pass, due to *MapRef/*ListRef cross-references in arena teardown. We
# filter the output: if "N/N tests passed" with N==total, treat as success.
# `--summary all` is required so the count is printed.
#
# THE SUMMARY IS PARSED IN TWO SPELLINGS. Older toolchains wrote the test
# tally as "217/223 tests passed; 6 skipped"; 0.16 writes the annotations as
# a parenthesised list instead - "217/223 tests passed (6 skipped)", and
# "(6 skipped, 1 crashed)" when something did go wrong. Reading only the
# semicolon form off 0.16 finds no skip count at all, so "passed + skipped"
# falls short of "total" and the tolerance refuses a run that was in fact
# clean - failing precisely when the teardown crash it exists for happens.
# Both spellings are accepted below, and any "failed"/"crashed"/"timed out"
# in that same annotation is a real failure, never a teardown crash.
#
# A TEST THAT DID NOT COMPILE IS NOT IN THE TALLY. The tolerance above is for a
# crash AFTER the tests ran, and it must never cover a build that failed: a
# compile error means those test binaries never ran, so they never reach
# "total", and "60/66 passed; 6 skipped" reads as a clean 66/66 while five of
# thirteen build steps are red. That is exactly how a `.undef` tag that does
# not exist in JsonValue shipped in 4.2.2 and stayed green in every sweep
# afterwards. So: if any build step failed, this target fails, whatever the
# test counts say.
test:
	@out=$$(zig build test --summary all 2>&1); code=$$?; \
	echo "$$out"; \
	if [ $$code -eq 0 ]; then exit 0; fi; \
	steps=$$(echo "$$out" | grep -oE '[0-9]+/[0-9]+ steps succeeded' | tail -1); \
	sdone=$$(echo "$$steps" | sed -E 's#([0-9]+)/([0-9]+).*#\1#'); \
	stotal=$$(echo "$$steps" | sed -E 's#([0-9]+)/([0-9]+).*#\2#'); \
	if [ -n "$$steps" ] && [ "$$sdone" != "$$stotal" ]; then \
		echo "zig: $$steps — a build step failed, so the test tally is incomplete"; \
		exit 1; \
	fi; \
	if echo "$$out" | grep -q 'error: the following command failed with .* compilation errors'; then \
		echo "zig: compilation errors — not a teardown crash"; \
		exit 1; \
	fi; \
	summary=$$(echo "$$out" | grep -oE '[0-9]+/[0-9]+ tests passed( \([^)]*\))?(; [0-9]+ skipped)?' | tail -1); \
	passed=$$(echo "$$summary" | sed -E 's#([0-9]+)/([0-9]+).*#\1#'); \
	total=$$(echo "$$summary" | sed -E 's#([0-9]+)/([0-9]+).*#\2#'); \
	skipped=$$(echo "$$summary" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+'); \
	[ -n "$$skipped" ] || skipped=0; \
	if echo "$$summary" | grep -qE '[0-9]+ (failed|crashed|timed out)'; then \
		echo "zig: $$summary — tests failed, so this is not a teardown crash"; \
		exit 1; \
	fi; \
	if [ -n "$$passed" ] && [ "$$total" -gt 0 ] && [ $$((passed + skipped)) -eq "$$total" ]; then \
		exit 0; \
	fi; \
	exit 1

lint: fmt-check

fmt-check:
	zig fmt --check .

clean:
	rm -rf .zig-cache zig-cache zig-out
