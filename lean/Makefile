.PHONY: test build lint clean corpus smoke ffi exe

# Build every lean_lib and lean_exe declared in lakefile.toml. `ffi` first:
# the secrets feature's plugin groups bind libcurl through two C stubs that
# Lake's TOML manifest cannot compile itself (see the SECRETS FFI note at the
# bottom); with no plugin group selected it is a no-op.
build: ffi
	lake build

# Run the generated test executables. `omnismoke` proves the VENDORED
# @voxgig/omni engine itself is alive (and can still FAIL), `runner` drives
# the SDK pipeline and the generated entity/direct tests, `feature` the
# feature suite, `primary` the shared primary-utility corpus, and
# `structcorpus` the vendored voxgig/struct corpus. Any one exiting non-zero
# fails the target, `pipeline` the request-shaping utilities driven directly.
# The smoke test runs FIRST: a corpus suite that went green
# on a broken engine would prove nothing. When the model ships the secrets
# feature, `secrets` (test/feature/secrets/TSecrets.lean) runs last.
test: ffi
	lake exe omnismoke
	lake exe runner
	lake exe feature
	lake exe pipeline
	lake exe primary
	lake exe structcorpus
	lake exe secrets

corpus:
	lake exe structcorpus

# One executable by name, under the same environment `test` runs in
# (`make exe EXE=secrets`): the secrets ffi, when present, sets LEAN_CC for
# every lake invocation below, and a bare `lake exe` would not see it.
exe: ffi
	lake exe $(EXE)

smoke:
	lake exe omnismoke

# "Lint": a clean build means the code type-checks.
lint:
	lake build

clean:
	rm -rf .lake $(SECRETS_FFI)

# SECRETS FFI. The vendored sekreto plugins reach the network through
# `@[extern "sekreto_curl_fetch"]` (SekretoPlugins.Httpjson) and the wall
# clock through `@[extern "sekreto_epoch_seconds"]` (SekretoPlugins.Clock),
# both bound in src/feature/secrets/ffi/*.c. Lake's TOML manifest has no
# extern_lib, and its bundled clang compiles under -nostdinc so it cannot see
# <curl/curl.h>; the stubs are therefore compiled HERE with the system C
# compiler against the toolchain's own <lean/lean.h> - exactly upstream
# sekreto's recipe - and lakefile.toml's `moreLinkArgs` reads ONE response
# file, src/feature/secrets/ffi/link.rsp, that the rules below write with
# the objects, the machine's library directories and -lcurl -lssl -lcrypto:
# a lakefile is static, and where libcurl lives is not. The link itself runs
# through the SYSTEM compiler (LEAN_CC): the bundled clang links against the
# toolchain's own, older glibc, and the system libcurl needs the system one.
# Main_lean fills the marker below only when a plugin group is active, so an
# SDK without secrets, or with the four built-in kinds alone, defines nothing
# here and links neither the stubs nor -lcurl.
export LEAN_CC ?= cc
CC ?= cc
LEANPREFIX := $(shell lean --print-prefix)
SECRETS_FFI_DIR := src/feature/secrets/ffi
SECRETS_FFI_OBJS := $(SECRETS_FFI_DIR)/sekreto_curl.o $(SECRETS_FFI_DIR)/sekreto_clock.o
SECRETS_FFI_RSP := $(SECRETS_FFI_DIR)/link.rsp
SECRETS_FFI := $(SECRETS_FFI_OBJS) $(SECRETS_FFI_RSP)
# Where the compiler finds libcurl (multiarch on Debian, lib64 on Fedora),
# asked rather than guessed; a bare name back means no development package.
SECRETS_LIBCURL := $(shell $(CC) -print-file-name=libcurl.so)

$(SECRETS_FFI_DIR)/%.o: $(SECRETS_FFI_DIR)/%.c
	$(CC) -c -o $@ $< -I$(LEANPREFIX)/include -fPIC -std=c11 -Wall -Wextra

$(SECRETS_FFI_RSP): $(SECRETS_FFI_OBJS) lakefile.toml
	@test "$(SECRETS_LIBCURL)" != "libcurl.so" || { echo "secrets: libcurl development files not found (libcurl4-openssl-dev / libcurl-devel)" >&2; exit 1; }
	printf '%s\n' $(SECRETS_FFI_OBJS) -L$(LEANPREFIX)/lib -L$(dir $(SECRETS_LIBCURL)) -lcurl -lssl -lcrypto > $@

ffi: $(SECRETS_FFI)
