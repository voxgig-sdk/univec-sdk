.PHONY: test build lint clean corpus

# Compile the whole SDK (runtime + test runners) via scala-cli.
build:
	scala-cli compile .

# Run the runtime test suite (plain scala-cli main), the generated per-entity
# entity/direct tests (SdkEntityTestMain), then the shared struct corpus
# (vendored voxgig struct against ../.sdk/test/test.json). Any one reporting a
# failure exits non-zero.
test:
	scala-cli run . --main-class SdkTestMain
	scala-cli run . --main-class SdkEntityTestMain
	scala-cli run . --main-class Runner -- ../.sdk/test/test.json

corpus:
	scala-cli run . --main-class Runner -- ../.sdk/test/test.json

# "Lint": a clean compile means the code type-checks.
lint:
	scala-cli compile .

clean:
	rm -rf .scala-build .bsp out
