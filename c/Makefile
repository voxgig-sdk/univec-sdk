# Univec SDK (C) — build + test. Compiles the runtime (core/, utility/,
# utility/struct/, feature/, entity/) into a static archive, then builds and
# runs every tests/*.c binary. `make test` exits non-zero if any test fails.

CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -O0 -g
# -I feature: a feature's own header (feature/<name>.h), which a suite under
# tests/feature/<name>/ includes by bare name the way every test includes
# sdk.h. Then EVERY payload directory two levels under feature/: a feature
# that carries a vendored library keeps it in feature/<name>/<lib>/, and
# every quoted include inside such a port is a bare basename resolved
# through these. Derived from the tree rather than listed, so the Makefile
# names no feature; harmless when the feature trim has removed the
# directories (the wildcard is then empty), and a payload's value.h /
# point.h / types.h shadow nothing: the SDK's own value.h (utility/struct)
# is reached by its neighbours through the including file's directory,
# which a quoted include searches before any -I.
PAYLOAD_DIRS := $(sort $(dir $(wildcard feature/*/*/*.h)))
# Payload headers are quoted includes; they must not shadow system headers
# such as <regex.h> with the plugin library's own regex.h.
INC := -I core -I utility/struct -I feature $(addprefix -iquote ,$(PAYLOAD_DIRS))
# The vendored omni test runner (tests/vendor/omni) is TEST-ONLY: it is
# reachable from tests/ alone, never from LIB_SRCS, so it cannot enter the
# shipped libsdk.a. That is why it lives under tests/ and not utility/.
OMNI_INC := -I tests -I tests/vendor/omni
# The test harness headers (ctest.h, feature_harness.h) by bare name, for a
# suite that lives BELOW tests/ (a gated feature's tests/feature/<name>/
# suite) and so cannot reach them through its own directory as tests/*.c do.
TEST_INC := -I tests
LDLIBS := -lm

