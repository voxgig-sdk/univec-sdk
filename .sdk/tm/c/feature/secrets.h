// The secrets feature's public surface (feature/secrets.c). A header of its
// own, unlike the other c features, because callers need more than the
// constructor sdk.h's list gives every bundled feature: the LIVE sekreto
// instance (arbitrary secrets, redaction), the resolved credential, and
// the init-failure text - the c spelling of ts's `sdk.secrets().sekreto()`
// and go's `Sekreto()` / `Credential()` accessors. Named for the feature so
// the feature trim drops it with feature/secrets.c and feature/secrets/.
//
// The feature is GATED (model/feature/secrets.aon `needs: { sekreto: true }`
// and model/target/c.aon `provides`), so its constructor is NOT in sdk.h's
// bundled list: core/config.c emits the prototype for a project that
// selected it, and this header repeats it for a caller that includes only
// this file.

#ifndef PROJECTNAME_FEATURE_SECRETS_H
#define PROJECTNAME_FEATURE_SECRETS_H

#include "sdk.h"

// The vendored sekreto's chain type, opaque here; include "sekreto.h" for
// the operations (sek_get, sek_try, sek_getfrom, sek_redact_text, ...).
struct sek_sekreto;

Feature* feature_secrets_new(void);

// The client's secrets feature, or NULL when the client has none. Walks the
// client's feature list by name, so it finds the instance the generated
// config installed from the options - never a second one.
Feature* sdk_feature_secrets(UnivecSDK* sdk);

// The LIVE chain, or NULL when the feature is inactive or its construction
// failed (see feature_secrets_initerr). Never a clone: sekreto holds
// provider state that has to stay live to be worth anything.
struct sek_sekreto* feature_secrets_sekreto(Feature* f);

// The resolved credential ("" when none) - the value the transport wrapper
// injects into each request. Read here rather than from the options map,
// which this feature never mutates.
const char* feature_secrets_credential(Feature* f);

// sekreto's own message when the chain could not be built (an unknown kind,
// a malformed providers entry, a provider refusing its configuration), or
// NULL. While it is set the transport wrapper refuses to send.
const char* feature_secrets_initerr(Feature* f);

#endif // PROJECTNAME_FEATURE_SECRETS_H
