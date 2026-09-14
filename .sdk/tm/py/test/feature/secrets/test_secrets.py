# Behavioural tests for the secrets feature (vendored voxgig_sekreto).
#
# The contract under test: the `apikey` OPTION keeps its exact old meaning
# and always wins, because the secrets feature places it FIRST in the
# provider chain (a `memory` store named 'options') - explicit-beats-lookup
# falls out of sekreto's first-hit rule rather than from special-case
# logic. With the feature inactive nothing changes at all. With it active
# and the option unset, the chain (env, dotenv, a custom provider, a
# vault) supplies the credential instead.
#
# Every wire assertion here reads the header A MOCKED TRANSPORT RECEIVES,
# not the options map: the options map cannot tell a suppressed credential
# from a missing one, and the auth-null defect this suite pins was
# invisible to it.
#
# The feature instance is CONSTRUCTED HERE when this SDK was generated
# without the secrets class (the active-path proof cannot depend on the
# project having switched the feature on): `extend` carries it into the
# constructor, where feature_init runs it against the model options like
# any generated feature.
#
# This file lives in the test/feature/ container on purpose: `target add`
# trims it, along with the feature source and the vendored library, for a
# project whose model does not select `secrets`.

import json
import os
import http.server
import threading
import unittest

from projectname_sdk import UnivecSDK
from projectname_sdk.features import _has_feature
from projectname_sdk.feature.secrets_feature import UnivecSecretsFeature


ENVPREFIX = "PROJECTENV_TEST_SECRETS_"


def secrets_sdk(sdkopts):
    """An SDK with the secrets feature ACTIVE.

    When this SDK was generated with the feature, the ordinary factory
    path builds it; otherwise the instance rides in via `extend`, which is
    the constructor's documented adopt path - init and the PreSpec hook
    then run exactly as generated code would run them.
    """
    if not _has_feature("secrets"):
        sdkopts = dict(sdkopts)
        sdkopts["extend"] = [UnivecSecretsFeature()]
    return UnivecSDK(sdkopts)


def envchain(extra=None):
    """The feature options most of these tests use: an env provider."""
    secrets = {
        "active": True,
        "providers": [{"kind": "env", "prefix": ENVPREFIX}],
    }
    if extra:
        secrets.update(extra)
    return {"feature": {"secrets": secrets}}


class RecordingTransport:
    """A live-mode system.fetch that records what reaches the wire."""

    def __init__(self):
        self.calls = []

    def __call__(self, url, fetchdef):
        self.calls.append({"url": url, "fetchdef": fetchdef})
        return {"status": 200, "statusText": "OK", "headers": {},
                "json": lambda: {}, "body": "{}"}, None


