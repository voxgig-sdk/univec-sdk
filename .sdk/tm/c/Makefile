# Univec SDK (C) — build + test. Compiles the runtime (core/, utility/,
# utility/struct/, feature/, entity/) into a static archive, then builds and
# runs every tests/*.c binary. `make test` exits non-zero if any test fails.

CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -O0 -g
INC := -I core -I utility/struct
LDLIBS := -lm

# feature/*/*.c: a feature may carry a vendored library payload in its own
# subdirectory (the station feature vendors voxgig_station there - C has no
# package registry, so tier-C libraries ride the feature source; see
# utility/struct/ for the same precedent at the utility level). Empty when
# no feature ships one.
LIB_SRCS := $(wildcard core/*.c utility/*.c utility/struct/*.c feature/*.c feature/*/*.c entity/*.c)
LIB_OBJS := $(LIB_SRCS:.c=.o)

TEST_SRCS := $(wildcard tests/*.c)
TEST_BINS := $(TEST_SRCS:.c=.out)

.PHONY: all build test clean publish

all: build

build: libsdk.a

%.o: %.c
	$(CC) $(CFLAGS) $(INC) -c $< -o $@

libsdk.a: $(LIB_OBJS)
	ar rcs $@ $(LIB_OBJS)

tests/%.out: tests/%.c libsdk.a
	$(CC) $(CFLAGS) $(INC) $< libsdk.a -o $@ $(LDLIBS)

# Build and run every test; aggregate pass/fail.
test: libsdk.a
	@fail=0; total=0; \
	for src in $(TEST_SRCS); do \
	  bin=$${src%.c}.out; \
	  $(CC) $(CFLAGS) $(INC) $$src libsdk.a -o $$bin $(LDLIBS) || { echo "BUILD FAIL: $$src"; fail=1; continue; }; \
	  total=$$((total+1)); \
	  if ./$$bin; then :; else echo "TEST FAIL: $$bin"; fail=1; fi; \
	done; \
	echo "-----------------------------------------"; \
	if [ $$fail -eq 0 ]; then echo "ALL $$total TEST BINARIES PASSED"; else echo "SOME TESTS FAILED"; fi; \
	exit $$fail

clean:
	rm -f $(LIB_OBJS) libsdk.a $(TEST_BINS) tests/*.out corpus-scoreboard.json

# C has no central registry — publishing IS the git tag.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.1)
publish:
	@echo "C target: tag-only publish (c/v$(VERSION)); no registry."
