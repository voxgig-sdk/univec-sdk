.PHONY: test build clean struct primary omni

# Full ExUnit suite (includes both vendored-omni corpus suites).
test:
	mix test

# Only the struct corpus, through the vendored omni engine.
struct:
	mix test test/struct_corpus_test.exs

# Only the primary-utility corpus, through the vendored omni engine.
primary:
	mix test test/primary_utility_test.exs

# The vendored omni engine's own smoke tests (it must be able to FAIL).
omni:
	mix test test/omni_smoke_test.exs

build:
	mix compile

clean:
	rm -rf _build