class TestSecrets(unittest.TestCase):

    def setUp(self):
        os.environ.pop(ENVPREFIX + "APIKEY", None)

    tearDown = setUp

    def _sdk(self, sdkopts):
        transport = RecordingTransport()
        opts = {
            # Concrete base: a live construction must satisfy any server
            # variables a templated base URL declares.
            "base": "http://localhost:8080",
            "system": {"fetch": transport},
        }
        opts.update(sdkopts)
        sdk = secrets_sdk(opts)
        return sdk, transport

    def _send(self, sdk, transport):
        """Resolve through the ENTITY-OP SEAM (the PreSpec feature hook -
        exactly the call every generated entity op emits before
        make_spec), build the request, and put it on the mocked wire."""
        utility = sdk._utility
        ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
        utility.feature_hook(ctx, "PreSpec")

        fetchdef = sdk.prepare({"path": "/"})
        res, err = utility.fetcher(ctx, fetchdef["url"], fetchdef)
        self.assertIsNone(err)
        self.assertEqual(1, len(transport.calls))
        return transport.calls[0]["fetchdef"].get("headers") or {}

    def _lastwire(self, sdk, transport):
        """Drive one operation and read the headers off the LAST call, so a
        test can operate more than once on the same client."""
        utility = sdk._utility
        ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
        utility.feature_hook(ctx, "PreSpec")

        fetchdef = sdk.prepare({"path": "/"})
        res, err = utility.fetcher(ctx, fetchdef["url"], fetchdef)
        self.assertIsNone(err)
        return transport.calls[-1]["fetchdef"].get("headers") or {}

    def assert_credential(self, headers, token):
        # The Authorization header carries the SPEC's credential prefix,
        # which a TEMPLATE cannot know - assert on the CREDENTIAL and let
        # the prefix be whatever this SDK's API declares.
        got = str(headers.get("authorization") or "")
        self.assertTrue(
            got == token or got.endswith(" " + token),
            "expected the authorization header to carry %s, got: %r"
            % (token, got))

    # --- the chain ---

    def test_option_wins_over_chain(self):
        os.environ[ENVPREFIX + "APIKEY"] = "ENVKEY01"
        opts = {"apikey": "OPTKEY01"}
        opts.update(envchain())
        sdk, transport = self._sdk(opts)

        headers = self._send(sdk, transport)
        self.assert_credential(headers, "OPTKEY01")

        # The explicit option is a real store, not a special case: a
        # directed read names it like any other.
        self.assertEqual(
            "OPTKEY01", sdk._secrets.sekreto().getfrom("options", "apikey"))

    def test_env_provider_supplies_the_credential(self):
        os.environ[ENVPREFIX + "APIKEY"] = "ENVKEY01"
        sdk, transport = self._sdk(envchain())

        headers = self._send(sdk, transport)
        self.assert_credential(headers, "ENVKEY01")

    def test_custom_provider_supplies_the_credential(self):
        # A custom provider is a MAP of callables (the exact parallel of
        # ts's verbatim object-with-functions: python's options clone
        # flattens a class instance, so the map shape is the contract).
        asked = []

        def lookup(name):
            asked.append(name)
            return "CUSTKEY01" if "apikey" == name else None

        sdk, transport = self._sdk({
            "feature": {"secrets": {
                "active": True,
                "providers": [{
                    "lookup": lookup,
                    "describe": lambda: "custom:test",
                }],
            }},
        })

        headers = self._send(sdk, transport)
        self.assert_credential(headers, "CUSTKEY01")
        self.assertEqual(["apikey"], asked)

    # --- miss vs error ---

    def test_a_miss_falls_through_to_no_credential(self):
        # No env var, no option: the chain answers None, and the request
        # goes out UNAUTHENTICATED - a miss is an answer, not a failure.
        sdk, transport = self._sdk(envchain())

        headers = self._send(sdk, transport)
        self.assertNotIn("authorization", headers)

    def test_a_provider_error_fails_the_op(self):
        # A broken store is NOT a miss: resolution must raise (failing the
        # op at the PreSpec seam), never fall through to an
        # unauthenticated request because a vault was unreachable.
        def broken_lookup(name):
            raise RuntimeError("vault unreachable")

        sdk, _transport = self._sdk({
            "feature": {"secrets": {
                "active": True,
                "providers": [{
                    "lookup": broken_lookup,
                    "describe": lambda: "broken",
                }],
            }},
        })

        utility = sdk._utility
        ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
        with self.assertRaises(RuntimeError):
            utility.feature_hook(ctx, "PreSpec")

    # --- a miss is not a cacheable answer ---

    # sekreto's own rule, which this feature used to override from the
    # layer above: `A miss is never cached: the next read asks again`.
    #
    # DEFAULT caching in both tests below, which is the whole point.
    # `cache: True` is about holding a HIT; holding the settled miss meant
    # the chain was never asked again for the life of the client, so a
    # secret provisioned after startup (a mounted file, a vault policy
    # granted a minute late) was invisible forever.
    def test_a_cached_miss_is_reasked(self):
        state = {"present": False, "calls": 0}

        def lookup(name):
            state["calls"] += 1
            return "LATEKEY01" if state["present"] else None

        sdk, transport = self._sdk({
            "feature": {"secrets": {
                "active": True,
                "providers": [{"lookup": lookup, "describe": lambda: "late:test"}],
            }},
        })

        headers = self._lastwire(sdk, transport)
        self.assertNotIn("authorization", headers,
                         "the chain has nothing yet, so no credential "
                         "should go out")

        asked = state["calls"]
        self.assertLess(0, asked)

        # The secret is provisioned while the client is live.
        state["present"] = True

        headers = self._lastwire(sdk, transport)
        self.assert_credential(headers, "LATEKEY01")

        self.assertLess(asked, state["calls"],
                        "the MISS was cached: a secret that appears later "
                        "can never be picked up")

    def test_a_cached_hit_is_kept(self):
        # The other half of the same rule: a HIT is still cached by
        # default, so the fix above must not turn every request into a
        # chain walk.
        state = {"calls": 0}

        def lookup(name):
            state["calls"] += 1
            return "STABLEKEY01"

        sdk, transport = self._sdk({
            "feature": {"secrets": {
                "active": True,
                "providers": [{"lookup": lookup, "describe": lambda: "counting:test"}],
            }},
        })

        self._lastwire(sdk, transport)
        self._lastwire(sdk, transport)

        self.assertEqual(1, state["calls"],
                         "a hit must be cached under the default cache: True")

    # --- auth: None suppression ---

    def test_auth_none_still_suppresses_the_credential(self):
        # `auth: None` is the documented way to send NO credential, and it
        # must beat BOTH the explicit option and the chain: the resolved
        # value may land in options.apikey, but prepare_auth honours the
        # suppression before it ever reads the apikey. The struct resync
        # (validate now answers the optspec default for a stored None)
        # makes make_options' capture-and-restore the only thing holding
        # this - so it is pinned at the transport, where a leak would
        # actually happen.
        os.environ[ENVPREFIX + "APIKEY"] = "ENVKEY01"
        opts = {"apikey": "LEAKKEY01", "auth": None}
        opts.update(envchain())
        sdk, transport = self._sdk(opts)

        headers = self._send(sdk, transport)
        self.assertNotIn("authorization", headers)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------
