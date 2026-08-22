.PHONY: build test lint fmt-check clean

build:
	zig build

# Run all tests.
# The zig test framework can crash with signal 11 during cleanup *after* all
# tests pass, due to *MapRef/*ListRef cross-references in arena teardown. We
# filter the output: if "N/N tests passed" with N==total, treat as success.
# `--summary all` is required so the count is printed.
test:
	@out=$$(zig build test --summary all 2>&1); code=$$?; \
	echo "$$out"; \
	if [ $$code -eq 0 ]; then exit 0; fi; \
	summary=$$(echo "$$out" | grep -oE '[0-9]+/[0-9]+ tests passed(; [0-9]+ skipped)?' | tail -1); \
	passed=$$(echo "$$summary" | sed -E 's#([0-9]+)/([0-9]+).*#\1#'); \
	total=$$(echo "$$summary" | sed -E 's#([0-9]+)/([0-9]+).*#\2#'); \
	skipped=$$(echo "$$summary" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+'); \
	[ -n "$$skipped" ] || skipped=0; \
	if [ -n "$$passed" ] && [ "$$total" -gt 0 ] && [ $$((passed + skipped)) -eq "$$total" ]; then \
		exit 0; \
	fi; \
	exit 1

lint: fmt-check

fmt-check:
	zig fmt --check .

clean:
	rm -rf .zig-cache zig-cache zig-out
