# Univec SDK (C++) — build & test.
#
# Header-only runtime (core/, utility/, feature/, entity/); each test/*.cpp is
# an independent executable. `make test` compiles and runs them all, failing
# if any test binary exits non-zero. Mirrors the struct/cpp and tm/rust build.
#
# The ONE exception to header-only is a gated feature's vendored payload
# (below): a multi-translation-unit library, compiled into an archive the
# test executables link - and only while that feature is wired in.

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O0 -g -Wall -Wextra -Wno-unused-parameter -pthread

# ---- gated feature payloads (model/feature/<name>.aon plugin groups) --------
#
# A gated feature's vendored payload sits two levels under feature/
# (feature/<name>/<lib>/*.cpp), as .cpp/.hpp pairs that cannot ride inside
# a test's single translation unit. What of it is built is decided by a
# GENERATED make fragment, feature/<name>/kinds.mk, that the feature's
# Config component emits beside its generated wiring file only when the
# model activates the feature for this target. The fragment appends the
# payload sources to FEATURE_SRCS, the feature's suite to FEATURE_TEST_SRCS,
# and - only when a plugin group is active - the plugin layer and the
# external libraries it brings to FEATURE_LIBS. Nothing here names a
# feature: a tree whose model never activated one has no fragment, carries
# its payload as inert source, and links libstdc++ alone, and a project's
# `target add` trims it outright. `ldd` on any test binary shows which case
# this tree is. Every quoted include inside a payload is either
# same-directory or an explicit sibling path written at vendoring time
# (ts/vendor/routes.json), so NO -I is needed and a payload's types.hpp or
# value.hpp can never shadow core/types.hpp.
FEATURE_SRCS :=
FEATURE_TEST_SRCS :=
FEATURE_LIBS :=
-include $(wildcard feature/*/kinds.mk)
FEATURE_OBJS := $(FEATURE_SRCS:.cpp=.o)
FEATURE_ARCHIVE := $(if $(strip $(FEATURE_SRCS)),libsdkfeature.a,)

TEST_SRCS := $(wildcard test/*.cpp) $(FEATURE_TEST_SRCS)
TEST_BINS := $(TEST_SRCS:.cpp=.out)

# REBUILD WHEN A HEADER CHANGES. The runtime is header-only, so a test binary
# depends on far more than its own .cpp — but the pattern rule below names
# only that .cpp, so make happily reused a stale .out after every change to
# core/, feature/, entity/ or utility/. A real fix to the mock transport read
# as "still failing" through several rebuilds because the binary under test
# predated it. Listing the headers is cheap and makes `make test` mean what it
# says.
# test/ is listed too: the corpus suites are driven by test/*.hpp (the omni
# resolver and the retained runner support) and by the vendored omni headers
# under test/vendor/omni/, none of which the pattern rule below names either.
# feature/*/ and feature/*/*/ cover a gated feature's vendored headers.
SDK_HDRS := $(wildcard core/*.hpp entity/*.hpp feature/*.hpp \
                       feature/*/*.hpp feature/*/*/*.hpp \
                       utility/*.hpp utility/*/*.hpp *.hpp \
                       test/*.hpp test/vendor/omni/*.hpp)

.PHONY: test build clean

build: $(TEST_BINS)

test: build
	@fail=0; \
	for b in $(TEST_BINS); do \
	  echo "===== $$b ====="; \
	  if ! ./$$b; then fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi; \
	echo "ALL TESTS PASSED"

# The payload archive. `ar r` REPLACES a member by basename on an archive it
# finds and KEEPS every other one, so a stale member from a removed source
# would outlive it; one cold `ar rcs` keeps exactly the current members
# (upstream sekreto's own Makefile deletes first for the same reason).
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

libsdkfeature.a: $(FEATURE_OBJS)
	@rm -f $@
	ar rcs $@ $(FEATURE_OBJS)

# $(FEATURE_ARCHIVE) and $(FEATURE_LIBS) are empty unless a gated feature is
# wired in, so this rule is byte-for-byte the header-only build otherwise.
test/%.out: test/%.cpp $(SDK_HDRS) $(FEATURE_ARCHIVE)
	$(CXX) $(CXXFLAGS) $< -o $@ $(FEATURE_ARCHIVE) $(FEATURE_LIBS)

clean:
	rm -f test/*.out test/*/*/*.out $(FEATURE_OBJS) libsdkfeature.a

# --- Release: tag cpp/vX.Y.Z (header-only; no registry) --------------------
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.1)
TAG := cpp/v$(VERSION)
publish:
	@echo "Header-only C++ SDK; publishing is the git tag $(TAG)."
