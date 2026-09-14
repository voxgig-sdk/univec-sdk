# Univec SDK secrets feature

from __future__ import annotations
import json
import urllib.error
import urllib.request

from univec_sdk.utility.voxgig_struct import voxgig_struct as vs
from univec_sdk.feature.base_feature import UnivecBaseFeature
from univec_sdk.feature.secrets.voxgig_sekreto import Sekreto, envkey
# The plugin DEFINITIONS the model selected for this feature, emitted by
# config generically from the catalogue's active `plugin.def` entries.
# Upstream sekreto's contract since the registry was retired: a kind not
# passed in `plugins` is unknown to that Sekreto, so the model's choice of
# plugin groups IS the SDK's provider vocabulary.
from univec_sdk.config import FEATURE_PLUGINS


class _LiveProvider:
    """A custom provider given as a MAP of callables, adapted to the
    object shape sekreto's live-provider check reads.

    ts accepts `{ lookup() {...}, describe() {...} }` verbatim because a
    JS object literal survives the options clone with its functions
    intact. python's vs.clone flattens a class INSTANCE to a plain dict of
    its instance attributes (methods lost), so the dict-of-callables IS
    the shape that reaches this feature - the exact parallel of the ts
    contract - and this adapter turns it back into a provider."""

    def __init__(self, spec):
        self._spec = spec

    def lookup(self, name):
        return self._spec["lookup"](name)

    def describe(self):
        describe = self._spec.get("describe")
        return describe() if callable(describe) else "custom"


def _provider_entry(p):
    if isinstance(p, dict) and callable(p.get("lookup")):
        return _LiveProvider(p)
    return p


