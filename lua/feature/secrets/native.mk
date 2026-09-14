# Univec SDK: the sekreto transport helper build.
#
# GENERATED because a secrets plugin group is active
# (secrets.vault): the plugin provider kinds run this
# helper for every socket and child process, since Lua 5.4 has none. An
# SDK without an active plugin group has no such file, and its Makefile's
# optional include of it is a no-op - nothing is compiled and OpenSSL is
# not linked.
#
# The source carries the vendoring tool's three-line provenance header in
# lua comment syntax, which the compiler cannot read: it is fed the file
# from line four. Compiler line numbers are therefore three lower than the
# file's.
NATIVE := feature/secrets/native/sekreto-net

CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
LDLIBS ?= -lssl -lcrypto

feature/secrets/native/sekreto-net: feature/secrets/native/sekretonet.c
	@command -v $(CC) >/dev/null 2>&1 || { echo "secrets: a C compiler ($(CC)) is needed to build the sekreto transport helper that this SDK's plugin provider kinds run - install one, or use only the built-in provider kinds" >&2; exit 1; }
	tail -n +4 $< | $(CC) $(CFLAGS) -x c - -o $@ $(LDLIBS)
