# Behavioural tests for the secrets feature (vendored voxgig_sekreto) - the
# ruby port of tm/ts/test/feature/secrets/Secrets.test.ts.
#
# The contract under test: the `apikey` OPTION keeps its exact old meaning
# and always wins, because the feature places it FIRST in the provider chain
# (a `memory` store named 'options') - explicit-beats-lookup falls out of
# sekreto's first-hit rule rather than from special-case logic. With the
# feature inactive nothing changes at all. With it active and the option
# unset, the chain (env, a custom provider, a vault) supplies the credential
# instead.
#
# This file lives in the test `feature/` container on purpose: `target add`
# trims it, along with the feature source and the vendored library, for a
# project whose model does not select `secrets`.
#
# The credential is asserted ON THE WIRE: a live-mode client with a
# recording system.fetch, driven through real entity operations AND through
# `direct()`. An options-level assertion would pass for a port that never
# consults the value, and the raw paths run NO feature hooks - which is
# exactly why resolution lives at the transport seam.

require "minitest/autorun"
require "json"
require "socket"

require_relative "../../../Univec_sdk"

class SecretsFeatureTest < Minitest::Test
  # EVERYTHING BUT THE TEST CLASS IS NESTED. Ruby has ONE constant namespace
  # and reassigning a constant silently replaces it, so a top-level helper here
  # is a name an API entity could clobber (helpers/naming.ts RB_SDK_CONSTANTS
  # is the guard, and the shortest list is the safest one). Nested constants
  # resolve lexically inside the instance methods below, so nothing else
  # changes.
  ENVPREFIX = "UNIVEC_TEST_SECRETS_"

  # ---------------------------------------------------------------------
  # The recording transport: system.fetch for a LIVE client, scripting one
  # status per API call (the last repeating) and a token endpoint for the
  # exchange tests.

  class Wire
    attr_accessor :apistatus, :tokens, :tokenpath, :respfield

    def initialize
      @calls = []
      @apistatus = [200]
      @tokens = ["ACCESS01", "ACCESS02", "ACCESS03"]
      @tokenpath = "auth/token"
      @respfield = "access_token"
      @issued = 0
      @apicalls = 0
      @lock = Mutex.new
    end

    # The Proc the SDK options take as system.fetch.
    def fetch
      wire = self
      ->(fullurl, fetchdef) { wire.record(fullurl, fetchdef) }
    end

    def record(fullurl, fetchdef)
      @lock.synchronize do
        headers = fetchdef["headers"].is_a?(Hash) ? fetchdef["headers"] : {}
        @calls << {
          "url" => fullurl,
          "auth" => headers["authorization"],
          "has" => headers.key?("authorization"),
          "body" => fetchdef["body"],
        }

        if _istoken(fullurl)
          token = @tokens[[@issued, @tokens.length - 1].min]
          @issued += 1
          payload = { @respfield => token }
          return [{ "status" => 200, "statusText" => "OK", "headers" => {},
                    "json" => -> { payload } }, nil]
        end

        status = @apistatus[[@apicalls, @apistatus.length - 1].min]
        @apicalls += 1
        payload = { "ok" => status < 400 }
        [{ "status" => status, "statusText" => "X", "headers" => {},
           "json" => -> { payload } }, nil]
      end
    end

    def calls
      @lock.synchronize { @calls.dup }
    end

    # The recorded calls that did NOT go to the token endpoint.
    def api
      calls.reject { |c| _istoken(c["url"]) }
    end

    def token
      calls.select { |c| _istoken(c["url"]) }
    end

    def _istoken(url)
      url.to_s.end_with?("/" + @tokenpath)
    end
  end

  # A sekreto provider built in code: the contract is structural (lookup +
  # describe), and rb's VoxgigStruct.clone preserves a bare object by
  # reference, so it reaches the feature as itself.
  class CustomProvider
    def initialize(&lookup)
      @lookup = lookup
    end

    def lookup(name)
      @lookup.call(name)
    end

    def describe
      "custom:test"
    end
  end

  # A one-connection-at-a-time HTTP stand-in, in stdlib sockets alone: the
  # raw-fallback exchange has to be exercised over REAL HTTP (that is the
  # whole point of the lane), and webrick is a bundled gem a consumer's ruby
  # may not carry. Answers the token endpoint with an access token and every
  # other path with an empty JSON body, recording what each request carried.
  class HttpStub
    def initialize
      @lock = Mutex.new
      @refresh = nil
      @auth = nil
    end

    def start
      @server = TCPServer.new("127.0.0.1", 0)
      port = @server.addr[1]
      @thread = Thread.new { serve }
      port
    end

    def stop
      @running = false
      @server.close rescue nil
      @thread&.join
    end

    def refresh
      @lock.synchronize { @refresh }
    end

    def auth
      @lock.synchronize { @auth }
    end

    def serve
      @running = true
      while @running
        socket = begin
          @server.accept
        rescue StandardError
          break
        end
        begin
          handle(socket)
        ensure
          socket.close rescue nil
        end
      end
    end

    def handle(socket)
      request = socket.gets.to_s
      path = request.split(" ")[1].to_s

      headers = {}
      while (line = socket.gets)
        line = line.chomp
        break if line.empty?
        k, v = line.split(":", 2)
        headers[k.to_s.downcase.strip] = v.to_s.strip
      end

      length = headers["content-length"].to_i
      body = 0 < length ? socket.read(length) : ""

      if path.end_with?("/auth/token")
        parsed = begin
          JSON.parse(body)
        rescue StandardError
          {}
        end
        @lock.synchronize { @refresh = parsed["refresh_token"] }
        payload = '{"access_token": "RAWTOK01"}'
      else
        @lock.synchronize { @auth = headers["authorization"] }
        payload = "{}"
      end

      socket.print("HTTP/1.1 200 OK\r\n" \
        "content-type: application/json\r\n" \
        "content-length: #{payload.bytesize}\r\n" \
        "connection: close\r\n\r\n#{payload}")
    end
  end

  # -------------------------------------------------------------------
  # Support.

  # The Authorization header carries the SPEC's credential prefix, which a
  # TEMPLATE cannot know - so assert on the CREDENTIAL and let the prefix be
  # whatever this SDK's API declares.
  def assert_credential(header, token)
    ok = header == token || header.to_s.end_with?(" " + token)
    assert ok, "expected the authorization header to carry #{token}, got: #{header.inspect}"
  end

  def secrets_feature_of(client)
    client.features.find { |f| f.is_a?(UnivecSecretsFeature) }
  end

  # Construct the client and ADOPT the feature via `extend` ONLY when the
  # generated config did not already install it - when this SDK was
  # generated with `secrets` model-active, the ordinary factory path builds
  # the instance, and adding a second via extend would DOUBLE the feature:
  # two transport wraps, two resolutions, and a token purchase the
  # assertions cannot account for. (go's withSecrets and py's _has_feature
  # guard the same way.)
  def with_secrets
    client = yield(false)
    client = yield(true) if secrets_feature_of(client).nil?
    client
  end

  def secrets_opts(extra = {})
    fopts = {
      "active" => true,
      "providers" => [{ "kind" => "env", "prefix" => ENVPREFIX }],
    }
    { "secrets" => fopts.merge(extra) }
  end

  # A LIVE client carrying the secrets feature, wired to the recorder.
  def secrets_client(wire, sdkopts = {})
    opts = {
      "base" => "http://secrets.test/api",
      "system" => { "fetch" => wire.fetch },
    }.merge(sdkopts)

    with_secrets do |extend_it|
      o = opts.dup
      o["extend"] = [UnivecSecretsFeature.new] if extend_it
      UnivecSDK.new(o)
    end
  end

  # The entity accessors this SDK generated (client.Moon, client.Planet,
  # ...). Read off the class rather than from a name convention: this file
  # is a TEMPLATE and no project's entity names are known here.
  def entity_accessors(client)
    client.class.instance_methods(false).select { |m| m.to_s =~ /\A[A-Z]/ }
  end

  # Perform real entity operations until `stop` reports the observable state
  # the test is waiting for. Each op's own outcome is irrelevant (no seeded
  # data, a scripted response); an op the API does not define fails before
  # it reaches the transport, which is why several may need driving.
  def drive_until(client, what)
    entity_accessors(client).each do |accessor|
      ent = begin
        client.public_send(accessor)
      rescue StandardError
        next
      end

      ["list", "load"].each do |opname|
        next unless ent.respond_to?(opname)
        begin
          ent.public_send(opname)
        rescue StandardError
          # The op's own failure is not the assertion.
        end
        return if yield
      end
    end

    flunk "no entity operation #{what} - nothing to assert on"
  end

  # Drive ops until one request reached the recorder.
  def drive_op(client, wire)
    before = wire.api.length
    drive_until(client, "reached the transport") { before < wire.api.length }
  end

  # Drive real entity operations until ONE of them is refused, returning
  # what that op raised (nil if it returned instead). Same search as
  # drive_until and for the same reason: this file is a TEMPLATE and no
  # project's entity names or operations are known here, so `accessor[0].list`
  # is a guess - the fixture's first entity defines `load` and no `list` at
  # all, and the NoMethodError that guess raises satisfies a bare
  # `assert_raises` for entirely the wrong reason while every assertion
  # after it goes unreached.
  #
  # ONE op, not all of them: driving the whole accessor list would consult
  # the chain once per op, which would make 'refused once, not retried'
  # unassertable. The block reports the caller's own observable state
  # saying the chain was actually reached - an op that fails before the
  # transport never consults it at all, so the search moves on rather than
  # asserting on an outcome the feature never took part in.
  def drive_refusal(client)
    entity_accessors(client).each do |accessor|
      ent = begin
        client.public_send(accessor)
      rescue StandardError
        next
      end

      ["list", "load"].each do |opname|
        next unless ent.respond_to?(opname)
        caught = begin
          ent.public_send(opname)
          nil
        rescue StandardError => e
          e
        end
        return caught if yield
      end
    end

    flunk "no entity operation consulted the chain - nothing to assert on"
  end

  def setenv(name, value)
    ENV[ENVPREFIX + name] = value
  end

  def clearenv(name)
    ENV.delete(ENVPREFIX + name)
  end

  # -------------------------------------------------------------------
  # The feature-inactive baseline: bit-identical behaviour.

  def test_inactive_apikey_option_behaves_exactly_as_before
    client = UnivecSDK.test(nil, { "apikey" => "OPTKEY01" })
    fetchdef = client.prepare({ "path" => "/" })
    assert_credential(fetchdef["headers"]["authorization"], "OPTKEY01")

    assert_nil secrets_feature_of(client),
      "no activation and no extend: the feature must not be installed"
  end

  def test_inactive_no_apikey_means_no_authorization_header
    client = UnivecSDK.test(nil, nil)
    fetchdef = client.prepare({ "path" => "/" })
    refute fetchdef["headers"].key?("authorization"),
      "unexpected authorization header: #{fetchdef['headers']['authorization'].inspect}"
  end

  # -------------------------------------------------------------------
  # Active: the provider chain, driven through real entity operations.

  def test_apikey_option_still_wins_over_the_chain
    setenv("APIKEY", "ENVKEY01")
    wire = Wire.new
    client = secrets_client(wire, {
      "apikey" => "OPTKEY01",
      "feature" => secrets_opts,
    })

    drive_op(client, wire)
    assert_credential(wire.api[0]["auth"], "OPTKEY01")

    # The explicit option is a real store, not a special case: a directed
    # read names it like any other.
    feature = secrets_feature_of(client)
    refute_nil feature, "the extend seam did not install the feature"
    assert_equal "OPTKEY01", feature.sekreto.getfrom("options", "apikey")
  ensure
    clearenv("APIKEY")
  end

  def test_an_omitted_apikey_defers_to_the_chain_at_the_transport_seam
    setenv("APIKEY", "ENVKEY02")
    wire = Wire.new
    client = secrets_client(wire, { "feature" => secrets_opts })

    # Before any op, nothing has been resolved.
    assert_equal "", client.options_map["apikey"]

    drive_op(client, wire)

    # Resolution happens AT THE TRANSPORT - the one seam every wire path
    # crosses - so the credential is ON THE WIRE, not merely resolved.
    assert_credential(wire.api[0]["auth"], "ENVKEY02")
    assert_equal "ENVKEY02", secrets_feature_of(client).credential
  ensure
    clearenv("APIKEY")
  end

  def test_custom_provider_objects_are_accepted_verbatim
    asked = []
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |name|
          asked << name
          "CUSTOM01"
        }],
      } },
    })

    drive_op(client, wire)
    assert_credential(wire.api[0]["auth"], "CUSTOM01")
    assert_equal "apikey", asked[0]
  end

  def test_a_miss_everywhere_leaves_the_header_off
    clearenv("APIKEY")
    wire = Wire.new
    client = secrets_client(wire, { "feature" => secrets_opts })

    drive_op(client, wire)
    refute wire.api[0]["has"],
      "a chain MISS must fall through to an unauthenticated request, got #{wire.api[0]['auth'].inspect}"
  end

  def test_a_provider_error_fails_the_op_and_nothing_reaches_the_wire
    asked = false
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          asked = true
          raise VoxgigSekreto::SekretoError, "vault unreachable"
        }],
      } },
    })

    drive_until(client, "consulted the chain") { asked }

    assert_equal 0, wire.api.length,
      "a broken vault must never yield a request: #{wire.api.length} calls went out"
  end

  # The entity pipeline turns the refusal into a raised SDK error carrying
  # the feature's own code - never a silent unauthenticated send.
  def test_a_provider_error_raises_a_sdk_error_on_the_entity_path
    asked = false
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          asked = true
          raise VoxgigSekreto::SekretoError, "vault unreachable"
        }],
      } },
    })

    err = drive_refusal(client) { asked }

    # An op that RETURNED yields nil here, which is the fail-open
    # regression this case exists to catch - it must not read as a pass.
    assert_kind_of UnivecError, err,
      "the entity path did not raise the refusal: #{err.inspect}"
    assert_match(/vault unreachable/, err.to_s)
    assert_equal 0, wire.api.length,
      "a broken vault must never yield a request: #{wire.api.inspect}"
  end

  # MISS vs ERROR, the invariant the whole feature is worth having for,
  # asserted as a PAIR on the same two-provider chain: a store that does
  # not hold the secret falls through to the next one...
  def test_a_miss_falls_through_to_the_next_provider
    setenv("APIKEY", "ENVKEY04")
    asked = false
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [
          CustomProvider.new { |_name| asked = true; nil },
          { "kind" => "env", "prefix" => ENVPREFIX },
        ],
      } },
    })

    drive_op(client, wire)
    assert asked, "the first provider was never consulted"
    assert_credential(wire.api[0]["auth"], "ENVKEY04")
  ensure
    clearenv("APIKEY")
  end

  # ...while a store that COULD NOT ANSWER fails the operation, even though
  # the very next provider in the chain holds the secret. A broken vault
  # never degrades into an unauthenticated - or a differently-authenticated
  # - request.
  def test_an_error_fails_the_op_even_though_a_later_provider_has_the_secret
    setenv("APIKEY", "ENVKEY05")
    wire = Wire.new
    client = secrets_client(wire, {
      "allow" => { "op" => "direct" },
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [
          CustomProvider.new { |_name|
            raise VoxgigSekreto::SekretoError, "vault unreachable"
          },
          { "kind" => "env", "prefix" => ENVPREFIX },
        ],
      } },
    })

    res = client.direct({ "path" => "/probe" })
    refute res["ok"], "an ERROR must not fall through to the next provider"
    assert_equal "secrets_provider", res["err"].code
    assert_equal 0, wire.calls.length
  ensure
    clearenv("APIKEY")
  end

  def test_a_provider_recovers_after_a_transient_failure
    calls = 0
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          calls += 1
          raise VoxgigSekreto::SekretoError, "vault unreachable" if calls == 1
          "RECOVERED01"
        }],
      } },
    })

    # The first op fails closed; a failed resolution is never cached, so the
    # second op asks the chain again and succeeds.
    drive_until(client, "consulted the chain") { calls > 0 }
    assert_equal 0, wire.api.length, "the first op must not reach the wire"

    drive_op(client, wire)
    assert_credential(wire.api[0]["auth"], "RECOVERED01")
  end

  # With `cache: false`, a provider that answered once and then reports a
  # MISS (a revoked secret) must RETRACT the credential: nothing the feature
  # published may keep going out on the wire.
  def test_an_uncached_miss_retracts_the_credential
    have = true
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "cache" => false,
        "providers" => [CustomProvider.new { |_name|
          have ? "REVOCABLE01" : nil
        }],
      } },
    })

    drive_op(client, wire)
    assert_credential(wire.api[0]["auth"], "REVOCABLE01")

    have = false

    drive_op(client, wire)
    last = wire.api[-1]
    refute(last["has"] && !last["auth"].to_s.empty?,
      "after the chain reports a miss the retracted credential must not go out; the wire saw #{last['auth'].inspect}")
  end

  # A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
  # feature used to override from the layer above.
  #
  # DEFAULT caching here, which is the whole point: `cache: true` is about
  # holding a HIT, and keeping the settled resolution after a miss meant the
  # chain was never asked again for the life of the client. A secret
  # provisioned after startup (a mounted file, a vault policy granted a
  # minute late) was invisible forever, and the only workaround was giving
  # up hit caching entirely.
  def test_a_cached_miss_is_reasked
    present = false
    calls = 0
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          calls += 1
          present ? "LATEKEY01" : nil
        }],
      } },
    })

    drive_op(client, wire)
    first = wire.api[0]
    refute(first["has"] && !first["auth"].to_s.empty?,
      "the chain has nothing yet, so no credential should go out")

    asked = calls
    assert_operator asked, :>, 0

    # The secret is provisioned while the client is live.
    present = true

    drive_op(client, wire)
    assert_credential(wire.api[-1]["auth"], "LATEKEY01")

    assert_operator calls, :>, asked,
      "the MISS was cached: a secret that appears later can never be picked up"
  end

  # The other half of the same rule: a HIT is still cached by default, so
  # the fix above must not turn every request into a chain walk.
  def test_a_cached_hit_is_kept
    calls = 0
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          calls += 1
          "STABLEKEY01"
        }],
      } },
    })

    drive_op(client, wire)
    drive_op(client, wire)

    assert_equal 1, calls,
      "a hit must be cached under the default cache: true"
  end

  def test_auth_nil_suppresses_the_credential_chain_or_no_chain
    setenv("APIKEY", "ENVKEY03")
    wire = Wire.new
    client = secrets_client(wire, {
      "auth" => nil,
      "apikey" => "OPTKEY01",
      "feature" => secrets_opts,
    })

    drive_op(client, wire)

    refute wire.api[0]["has"],
      "auth nil must suppress the credential, got #{wire.api[0]['auth'].inspect}"

    # The suppression survives option validation rather than being replaced
    # by the optspec's default auth map.
    opts = client.options_map
    assert opts.key?("auth"), "options.auth must stay a present nil"
    assert_nil opts["auth"]
  ensure
    clearenv("APIKEY")
  end

  # -------------------------------------------------------------------
  # The RAW paths - direct and graphql - run no feature hooks at all, so for
  # them the transport seam is the ONLY place resolution can happen.

  def test_direct_carries_the_chain_credential_and_fails_closed
    setenv("APIKEY", "DIRECTKEY01")
    wire = Wire.new
    client = secrets_client(wire, {
      "allow" => { "op" => "direct" },
      "feature" => secrets_opts,
    })

    res = client.direct({ "path" => "/direct-probe" })
    assert res["ok"], "direct refused: #{res['err']}"
    assert_equal 1, wire.api.length
    assert_credential(wire.api[0]["auth"], "DIRECTKEY01")

    # And fail-closed holds for raw access too: a broken chain refuses the
    # direct call before anything reaches the wire.
    brokenwire = Wire.new
    broken = secrets_client(brokenwire, {
      "allow" => { "op" => "direct" },
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          raise VoxgigSekreto::SekretoError, "vault unreachable"
        }],
      } },
    })

    res = broken.direct({ "path" => "/direct-probe" })
    refute res["ok"], "a broken chain must refuse the raw path fail-closed"
    assert_equal "secrets_provider", res["err"].code
    assert_equal 0, brokenwire.calls.length,
      "a broken vault must never yield a request on the raw path"
  ensure
    clearenv("APIKEY")
  end

  def test_graphql_carries_the_chain_credential_and_fails_closed
    setenv("APIKEY", "GQLKEY01")
    wire = Wire.new
    client = secrets_client(wire, {
      "allow" => { "op" => "graphql" },
      "feature" => secrets_opts,
    })

    client.graphql("{ probe }")
    assert_equal 1, wire.api.length
    assert_credential(wire.api[0]["auth"], "GQLKEY01")

    brokenwire = Wire.new
    broken = secrets_client(brokenwire, {
      "allow" => { "op" => "graphql" },
      "feature" => { "secrets" => {
        "active" => true,
        "providers" => [CustomProvider.new { |_name|
          raise VoxgigSekreto::SekretoError, "vault unreachable"
        }],
      } },
    })

    res = broken.graphql("{ probe }")
    refute res["ok"], "a broken chain must refuse graphql fail-closed"
    assert_equal 0, brokenwire.calls.length
  ensure
    clearenv("APIKEY")
  end

  # -------------------------------------------------------------------
  # The access-token exchange.

  def test_the_refresh_token_buys_an_access_token_and_a_spent_one_is_rebought_once
    setenv("REFRESH_TOKEN", "REFRESH01")
    wire = Wire.new
    # First API call is refused, the retry succeeds.
    wire.apistatus = [401, 200]

    client = secrets_client(wire, {
      "feature" => secrets_opts({
        "name" => "refresh_token",
        "exchange" => { "active" => true },
      }),
    })

    drive_op(client, wire)

    assert_equal 2, wire.token.length,
      "expected the initial purchase plus one rebuy, got #{wire.token.length}"
    assert_includes wire.token[0]["body"].to_s, "REFRESH01"

    api = wire.api
    assert_equal 2, api.length, "expected the request to be retried exactly once"
    assert_credential(api[0]["auth"], "ACCESS01")
    # The retry must carry the NEW token, not the spent one.
    assert_credential(api[1]["auth"], "ACCESS02")
  ensure
    clearenv("REFRESH_TOKEN")
  end

  # `auth: nil` SUPPRESSES THE PURCHASE, not just the retry.
  #
  # resolve runs before _with_refresh's suppression check, so the refresh
  # token used to go to the token endpoint in a request body even here.
  # Stopping the retry does not unsend it - this asserts on the token
  # endpoint, which is the half the API-header assertions cannot see.
  def test_auth_nil_buys_no_token_at_all
    setenv("REFRESH_TOKEN", "REFRESH01")
    wire = Wire.new
    wire.apistatus = [401]

    client = secrets_client(wire, {
      "auth" => nil,
      "feature" => secrets_opts({
        "name" => "refresh_token",
        "exchange" => { "active" => true },
      }),
    })

    drive_op(client, wire)

    assert_equal 0, wire.token.length,
      "auth nil suppressed the credential but the refresh token was still " \
      "POSTed to the exchange endpoint"
    refute wire.api[0]["has"],
      "no credential may be sent when auth is suppressed"
  ensure
    clearenv("REFRESH_TOKEN")
  end

  # A second refusal on a token bought moments ago is a real failure, not a
  # spin: exactly one rebuy, and the refusal is returned as it stands.
  def test_a_second_refusal_is_returned_as_is
    setenv("REFRESH_TOKEN", "REFRESH01")
    wire = Wire.new
    wire.apistatus = [401]

    client = secrets_client(wire, {
      "feature" => secrets_opts({
        "name" => "refresh_token",
        "exchange" => { "active" => true },
      }),
    })

    drive_op(client, wire)

    assert_equal 2, wire.api.length, "one attempt plus one retry, no more"
    assert_equal 2, wire.token.length
  ensure
    clearenv("REFRESH_TOKEN")
  end

  # Test mode buys nothing and needs no token endpoint, so an offline suite
  # never makes the one HTTP call the test mock cannot stop.
  def test_test_mode_buys_nothing_and_needs_no_token_endpoint
    setenv("REFRESH_TOKEN", "REFRESH01")
    wire = Wire.new

    client = with_secrets do |extend_it|
      opts = {
        "system" => { "fetch" => wire.fetch },
        "feature" => secrets_opts({
          "name" => "refresh_token",
          "exchange" => { "active" => true },
        }),
      }
      opts["extend"] = [UnivecSecretsFeature.new] if extend_it
      UnivecSDK.test(nil, opts)
    end

    drive_until(client, "resolved the fake token") do
      !secrets_feature_of(client).credential.to_s.empty?
    end

    assert_equal 0, wire.calls.length, "test mode must not do IO"
    # A deterministic placeholder, so offline suites need no configuration.
    assert_equal "test-access_token", secrets_feature_of(client).credential
  ensure
    clearenv("REFRESH_TOKEN")
  end

  # A failed PURCHASE answers with the API's own refusal, not the exchange
  # error: the caller asked for data, and the 401 is the more useful of the
  # two.
  def test_a_failed_purchase_answers_with_the_apis_own_refusal
    clearenv("REFRESH_TOKEN")
    wire = Wire.new
    wire.apistatus = [401]

    client = secrets_client(wire, {
      "allow" => { "op" => "direct" },
      "apikey" => "STALE01",
      "feature" => secrets_opts({
        "name" => "refresh_token",
        "exchange" => { "active" => true },
      }),
    })

    res = client.direct({ "path" => "/probe" })

    # 401 from the API, surfaced as the raw path's ok:false - not a token
    # exchange error.
    refute res["ok"]
    assert_equal 401, res["status"]
    assert_equal 1, wire.api.length
  end

  # The exchange with NO system.fetch: the raw fallback transport carries
  # the purchase end to end over REAL HTTP, and the body is MARSHALLED - a
  # refresh token full of JSON-hostile characters must arrive as that
  # literal value.
  def test_the_exchange_works_with_ordinary_options_and_marshals_its_body
    tricky = "re\"fresh\\to\nken"

    server = HttpStub.new
    port = server.start

    begin
      client = with_secrets do |extend_it|
        opts = {
          "base" => "http://127.0.0.1:#{port}/api",
          "allow" => { "op" => "direct" },
          "feature" => { "secrets" => {
            "active" => true,
            "name" => "refresh_token",
            "exchange" => { "active" => true, "refresh" => tricky },
          } },
        }
        opts["extend"] = [UnivecSecretsFeature.new] if extend_it
        UnivecSDK.new(opts)
      end

      # No system.fetch anywhere: the API call takes the SDK's default
      # transport and the token purchase takes the feature's raw fallback.
      res = client.direct({ "path" => "/probe" })
      assert res["ok"], "the raw fallback exchange failed: #{res['err']}"
    ensure
      server.stop
    end

    assert_equal tricky, server.refresh,
      "the refresh token must arrive as its literal value (marshalled, not concatenated)"
    assert_credential(server.auth, "RAWTOK01")
  end

  # -------------------------------------------------------------------
  # The refusal is NOT retried. The gate lives at the transport, so a
  # provider ERROR must fail the operation once - never spin the chain, and
  # never let a later attempt through unauthenticated.
  def test_a_provider_error_is_refused_once_and_not_retried
    calls = 0
    wire = Wire.new
    client = secrets_client(wire, {
      "feature" => {
        "secrets" => {
          "active" => true,
          "providers" => [CustomProvider.new { |_name|
            calls += 1
            raise VoxgigSekreto::SekretoError, "vault unreachable"
          }],
        },
      },
    })

    err = drive_refusal(client) { 0 < calls }

    assert_kind_of UnivecError, err,
      "the entity path did not raise the refusal: #{err.inspect}"
    assert_equal 1, calls, "the refusal must not be retried"
    assert_equal 0, wire.calls.length,
      "a refused op must never yield a request: #{wire.calls.inspect}"
  end
end
