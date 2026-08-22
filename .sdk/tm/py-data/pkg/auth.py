# Univec Data — credential discovery.
#
# `data()` must work in a fresh Colab cell with no arguments. Analysts do not
# want to construct a client; they want a DataFrame. So the token and base
# URL are looked up through a short, predictable chain and the failure
# message TEACHES rather than merely reports.
#
# Kept generic (the SDK's env-var prefix is passed in) because this file is
# copied verbatim per SDK — only `Univec` is substituted at generation
# time, so nothing here may hardcode a per-API name.

from __future__ import annotations

import os
from typing import Any


NOT_FOUND = object()


def from_colab(key: str) -> Any:
    """Read a Colab secret, or NOT_FOUND.

    Guarded three ways because every one of them bites in practice:
    the import fails outside Colab; `userdata` raises SecretNotFoundError for
    a key that was never set; and it raises NotebookAccessError when the
    secret exists but the notebook has not been granted access to it (the
    toggle in Colab's key panel). None of those are errors HERE — they just
    mean "try the next source".
    """
    try:
        from google.colab import userdata  # type: ignore
    except Exception:
        return NOT_FOUND
    try:
        val = userdata.get(key)
    except Exception:
        return NOT_FOUND
    return val if val else NOT_FOUND


def from_env(key: str) -> Any:
    val = os.environ.get(key)
    return val if val else NOT_FOUND


def resolve(
    prefix: str,
    token: str | None = None,
    base_url: str | None = None,
    *,
    token_key: str | None = None,
    base_key: str | None = None,
) -> tuple:
    """(token, base_url, source) from args, then Colab secrets, then env.

    `prefix` is the SDK's upper-snake name, e.g. ACME -> ACME_APIKEY /
    ACME_BASE. Returns the raw values; validation is the caller's job so it
    can decide whether a missing base_url is fatal (multi-tenant APIs) or
    fine (the model's default applies).
    """
    tkey = token_key or f"{prefix}_APIKEY"
    bkey = base_key or f"{prefix}_BASE"

    source = "argument"
    tok: Any = token if token else NOT_FOUND

    if tok is NOT_FOUND:
        tok = from_colab(tkey)
        source = "colab"
    if tok is NOT_FOUND:
        tok = from_env(tkey)
        source = "env"

    base: Any = base_url if base_url else NOT_FOUND
    if base is NOT_FOUND:
        base = from_colab(bkey)
    if base is NOT_FOUND:
        base = from_env(bkey)

    return (
        None if tok is NOT_FOUND else tok,
        None if base is NOT_FOUND else base,
        None if tok is NOT_FOUND else source,
    )


def missing_token_message(prefix: str, token_key: str | None = None) -> str:
    """The error an analyst sees when no credential was found.

    Shows the exact lines to run for THIS SDK in both environments. A generic
    "credentials not found" costs the reader a trip to the README; this costs
    them a copy-paste.
    """
    tkey = token_key or f"{prefix}_APIKEY"
    return (
        f"No API credential found for Univec.\n"
        f"\n"
        f"In Google Colab — open the key panel (left sidebar), add a secret\n"
        f"named {tkey}, and enable notebook access for it. Or set it in code:\n"
        f"\n"
        f"    from google.colab import userdata\n"
        f"    userdata.set('{tkey}', 'your-api-key')\n"
        f"\n"
        f"Elsewhere (Jupyter, a script, a terminal):\n"
        f"\n"
        f"    import os\n"
        f"    os.environ['{tkey}'] = 'your-api-key'\n"
        f"\n"
        f"Or pass it directly:\n"
        f"\n"
        f"    data(token='your-api-key')\n"
    )


def missing_base_message(prefix: str, base_key: str | None = None) -> str:
    """The error for a multi-tenant API with no base URL.

    Only raised when the model's server URL carries an unresolved
    placeholder, i.e. the API genuinely has no single host and every customer
    has their own instance. Guessing one would produce confusing 404s.
    """
    bkey = base_key or f"{prefix}_BASE"
    return (
        f"Univec is multi-tenant: it has no single API host, so the base\n"
        f"URL for YOUR instance is required.\n"
        f"\n"
        f"    data(base_url='https://your-instance.example.com')\n"
        f"\n"
        f"or set {bkey} as a Colab secret / environment variable.\n"
    )
