.PHONY: test build lint clean corpus smoke

# Build every lean_lib and lean_exe declared in lakefile.toml.
build:
	lake build

# Run the five generated test executables. `omnismoke` proves the VENDORED
# @voxgig/omni engine itself is alive (and can still FAIL), `runner` drives
# the SDK pipeline and the generated entity/direct tests, `feature` the
# feature suite, `primary` the shared primary-utility corpus, and
# `structcorpus` the vendored voxgig/struct corpus. Any one exiting non-zero
# fails the target. The smoke test runs FIRST: a corpus suite that went green
# on a broken engine would prove nothing.
test:
	lake exe omnismoke
	lake exe runner
	lake exe feature
	lake exe primary
	lake exe structcorpus

corpus:
	lake exe structcorpus

smoke:
	lake exe omnismoke

# "Lint": a clean build means the code type-checks.
lint:
	lake build

clean:
	rm -rf .lake
