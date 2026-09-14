# Generated beside kinds.c: what the `secrets` feature needs from the
# build, read by the Makefile through `-include $(wildcard feature/*/kinds.mk)`.
# Without this file none of the feature's vendored payload is compiled or
# linked. Do not hand-edit - change the model and regenerate.

# The vendored cores every chain needs (sekreto and the voxgig/plugin host it
# is built on), and the feature's gated suite.
FEATURE_SRCS += $(wildcard feature/secrets/sekreto/*.c feature/secrets/plugin/*.c)
FEATURE_TEST_SRCS += $(wildcard tests/feature/secrets/*.c)

# A plugin group is active: the selected kinds and the five shared helpers
# they call (the socket HTTP client and its OpenSSL binding, the encoders,
# the clock and the child-process launcher), with the two external
# libraries they bring - OpenSSL for the vault kinds' TLS, libcurl for the
# token-exchange transport of last resort in kinds.c.
FEATURE_SRCS += $(wildcard feature/secrets/plugins/*.c)
LDLIBS += -lssl -lcrypto -lcurl
