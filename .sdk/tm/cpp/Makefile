# Univec SDK (C++) — build & test.
#
# Header-only runtime (core/, utility/, feature/, entity/); each test/*.cpp is
# an independent executable. `make test` compiles and runs them all, failing
# if any test binary exits non-zero. Mirrors the struct/cpp and tm/rust build.

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O0 -g -Wall -Wextra -Wno-unused-parameter -pthread

TEST_SRCS := $(wildcard test/*.cpp)
TEST_BINS := $(TEST_SRCS:.cpp=.out)

# REBUILD WHEN A HEADER CHANGES. The runtime is header-only, so a test binary
# depends on far more than its own .cpp — but the pattern rule below names
# only that .cpp, so make happily reused a stale .out after every change to
# core/, feature/, entity/ or utility/. A real fix to the mock transport read
# as "still failing" through several rebuilds because the binary under test
# predated it. Listing the headers is cheap and makes `make test` mean what it
# says.
SDK_HDRS := $(wildcard core/*.hpp entity/*.hpp feature/*.hpp \
                       utility/*.hpp utility/*/*.hpp *.hpp)

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

test/%.out: test/%.cpp $(SDK_HDRS)
	$(CXX) $(CXXFLAGS) $< -o $@

clean:
	rm -f test/*.out

# --- Release: tag cpp/vX.Y.Z (header-only; no registry) --------------------
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.1)
TAG := cpp/v$(VERSION)
publish:
	@echo "Header-only C++ SDK; publishing is the git tag $(TAG)."
