# Univec SDK: the secrets feature build.
#
# GENERATED because the model activates `secrets` for this target
# (plugin groups: vault).
# An SDK whose model does not has no such file, and its Makefile's optional
# include of it is a no-op: nothing of the feature is compiled. Do not
# hand-edit - change the model's plugin groups and regenerate.
#
# MODULE ORDER IS THE DEPENDENCY ORDER: the voxgig/plugin host, the sekreto
# core, the shared helpers the selected kinds open, the kinds, the feature.

FEATURE_INC = -I +unix -I feature -I feature/secrets/plugin \
  -I feature/secrets/sekreto -I feature/secrets/plugins
FEATURE_LIB = unix.cma

SECRETS_PLUGIN = feature/secrets/plugin/value.ml \
  feature/secrets/plugin/types.ml \
  feature/secrets/plugin/ref.ml \
  feature/secrets/plugin/version.ml \
  feature/secrets/plugin/capability.ml \
  feature/secrets/plugin/resolve.ml \
  feature/secrets/plugin/env.ml \
  feature/secrets/plugin/config.ml \
  feature/secrets/plugin/graph.ml \
  feature/secrets/plugin/order.ml \
  feature/secrets/plugin/export.ml \
  feature/secrets/plugin/depend.ml \
  feature/secrets/plugin/point.ml \
  feature/secrets/plugin/defs.ml \
  feature/secrets/plugin/catalog.ml \
  feature/secrets/plugin/host.ml

SECRETS_CORE = feature/secrets/sekreto/json.ml \
  feature/secrets/sekreto/secret.ml \
  feature/secrets/sekreto/provider.ml \
  feature/secrets/sekreto/sekreto.ml

SECRETS_HELPERS = feature/secrets/plugins/crypto.ml \
  feature/secrets/plugins/sigv4.ml \
  feature/secrets/plugins/tls.ml \
  feature/secrets/plugins/http.ml \
  feature/secrets/plugins/httpjson.ml \
  feature/secrets/plugins/runcmd.ml

SECRETS_KINDS = feature/secrets/plugins/boru.ml \
  feature/secrets/plugins/hashicorp.ml

FEATURE_SRC = $(SECRETS_PLUGIN) $(SECRETS_CORE) $(SECRETS_HELPERS) $(SECRETS_KINDS) \
  feature/secrets_feature.ml

FEATURE_TESTS = test/feature/secrets/t_secrets.ml

# THE ONE EXTERNAL DEPENDENCY, behind the plugin groups that need a
# transport (vault): plugins/tls.ml's externals live in
# plugins/tls_stubs.c against OpenSSL, so the stub is compiled here and the
# bytecode executables are linked `-custom` with libssl and libcrypto.
# The stub is fed from line four (past the provenance header, see above).
OCAMLLIB = $(shell $(OCAMLC) -where)
FEATURE_OBJ = feature/secrets/plugins/tls_stubs.o
FEATURE_LINK = -custom -cclib -lssl -cclib -lcrypto

feature/secrets/plugins/tls_stubs.o: feature/secrets/plugins/tls_stubs.c
	@command -v $(CC) >/dev/null 2>&1 || { echo "secrets: a C compiler ($(CC)) is needed to build the OpenSSL binding that this SDK's secrets plugin kinds (vault) run - install one, or use only the built-in provider kinds" >&2; exit 1; }
	tail -n +4 $< | $(CC) -std=c11 -O2 -Wall -Wextra -I$(OCAMLLIB) -x c - -c -o $@
