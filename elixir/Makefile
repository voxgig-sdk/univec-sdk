.PHONY: test build clean struct

# Full ExUnit suite (includes the vendored struct corpus test).
test:
	mix test

# Only the vendored struct corpus.
struct:
	mix test test/struct_corpus_test.exs

build:
	mix compile

clean:
	rm -rf _build