# Review-hardening pins (vendor-tag rollout, PR review): the exchange
# works with ORDINARY options (no custom transport, the stdlib fallback
# carries the purchase), and an uncached miss retracts the credential.

class _TokenEndpoint(http.server.BaseHTTPRequestHandler):
    refresh_seen = None

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            body = {}
        _TokenEndpoint.refresh_seen = body.get("refresh_token")
        out = json.dumps({"access_token": "RAWTOK01"}).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass


class TestSecretsReviewPins(unittest.TestCase):

    def test_exchange_uses_the_raw_fallback_and_marshals_the_body(self):
        # A refresh token full of JSON-hostile characters must arrive at
        # the endpoint as its literal value, through the feature's OWN
        # raw transport - ordinary options carry no system.fetch for it.
        tricky = 're"fresh\\to\nken'
        _TokenEndpoint.refresh_seen = None

        srv = http.server.HTTPServer(("127.0.0.1", 0), _TokenEndpoint)
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        try:
            # NO system.fetch anywhere: with the seam set, the purchase
            # rightly prefers it - the point of this pin is the OTHER
            # case, ordinary options, where the feature's own stdlib
            # fallback must carry the exchange. Only PreSpec runs, so no
            # API call ever leaves; the one HTTP request is the purchase.
            sdk = secrets_sdk({
                "base": "http://127.0.0.1:%d/api" % srv.server_port,
                "feature": {"secrets": {
                    "active": True,
                    "name": "refresh_token",
                    "exchange": {"active": True, "refresh": tricky},
                }},
            })

            utility = sdk._utility
            ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
            utility.feature_hook(ctx, "PreSpec")

            self.assertEqual(tricky, _TokenEndpoint.refresh_seen)
            self.assertEqual("RAWTOK01", sdk.options.get("apikey"))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_auth_none_buys_no_token_at_all(self):
        # `auth: None` SUPPRESSES THE PURCHASE, not just the retry.
        #
        # resolve() runs before _with_refresh's suppression check, so the
        # refresh token used to go to the token endpoint in a request body
        # even here. Stopping the retry does not unsend it - and only the
        # token endpoint can see this, which is why the API-header
        # assertion above is not enough.
        tricky = "REFRESH01"
        _TokenEndpoint.refresh_seen = None

        srv = http.server.HTTPServer(("127.0.0.1", 0), _TokenEndpoint)
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        try:
            sdk = secrets_sdk({
                "base": "http://127.0.0.1:%d/api" % srv.server_port,
                "auth": None,
                "feature": {"secrets": {
                    "active": True,
                    "name": "refresh_token",
                    "exchange": {"active": True, "refresh": tricky},
                }},
            })

            utility = sdk._utility
            ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
            utility.feature_hook(ctx, "PreSpec")

            self.assertIsNone(_TokenEndpoint.refresh_seen,
                              "auth: None suppressed the credential but the "
                              "refresh token was still POSTed to the "
                              "exchange endpoint")
        finally:
            srv.shutdown()
            srv.server_close()

    def test_uncached_miss_retracts_the_credential(self):
        # `cache: False` re-asks the chain per operation; when a provider
        # that answered once reports a MISS (a revoked secret), the value
        # this feature wrote must stop going out on the wire.
        state = {"have": True}

        def lookup(name):
            return "REVOCABLE01" if state["have"] else None

        sdk, transport = self._pair({
            "feature": {"secrets": {
                "active": True,
                "cache": False,
                "providers": [{"lookup": lookup, "describe": lambda: "revocable"}],
            }},
        })

        headers = self._wire(sdk, transport)
        self.assert_credential(headers, "REVOCABLE01")

        state["have"] = False
        headers = self._wire(sdk, transport)
        self.assertEqual("", str(headers.get("authorization") or ""),
                         "after the chain reports a miss, the retracted "
                         "credential must not go out")

    # Local mirrors of TestSecrets' helpers (kept self-contained so this
    # class needs none of its state).
    def _pair(self, sdkopts):
        transport = RecordingTransport()
        opts = {
            "base": "http://localhost:8080",
            "system": {"fetch": transport},
        }
        opts.update(sdkopts)
        return secrets_sdk(opts), transport

    def _wire(self, sdk, transport):
        utility = sdk._utility
        ctx = utility.make_context({"opname": "load"}, sdk.get_root_ctx())
        utility.feature_hook(ctx, "PreSpec")
        fetchdef = sdk.prepare({"path": "/"})
        res, err = utility.fetcher(ctx, fetchdef["url"], fetchdef)
        self.assertIsNone(err)
        return transport.calls[-1]["fetchdef"].get("headers") or {}

    def assert_credential(self, headers, token):
        got = str(headers.get("authorization") or "")
        self.assertTrue(
            got == token or got.endswith(" " + token),
            "expected the authorization header to carry %s, got: %r"
            % (token, got))
