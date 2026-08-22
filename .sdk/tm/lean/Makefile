.PHONY: test build lint clean corpus

# Build every lean_lib and lean_exe declared in lakefile.toml.
build:
	lake build

# Run the four generated test executables. `runner` drives the SDK pipeline
# and the generated entity/direct tests, `feature` the feature suite,
# `primary` the shared primary-utility corpus, and `structcorpus` the
# vendored voxgig/struct corpus. Any one exiting non-zero fails the target.
test:
	lake exe runner
	lake exe feature
	lake exe primary
	lake exe structcorpus

corpus:
	lake exe structcorpus

# "Lint": a clean build means the code type-checks.
lint:
	lake build

clean:
	rm -rf .lake