# Secret access via a vendored voxgig_sekreto provider chain, and the
# access-token exchange some APIs require on top of it. A port of the ts
# reference (tm/ts/src/feature/secrets/SecretsFeature.ts) - semantics
# must match, seam for seam.
#
# The SDK's `apikey` option keeps exactly its old meaning: an explicit
# credential given in code. This feature makes it ONE SOURCE among several
# rather than the only one: when active, the apikey is resolved through a
# sekreto chain in which the explicit option (when set) is the FIRST
# provider - a `memory` store named 'options' - so an explicit value
# always wins, by sekreto's own first-hit rule rather than by special-case
# logic. When the option is unset, the remaining providers (env, dotenv, a
# vault) are asked in order, and moving a credential from code to a vault
# becomes a configuration change.
#
# SOME APIs will not take a long-lived credential at all. What the chain
# resolves is then a REFRESH token, which buys a short-lived ACCESS token
# from a token endpoint; the access token is what every request carries,
# and it expires. `exchange.active` turns that round trip on: the resolved
# secret is POSTed to `exchange.path` (relative to options.base), the
# access token from the response is written to options.apikey, and a
# response in `exchange.statuses` (401) buys another and retries once.
#
# That last part is why this feature wraps the transport. Expiry is only
# ever discovered from a RESPONSE, and the transport is the one place a
# response can be seen before the operation pipeline turns it into a
# result. With the exchange off, nothing is wrapped.
#
# WHERE ts RESOLVES ASYNCHRONOUSLY, PYTHON IS SYNC THROUGHOUT: sekreto's
# python port does blocking IO, so the PreSpec hook resolves in place and
# ts's shared in-flight promise degenerates to the resolved/cache flags
# below. The observable rules are unchanged: one resolution serves every
# op while caching is on, `cache: False` asks the chain again each time,
# and a provider ERROR raises and fails the op - sekreto's miss-vs-error
# rule: never fall through to an unauthenticated request because a store
# was broken. prepare_auth itself is untouched: PreSpec runs before
# make_spec on every entity op, so the resolved value lands in the live
# options where prepare_auth already looks.
class UnivecSecretsFeature(UnivecBaseFeature):
    def __init__(self):
        super().__init__()
        self.version = "0.1.0"
        self.name = "secrets"
        self.active = True

        self._client = None
        self._sekreto = None
        self._secretname = "apikey"
        self._resolved = False
        self._lastset = None
        self._cache = True

        # Exchange state. `_exchange` is the resolved config (None when
        # off) and `_refresh` the credential the chain gave us.
        self._exchange = None
        self._refresh = None

    # Sync by contract: build the chain only, never look anything up here.
    def init(self, ctx, fopts):
        client = ctx.client
        options = ctx.options if isinstance(ctx.options, dict) else {}
        fopts = fopts if isinstance(fopts, dict) else {}

        self._client = client

        name = fopts.get("name")
        self._secretname = name if isinstance(name, str) and "" != name \
            else "apikey"

        # Exchange config, normalised once. None when off, so every later
        # decision is a None check rather than a repeated active test.
        xopts = fopts.get("exchange")
        if isinstance(xopts, dict) and xopts.get("active") is True:
            self._exchange = {
                "path": xopts.get("path")
                if isinstance(xopts.get("path"), str) else "auth/token",
                "method": xopts.get("method")
                if isinstance(xopts.get("method"), str) else "POST",
                "request": xopts.get("request")
                if isinstance(xopts.get("request"), str) else "refresh_token",
                "response": xopts.get("response")
                if isinstance(xopts.get("response"), str) else "access_token",
                "statuses": xopts.get("statuses")
                if isinstance(xopts.get("statuses"), list) else [401],
                "retries": xopts.get("retries")
                if isinstance(xopts.get("retries"), (int, float))
                and not isinstance(xopts.get("retries"), bool) else 1,
            }
        else:
            self._exchange = None

        providers = []

        # The explicit credential, when set, is the first store in the
        # chain.
        #
        # WHICH option that is depends on the exchange. Without one, the
        # secret being resolved IS the credential the transport sends, so
        # `apikey` is it. With one, the secret is a REFRESH token and
        # `apikey` means the opposite thing - an access token the caller
        # already holds - so the explicit seat belongs to
        # `exchange.refresh`, and apikey is left alone to serve as the
        # starting access token (see _resolve_once below).
        if self._exchange is None:
            explicit = options.get("apikey")
        else:
            explicit = xopts.get("refresh") if isinstance(xopts, dict) else None

        if isinstance(explicit, str) and "" != explicit:
            providers.append({
                "kind": "memory",
                "name": "options",
                "values": {envkey(self._secretname): explicit},
            })

        for p in (fopts.get("providers") or []):
            providers.append(_provider_entry(p))

        self._cache = fopts.get("cache") is not False

        self._sekreto = Sekreto({
            "providers": providers,
            "plugins": FEATURE_PLUGINS.get(self.name) or [],
            "cache": self._cache,
        })

        # Seam for UnivecSDK.prepare() (no feature hooks on that
        # path) and for callers wanting the live Sekreto.
        client._secrets = self

        # Wrap the transport ONLY when there is an exchange to defend. A
        # spent access token is discovered from the response, and this is
        # the one place a response can be seen and the request tried
        # again.
        if self._exchange is not None:
            utility = ctx.utility
            inner = utility.fetcher

            def secrets_fetcher(fctx, fullurl, fetchdef):
                return self._with_refresh(fctx, fullurl, fetchdef, inner)

            utility.fetcher = secrets_fetcher

    # The LIVE Sekreto instance, for callers who want arbitrary secrets or
    # redaction:
    #
    #   sdk._secrets.sekreto().get('db.password')
    #   sdk._secrets.sekreto().redact(logline)
    #
    # Never a clone: sekreto holds provider state (caches, vault leases)
    # that has to stay live to be worth anything.
    def sekreto(self):
        return self._sekreto

    def PreSpec(self, _ctx):
        return self.resolve()

    # Resolve the apikey before the first request. A successful HIT is
    # reused while caching is on; with `cache: False` the chain is asked
    # again on every call - holding the first answer forever would make
    # the documented option a lie. A provider ERROR raises (fails the op)
    # and leaves nothing cached, so a transient vault outage does not
    # poison the client after the vault recovers.
    #
    # A MISS is not marked resolved either, however caching is set. That
    # rule is sekreto's, not this feature's: `A miss is never cached: the
    # next read asks again`, in sekreto's own source. Marking a settled
    # miss here would override that from the layer above, and a secret
    # provisioned after startup - a mounted file, a policy granted a minute
    # late - would never be picked up for the life of the client. `cache`
    # is about caching a HIT; it was never a promise to keep saying no.
    def resolve(self):
        if self._resolved and self._cache:
            return
        self._resolved = self._resolve_once()

    # Resolve once, reporting whether a credential came out of it. That
    # bool is the whole of what resolve() needs to tell a cacheable HIT
    # from a miss it must not retain.
    def _resolve_once(self):
        if self._sekreto is None:
            return False

        # Miss-vs-error: `try_` answers None for "no store has it" and
        # RAISES for "a store could not answer" - only the miss falls
        # through.
        found = self._sekreto.try_(self._secretname)

        if self._exchange is None:
            if found is not None:
                # The same live-mutation seam the test feature uses for
                # the transport: prepare_auth reads
                # ctx.client.options_map() (a clone of options), so the
                # resolved value lands where the sync auth path already
                # looks.
                self._client.options["apikey"] = found
                self._lastset = found
            elif self._lastset:
                # An UNCACHED miss after an earlier hit is a revocation:
                # the chain now says no provider has the secret, so the
                # value this feature wrote must not keep going out on the
                # wire. Only the feature's own write is retracted - an
                # explicit apikey seats FIRST in the chain as a memory
                # provider, so the chain HITS while one is set and this
                # branch is never reached.
                if self._client.options.get("apikey") == self._lastset:
                    self._client.options["apikey"] = ""
                self._lastset = None
            return found is not None

        # Exchanging: what the chain resolved is the REFRESH token, kept
        # for every later purchase. A miss is not fatal here - an explicit
        # `apikey` may already hold a usable access token, and the API is
        # what gets to say whether it does.
        self._refresh = None if found is None else str(found)

        apikey = self._client.options.get("apikey")
        if isinstance(apikey, str) and "" != apikey:
            # A starting access token was supplied. Spend it: if it is
            # stale the API answers 401 and the transport wrapper buys
            # another, which is the same path expiry takes anyway.
            return True

        # `auth: None` is the documented way to send NO credential, and a
        # purchase is a credential-bearing call: the refresh token goes to
        # the token endpoint in the request body. _with_refresh honours
        # suppression for the RETRY, but it runs after this - by then the
        # refresh token has already left the process, and no later check
        # can call it back. The suppression has to be honoured here, before
        # the first purchase, or it only ever half-held.
        if self._client.options_map().get("auth") is None:
            return False

        self._client.options["apikey"] = self._buy()

        return True

    # Buy an access token with the refresh token. (ts shares one in-flight
    # purchase between concurrent async callers; python resolves
    # synchronously, so the sharing that remains observable is the
    # spend-what-is-current rule in _with_refresh.)
    def _buy(self):
        # TEST MODE BUYS NOTHING.
        #
        # The test feature replaces the transport so that no request
        # leaves the process; an exchange here would be the one HTTP call
        # it could not stop, and it would need a live token endpoint for a
        # suite whose whole point is not needing one. So test mode gets a
        # deterministic, obviously-fake token instead - the same answer
        # make_options gives a required server variable, for the same
        # reason.
        if "live" != self._client.mode:
            return "test-" + self._exchange["response"]

        return self._buy_once()

    def _buy_once(self):
        x = self._exchange

        if self._refresh is None or "" == self._refresh:
            raise Exception(
                "secrets: no refresh token: the provider chain has no '"
                + self._secretname
                + "', and feature.secrets.exchange.refresh is unset")

        options = self._client.options_map()

        # The token endpoint is RELATIVE to the base, which already
        # carries whatever account or tenant segment the server URL
        # declares.
        base = str(options.get("base") or "").rstrip("/")
        url = base + "/" + str(x["path"]).lstrip("/")

        fetch = vs.getpath(options, "system.fetch")

        if not callable(fetch):
            # No custom transport supplied - the ordinary case.
            # make_options leaves system.fetch unset, so the exchange
            # gets its own raw HTTP path (stdlib urllib, mirroring the ts
            # reference whose system.fetch is initialized from the
            # platform fetcher). Local and minimal on purpose: see the
            # NOT-the-SDK-transport note below.
            fetch = _raw_exchange_fetch

        # Deliberately NOT the SDK transport. The transport is what this
        # feature wraps, and sending the token request back through it
        # would recurse on the first 401 - and would route the exchange
        # through the test mock, which knows nothing about it.
        res, err = fetch(url, {
            "method": x["method"],
            "headers": {"content-type": "application/json"},
            "body": json.dumps({x["request"]: self._refresh}),
        })

        if err is not None:
            raise Exception(
                "secrets: token exchange failed: " + str(err) + " from " + url)

        status = 0 if not isinstance(res, dict) else (res.get("status") or 0)

        if 200 > status or 300 <= status:
            raise Exception(
                "secrets: token exchange failed: " + str(status)
                + " from " + url)

        jf = res.get("json")
        if callable(jf):
            body = jf()
        else:
            body = res.get("body")
            if isinstance(body, str):
                try:
                    body = json.loads(body)
                except Exception:
                    body = None

        token = None if not isinstance(body, dict) else body.get(x["response"])

        if not isinstance(token, str) or "" == token:
            raise Exception(
                "secrets: token exchange returned no '" + x["response"]
                + "' field from " + url)

        return token

    # Buy a token and try the request again when the API says the current
    # one is spent. Wraps the transport; installed only when exchanging.
    #
    # The retry rewrites the authorization header IN PLACE on the
    # fetchdef, because the header was built by the synchronous
    # prepare_auth before this request left, and it carries the token that
    # just failed. Rebuilt the way prepare_auth builds it, from the same
    # options.auth.prefix, so the two cannot drift.
    def _with_refresh(self, ctx, url, fetchdef, inner):
        x = self._exchange
        max_retries = 0 if x is None else x["retries"]

        # `auth: None` is the documented way to send NO credential, and
        # prepare_auth honours it by removing the header. A refusal of a
        # deliberately unauthenticated request is not an expired token and
        # cannot be fixed by buying one - retrying would transmit exactly
        # the credential the caller suppressed.
        if self._client.options_map().get("auth") is None:
            return inner(ctx, url, fetchdef)

        attempt = 0

        while True:
            # The credential THIS attempt goes out with, captured before
            # it leaves: it is what tells a stale refusal apart from a
            # fresh one.
            used = self._client.options.get("apikey")

            res, err = inner(ctx, url, fetchdef)

            if attempt >= max_retries or not self._spent(res, err):
                return res, err

            # Another request may have bought a token while this one was
            # in flight. Spend what is current before buying: a second
            # exchange for a token that is already current is wasted, and
            # on a provider that invalidates the previous credential on
            # issuance, one that breaks the first request's own retry.
            current = self._client.options.get("apikey")

            if isinstance(current, str) and "" != current and current != used:
                token = current
            else:
                try:
                    token = self._buy()
                except Exception:
                    # The purchase failed: answer with the API's own
                    # refusal rather than this one. The caller asked for
                    # data, and the 401 is the more useful of the two -
                    # the exchange error is a symptom.
                    return res, err

                self._client.options["apikey"] = token

            self._reauth(fetchdef, token)

            attempt += 1

    def _spent(self, res, err):
        if err is not None or not isinstance(res, dict):
            return False
        return res.get("status") in self._exchange["statuses"]

    def _reauth(self, fetchdef, token):
        if not isinstance(fetchdef, dict) or \
                not isinstance(fetchdef.get("headers"), dict):
            return

        auth = self._client.options_map().get("auth")

        # Suppressed auth means NO header, the same answer prepare_auth
        # gives. Reached defensively - _with_refresh does not retry at all
        # when auth is None - but this is the function that writes the
        # credential, so it is where the rule has to hold.
        if auth is None:
            fetchdef["headers"].pop("authorization", None)
            return

        prefix = auth.get("prefix") if isinstance(auth, dict) else None
        fetchdef["headers"]["authorization"] = \
            prefix + " " + token if prefix else token


def _raw_exchange_fetch(fullurl, fetchdef):
    """Token-exchange transport of last resort: stdlib urllib, answering
    the same (res, err) shape the system.fetch seam promises. Exists so an
    exchange works with ordinary SDK options - requiring a custom
    transport for the COMMON case would reject every live token purchase
    before a request was made."""
    try:
        body = fetchdef.get("body")
        data = body.encode("utf-8") if isinstance(body, str) and body else None
        req = urllib.request.Request(
            fullurl,
            data=data,
            method=str(fetchdef.get("method") or "POST"),
        )
        for k, v in (fetchdef.get("headers") or {}).items():
            if isinstance(v, str):
                req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=30) as res:
            raw = res.read()
            status = res.status

        def _json():
            try:
                return json.loads(raw.decode("utf-8"))
            except Exception:
                return None

        return {"status": status, "json": _json}, None
    except urllib.error.HTTPError as e:
        # A non-2xx answer IS a response: hand back its status so the
        # caller reports "token exchange failed: <status>" rather than a
        # transport error.
        return {"status": e.code, "json": lambda: None}, None
    except Exception as e:
        return None, e