# ---- gated feature payloads (model/feature/<name>.aon plugin groups) --------
#
# A gated feature's vendored payload sits two levels under feature/
# (feature/<name>/<lib>/*.c) - out of reach of the feature/*/*.c glob below,
# and deliberately so. What of it is built is decided by a GENERATED make
# fragment, feature/<name>/kinds.mk, that Config_c emits beside the
# feature's generated kinds.c only when the model activates the feature for
# this target. The fragment appends the payload sources to FEATURE_SRCS, the
# feature's suite to FEATURE_TEST_SRCS, and - only when a plugin group is
# active - the plugin layer and the external libraries it brings to LDLIBS.
# Nothing here names a feature: a tree whose model never activated one
# carries its payload as inert source (as rust carries a module no parent
# declares), links libc alone, and a project's `target add` trims it
# outright. `ldd` on any test binary shows which case this tree is.
FEATURE_SRCS :=
FEATURE_TEST_SRCS :=
-include $(wildcard feature/*/kinds.mk)

# feature/*/*.c: a feature may carry a vendored library payload in its own
# subdirectory (the station feature vendors voxgig_station there - C has no
# package registry, so tier-C libraries ride the feature source; see
# utility/struct/ for the same precedent at the utility level). Empty when
# no feature ships one. A gated feature's own feature/<name>.c is in this
# glob too and always compiles (its headers are on INC above); without its
# kinds.mk nothing references it, so the archive member is never pulled
# into a link.
LIB_SRCS := $(wildcard core/*.c utility/*.c utility/struct/*.c feature/*.c feature/*/*.c entity/*.c) \
  $(FEATURE_SRCS)
LIB_OBJS := $(LIB_SRCS:.c=.o)

# Single-level on purpose: the vendored omni sources under
# tests/vendor/omni have no main() and must not become test binaries. A
# gated feature's suite under tests/feature/<name>/ is added by its
# generated kinds.mk, so it is only ever built when the feature it links
# against is wired in.
TEST_SRCS := $(wildcard tests/*.c) $(FEATURE_TEST_SRCS)
TEST_BINS := $(TEST_SRCS:.c=.out)

OMNI_SRCS := $(wildcard tests/vendor/omni/*.c)
OMNI_OBJS := $(OMNI_SRCS:.c=.o)

.PHONY: all build test clean publish

all: build

build: libsdk.a

# Keep this before the generic rule for GNU make 3.81 on macOS.
# omni's util.c includes <regex.h>. CFLAGS is `?=`, so an operator override
# can drop the -D_GNU_SOURCE that exposes it; -D_POSIX_C_SOURCE is the
# minimum omni itself compiles under (its own test/run.c sets exactly this).
# _DARWIN_C_SOURCE is needed BESIDE it, not instead of it: on Darwin,
# defining _POSIX_C_SOURCE alone LOWERS __DARWIN_C_LEVEL and hides regex_t,
# so the same flag that exposes the header on glibc hides it on macOS. Each
# platform ignores the other's macro.
tests/vendor/omni/%.o: tests/vendor/omni/%.c
	$(CC) $(CFLAGS) -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE -c $< -o $@


%.o: %.c
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

# `ar r` REPLACES a member by basename on an archive it finds, and this
# archive carries duplicate basenames by construction: core/utility.o
# beside utility/struct/utility.o, and a vendored payload's point.o,
# config.o and value.o beside core's and utility/struct's. One cold
# `ar rcs` keeps every member; an incremental one would silently drop
# whichever came first, so the archive is deleted before it is written.
libsdk.a: $(LIB_OBJS)
	@rm -f $@
	ar rcs $@ $(LIB_OBJS)


libomni.a: $(OMNI_OBJS)
	@rm -f $@
	ar rcs $@ $(OMNI_OBJS)

# Only the corpus drivers and the smoke test reach for omni, and the generic
# rule must stay free of it: omni's util.c needs POSIX <regex.h>, which
# Windows does not have at all. Linking it into EVERY test binary broke the
# auth-null probe the generator's own suite builds on windows and macos,
# neither of which runs a corpus.
OMNI_TESTS := tests/struct_corpus_test.out tests/primary_corpus_test.out \
  tests/omni_smoke_test.out

$(OMNI_TESTS): tests/%.out: tests/%.c libsdk.a libomni.a
	$(CC) $(CFLAGS) $(INC) $(TEST_INC) $(OMNI_INC) $< libsdk.a libomni.a -o $@ $(LDLIBS)

tests/%.out: tests/%.c libsdk.a
	$(CC) $(CFLAGS) $(INC) $(TEST_INC) $< libsdk.a -o $@ $(LDLIBS)

# Build and run every test; aggregate pass/fail.
test: libsdk.a libomni.a
	@fail=0; total=0; \
	for src in $(TEST_SRCS); do \
	  bin=$${src%.c}.out; \
	  case " $(OMNI_TESTS) " in *" $$bin "*) omni="libomni.a"; oinc="$(OMNI_INC)";; *) omni=""; oinc="";; esac; \
	  $(CC) $(CFLAGS) $(INC) $(TEST_INC) $$oinc $$src libsdk.a $$omni -o $$bin $(LDLIBS) || { echo "BUILD FAIL: $$src"; fail=1; continue; }; \
	  total=$$((total+1)); \
	  if ./$$bin; then :; else echo "TEST FAIL: $$bin"; fail=1; fi; \
	done; \
	echo "-----------------------------------------"; \
	if [ $$fail -eq 0 ]; then echo "ALL $$total TEST BINARIES PASSED"; else echo "SOME TESTS FAILED"; fi; \
	exit $$fail

clean:
	rm -f $(LIB_OBJS) libsdk.a $(OMNI_OBJS) libomni.a $(TEST_BINS) tests/*.out \
	  tests/feature/*/*.out corpus-scoreboard.json

# C has no central registry — publishing IS the git tag.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.1)
publish:
	@echo "C target: tag-only publish (c/v$(VERSION)); no registry."
