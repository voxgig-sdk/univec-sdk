# Generated beside kinds.cpp: what the `secrets` feature needs from the
# build, read by the Makefile through `-include $(wildcard feature/*/kinds.mk)`.
# Without this file none of the feature's vendored payload is compiled or
# linked. Do not hand-edit - change the model and regenerate.

# The wiring translation unit, the vendored cores every chain needs (sekreto
# and the voxgig/plugin host it is built on), and the feature's gated suite.
FEATURE_SRCS += feature/secrets/kinds.cpp \
  $(wildcard feature/secrets/sekreto/*.cpp feature/secrets/plugin/*.cpp)
FEATURE_TEST_SRCS += $(wildcard test/feature/secrets/*.cpp)

# A plugin group is active: the selected kinds and the four shared helpers
# they call (the socket HTTPS client, its OpenSSL binding, the digests and
# the child-process launcher), with the one external library they bring -
# OpenSSL, for the vault kinds' TLS and for the token-exchange transport of
# last resort in kinds.cpp, which rides on the same vendored client.
FEATURE_SRCS += $(wildcard feature/secrets/plugins/*.cpp)
FEATURE_LIBS += -lssl -lcrypto
