// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the swift port of tm/ts/test/feature/secrets/Secrets.test.ts, in the
// shape of kotlin's SecretsTest.kt.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (a memory store, a custom provider, a vault)
// supplies the credential instead.
//
// This file lives in the test `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets` - and Main_swift withholds
// it at generate time for the same model, because it imports Sekreto.
//
// THE CLIENT IS LIVE AND THE TRANSPORT IS THE THING COUNTED. Every wire
// assertion here runs against a real client whose `system.fetch` is the
// recorder - never `testSDK`, whose test feature REPLACES the fetcher with
// its own in-memory mock and would leave a `system.fetch` counter at zero
// for a healthy SDK carrying no secrets feature at all. An assertion that
// cannot fail pins no rule, so each fail-closed case additionally carries a
// CONTROL leg: the same construction with a WORKING provider must reach the
// same recorder exactly once, carrying the credential. Only then does a
// zero from the broken provider mean REFUSED rather than UNWIRED. And the
// refusal is matched on the PROVIDER'S OWN message, so an unrelated failure
// (a missing route, a blocked op) cannot stand in for fail-closed.
//
// The feature is CONSTRUCTED DIRECTLY and adopted through the `extend`
// option ONLY when the generated Config did not already install it, so
// these tests hold in any generated tree - and never double the feature
// (two transport wraps, two purchases) in one that did.
//
// NO ENVIRONMENT VARIABLES. Foundation has no supported way to set one for
// the current process, so the ts/go/js suites' `env` chains become `memory`
// chains and custom Provider objects here. The rule under test - the chain
// answers when the option does not - is identical either way.

import Foundation
import XCTest

@testable import UnivecSdk
import Sekreto
import struct VoxgigPlugin.Definition

// -------------------------------------------------------------------
// The recording transport: system.fetch for a LIVE client, scripting one
// status per API call (the last repeating) and a token endpoint for the
// exchange tests.

final class SecretsWire {
  struct Call {
    let url: String
    let auth: String
    let hasAuth: Bool
    let body: String
  }

  private let lock = NSLock()
  private var recorded: [Call] = []

  var apistatus: [Int] = [200]
  var tokens: [String] = ["ACCESS01", "ACCESS02", "ACCESS03"]
  var tokenpath = "auth/token"
  var respfield = "access_token"

  // A token endpoint that starts refusing after `tokenok` successful
  // purchases (0 refuses the first).
  var tokenok = Int.max

  private var issued = 0
  private var apicalls = 0

  // A `SystemFetch`-typed closure: that is the shape utility/Fetcher.swift
  // casts `system.fetch` to, and a closure stored under any other type
  // would be silently refused as "not a valid function".
  lazy var fetch: SystemFetch = { [unowned self] url, fetchdef in
    self.serve(url, fetchdef)
  }

  private func serve(_ url: String, _ fetchdef: VMap) -> Value {
    lock.lock()
    defer { lock.unlock() }

    // The header value is SNAPSHOT here, not referenced: the retry path
    // rewrites the same headers map in place, so a stored reference would
    // make every earlier record show the newest token.
    var auth = ""
    var hasAuth = false
    if let headers = gp(fetchdef, "headers").asMap {
      for (k, v) in headers.entries where k.lowercased() == "authorization" {
        hasAuth = true
        auth = v.asString ?? stringify(v)
      }
    }
    let body = gp(fetchdef, "body").asString ?? ""
    recorded.append(Call(url: url, auth: auth, hasAuth: hasAuth, body: body))

    if url.hasSuffix("/" + tokenpath) {
      if issued >= tokenok {
        issued += 1
        return SecretsWire.response(500, vm(("error", .string("nope"))))
      }
      let token = tokens[min(issued, tokens.count - 1)]
      issued += 1
      return SecretsWire.response(200, vm((respfield, .string(token))))
    }

    let status = apistatus[min(apicalls, apistatus.count - 1)]
    apicalls += 1
    return SecretsWire.response(status, vm(("ok", .bool(status < 400))))
  }

  static func response(_ status: Int, _ payload: VMap) -> Value {
    let captured: Value = .map(payload)
    return .map(vm(
      ("status", .int(Int64(status))),
      ("statusText", .string(status < 400 ? "OK" : "ERR")),
      ("headers", .map(VMap())),
      ("json", .nat({ () -> Value in captured } as NativeCall0))))
  }

  func calls() -> [Call] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  // The recorded calls that did NOT go to the token endpoint.
  func api() -> [Call] {
    return calls().filter { !$0.url.hasSuffix("/" + tokenpath) }
  }

  func token() -> [Call] {
    return calls().filter { $0.url.hasSuffix("/" + tokenpath) }
  }

  // What went out, for a message that names the leak rather than counting it.
  func wire() -> String {
    return calls().map { $0.url + " auth=" + $0.auth }.joined(separator: ", ")
  }
}

// A sekreto Provider built in code.
final class SecretsProbeProvider: Provider {
  private let onlookup: (String) throws -> String?
  private let label: String

  init(_ label: String = "custom:test", _ onlookup: @escaping (String) throws -> String?) {
    self.label = label
    self.onlookup = onlookup
  }

  func lookup(_ name: String) throws -> String? {
    return try onlookup(name)
  }

  func describe() -> String {
    return label
  }
}

// A provider's own failure - carries only its message, so that message is
// the one thing a refusal can be matched on.
struct SecretsProbeError: Error, CustomStringConvertible {
  let message: String
  init(_ message: String) { self.message = message }
  var description: String { message }
}

final class SecretsFeatureTest: XCTestCase {

  static let BASE = "http://secrets.test/api"

  // -------------------------------------------------------------------
  // Support.

  // The Authorization header carries the SPEC's credential prefix, which a
  // TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
  // `Bearer <token>`, an apiKey scheme the raw token. So assert on the
  // CREDENTIAL and let the prefix be whatever this SDK's API declares.
  private func credentialIs(_ header: String, _ token: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(header == token || header.hasSuffix(" " + token),
      "expected the authorization header to carry \(token), got: \"\(header)\"",
      file: file, line: line)
  }

  private func secretsOf(_ client: UnivecSDK) -> SecretsFeature? {
    return client.features.first { $0 is SecretsFeature } as? SecretsFeature
  }

  private func messageOf(_ err: Error?) -> String {
    guard let e = err else { return "" }
    if let pe = e as? UnivecError { return pe.message }
    return String(describing: e)
  }

  private func errOf(_ res: VMap) -> Error? {
    return res.entries["err"]?.asNative as? Error
  }

  // Build the client, and ADOPT the feature via `extend` ONLY when the
  // generated Config did not already install it: when this SDK was generated
  // with `secrets` model-active, the ordinary factory path builds the
  // instance, and adding a second via extend would DOUBLE the feature - two
  // transport wraps, two resolutions, and a token purchase the assertions
  // cannot account for.
  private func withSecrets(_ build: (Bool) -> UnivecSDK) -> UnivecSDK {
    let client = build(false)
    if nil != secretsOf(client) {
      return client
    }
    return build(true)
  }

  // A LIVE client carrying the secrets feature, wired to the recorder.
  //
  // `allow.op` is named explicitly: a project that narrows the default set
  // would otherwise turn the raw-path cases into a false RED (the control
  // leg refused before it reached the transport).
  private func secretsClient(_ w: SecretsWire, _ extra: [(String, Value)]) -> UnivecSDK {
    return withSecrets { extend in
      let opts = VMap()
      opts.entries["base"] = .string(SecretsFeatureTest.BASE)
      opts.entries["allow"] = .map(vm(
        ("op", .string("create,update,load,list,remove,command,direct,graphql"))))
      opts.entries["system"] = .map(vm(("fetch", .nat(w.fetch))))
      for (k, v) in extra {
        opts.entries[k] = v
      }
      if extend {
        opts.entries["extend"] = .list([.nat(SecretsFeature())])
      }
      return UnivecSDK(opts)
    }
  }

  // The feature options block: one provider (a live Provider object, or a
  // declarative spec / plain map), plus any extra feature options.
  private func chainOpts(_ provider: Value, _ extra: [(String, Value)] = []) -> Value {
    let fopts = VMap()
    fopts.entries["active"] = .bool(true)
    fopts.entries["providers"] = .list([provider])
    for (k, v) in extra {
      fopts.entries[k] = v
    }
    return .map(vm(("secrets", .map(fopts))))
  }

  private func working(_ value: String) -> Value {
    return .nat(SecretsProbeProvider("working:test") { name in
      "apikey" == name ? value : nil
    })
  }

  private var broken: Value {
    return .nat(SecretsProbeProvider("broken:test") { _ in
      throw SecretsProbeError("vault unreachable")
    })
  }

  private func memorySpec(_ key: String, _ value: String) -> Value {
    return .map(vm(("kind", .string("memory")), ("values", .map(vm((key, .string(value)))))))
  }

  // -------------------------------------------------------------------
  // Driving real entity operations - which is what runs the whole pipeline
  // and reaches the transport. Entities are discovered from the generated
  // CONFIG rather than named, because this file is a TEMPLATE and no
  // project's entity names are known here; each is driven through the
  // shared UnivecEntityBase pipeline exactly as a generated entity's
  // own `list`/`load` do (src/cmp/swift/fragment/Entity*Op.fragment.swift).
  // An op the API does not define fails BEFORE the transport, which is why
  // several may need driving.

  private func entityNames() -> [String] {
    return gp(SdkConfig.sharedConfig(), "entity").asMap?.entries.keys.sorted() ?? []
  }

  private func runEntityOp(_ client: UnivecSDK, _ entity: String,
                           _ opname: String) throws -> Value {
    let ent = UnivecEntityBase(client, nil, entity)
    let ctx = ent.utility.makeContext(
      ["opname": opname, "match": ent.match, "data": ent.data], ent.entctx)
    return try ent.runOp(ctx) {}
  }

  // Drives ops until `stop` reports the observable state a test waits for,
  // and returns the last error an op raised (the operation's own outcome is
  // otherwise irrelevant: no seeded data, a scripted response). `stop` is
  // handed that last error too, so a fail-closed case can stop on EITHER
  // outcome - the refusal it wants, or a request going out, which is the
  // failure it exists to catch; stopping only on the refusal would report
  // "nothing to assert on" for the leak.
  private func driveEntityOpUntil(_ client: UnivecSDK, _ what: String,
                                  _ stop: (Error?) -> Bool) -> Error? {
    var last: Error? = nil

    for name in entityNames() {
      for op in ["list", "load"] {
        do {
          let out = try runEntityOp(client, name, op)
          if let m = out.asMap, let e = m.entries["err"]?.asNative as? Error {
            last = e
          }
        } catch {
          last = error
        }
        if stop(last) {
          return last
        }
      }
    }

    XCTFail("no entity operation \(what) - nothing to assert on")
    return last
  }

  @discardableResult
  private func driveEntityOp(_ client: UnivecSDK, _ w: SecretsWire) -> Error? {
    let before = w.api().count
    return driveEntityOpUntil(client, "reached the transport") { _ in before < w.api().count }
  }

  // ===================================================================
  // The feature-inactive baseline: bit-identical behaviour.

  func testInactiveApikeyOptionBehavesExactlyAsBefore() throws {
    let client = UnivecSDK.testSDK(nil, vm(("apikey", .string("OPTKEY01"))))
    let fetchdef = try client.prepare(vm(("path", .string("/"))))
    let headers = gp(fetchdef, "headers").asMap ?? VMap()
    credentialIs(gp(headers, "authorization").asString ?? "", "OPTKEY01")

    // No runtime activation, no extend: the feature must not be installed,
    // whatever this project's model says.
    XCTAssertNil(secretsOf(client),
      "the feature must not install itself without feature.secrets.active")
  }

  func testInactiveNoApikeyMeansNoAuthorizationHeader() throws {
    let client = UnivecSDK.testSDK(nil, nil)
    let fetchdef = try client.prepare(vm(("path", .string("/"))))
    let headers = gp(fetchdef, "headers").asMap ?? VMap()
    XCTAssertNil(headers.entries["authorization"],
      "unexpected authorization header: \(stringify(gp(headers, "authorization")))")
  }

  // ===================================================================
  // Active: the provider chain, driven through real entity operations.

  func testApikeyOptionStillWinsOverTheChain() throws {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("apikey", .string("OPTKEY01")),
      ("feature", chainOpts(working("CHAINKEY01"))),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "OPTKEY01")

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    guard let sf = secretsOf(client) else {
      return XCTFail("the extend seam did not install the feature")
    }
    XCTAssertEqual("OPTKEY01", try sf.sekreto()!.getfrom("options", "apikey"))
  }

  func testAnOmittedApikeyDefersToTheChainAtTheTransportSeam() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(working("CHAINKEY02"))),
    ])

    // Before any op, nothing has been resolved.
    XCTAssertEqual("", secretsOf(client)!.credential(),
      "the chain was consulted before any operation")

    driveEntityOp(client, w)

    // Resolution happens AT THE TRANSPORT - the one seam every wire path
    // crosses - so the credential is ON THE WIRE, not merely resolved.
    credentialIs(w.api()[0].auth, "CHAINKEY02")
    XCTAssertEqual("CHAINKEY02", secretsOf(client)!.credential())

    // And the shared options map stays FROZEN: prepareAuth clones it on
    // every request, so a feature writing to it would race every concurrent
    // operation.
    XCTAssertEqual("", gp(client.optionsMap(), "apikey").asString ?? "",
      "the options map must stay unwritten after construction")
  }

  func testAnExplicitlyEmptyApikeyAlsoDefersToTheChain() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("apikey", .string("")),
      ("feature", chainOpts(working("CHAINKEY03"))),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "CHAINKEY03")
  }

  func testCustomProviderObjectsAreAcceptedVerbatim() {
    let asklock = NSLock()
    var asked: [String] = []
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider { name in
        asklock.lock()
        asked.append(name)
        asklock.unlock()
        return "CUSTOM01"
      }))),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "CUSTOM01")
    XCTAssertTrue(asked.contains("apikey"),
      "the custom provider was asked \(asked), want it to include apikey")
  }

  func testTypedProviderSpecsAreAcceptedVerbatim() {
    // The typed arm of the providers list: a ProviderSpec built in code
    // joins the chain without going through `specof`.
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(ProviderSpec(
        kind: "memory",
        values: Ordered<String>([("APIKEY", "SPECKEY01")]))))),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "SPECKEY01")
  }

  func testDeclarativeMemorySpecsAreAcceptedAsMaps() {
    // A chain given as plain maps (the shape a config file produces) is
    // turned into ProviderSpecs by sekreto's own `specof`.
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(memorySpec("APIKEY", "MAPKEY01"))),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "MAPKEY01")
  }

  func testAMissEverywhereLeavesTheHeaderOff() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider("empty:test") { _ in nil }))),
    ])

    driveEntityOp(client, w)

    // A MISS falls through to an unauthenticated request - and leaves the
    // header ABSENT rather than empty, which is what prepareAuth does.
    XCTAssertFalse(w.api()[0].hasAuth,
      "a chain MISS must leave the header off, got \"\(w.api()[0].auth)\"")
  }

  func testAuthNullSuppressesTheCredentialChainOrNoChain() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("auth", .null),
      ("apikey", .string("OPTKEY01")),
      ("feature", chainOpts(working("CHAINKEY04"))),
    ])

    driveEntityOp(client, w)

    // Nothing on the wire, even though the chain would have resolved AND an
    // explicit apikey was given.
    XCTAssertFalse(w.api()[0].hasAuth,
      "auth null must suppress the credential, got \"\(w.api()[0].auth)\"")

    // The suppression survives option validation rather than being replaced
    // by the optspec's default auth map.
    let opts = client.optionsMap()
    XCTAssertNotNil(opts.entries["auth"], "options.auth must stay present")
    XCTAssertTrue(opts.entries["auth"]?.isNull ?? false, "options.auth must stay a null")
  }

  func testSecretNameIsConfigurable() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(memorySpec("API_TOKEN", "TOKKEY01"),
        [("name", .string("api.token"))])),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "TOKKEY01")
  }

  func testSekretoIsLiveForArbitrarySecretsAndRedaction() throws {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(memorySpec("DB_PASSWORD", "dbpass01"))),
    ])

    let secrets = secretsOf(client)!.sekreto()!
    XCTAssertEqual("dbpass01", try secrets.get("db.password"))
    XCTAssertEqual("the password is [redacted], keep it safe",
      secrets.redact("the password is dbpass01, keep it safe"))
  }

  // THE PROVIDER VOCABULARY IS NON-EMPTY.
  //
  // The model's choice of plugin groups IS the SDK's provider vocabulary:
  // Config emits the selected definitions and the feature hands them to
  // Sekreto, which refuses at CONSTRUCTION any kind it was not given. A
  // feature that dropped them on the floor would carry every selected plugin
  // FILE and refuse every one of their kinds at runtime, while every test
  // using only built-in kinds stayed green.
  //
  // Conditional on this project selecting a group at all.
  func testASelectedPluginKindIsInTheSdkVocabulary() {
    let plugins = SdkConfig.featurePlugins("secrets")
    if plugins.isEmpty {
      return
    }

    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(memorySpec("APIKEY", "VOCAB01"))),
    ])

    let catalog = secretsOf(client)!.sekreto()!.catalog
    for d in plugins {
      guard let def = d as? Definition else {
        return XCTFail("a selected plugin definition is not a Definition: \(d)")
      }
      XCTAssertTrue(catalog.has(def.name),
        "the model selected plugin kind '\(def.name)' but the feature's Sekreto "
          + "does not know it - the definitions never reached the chain")
    }

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "VOCAB01")
  }

  // ===================================================================
  // FAIL CLOSED. sekreto's miss-vs-error invariant: a MISS falls through, an
  // ERROR does not. A broken vault must never degrade into an
  // unauthenticated request.

  func testAProviderErrorFailsTheEntityOpAndNothingReachesTheWire() {
    // THE RULE, asserted first so a regression reports the leak itself.
    let w = SecretsWire()
    let client = secretsClient(w, [("feature", chainOpts(broken))])

    // Stop on EITHER outcome - the refusal, or a request going out. Stopping
    // on the first op driven would report an op the API does not define
    // (which fails BEFORE the transport) as the provider's refusal.
    let err = driveEntityOpUntil(client, "refused the operation or sent one") { last in
      0 < w.api().count || messageOf(last).contains("vault unreachable")
    }

    XCTAssertEqual(0, w.api().count,
      "a request must not go out unauthenticated because a provider broke,"
        + " but one reached the transport: " + w.wire())
    XCTAssertNotNil(err, "the operation must fail rather than proceed")
    XCTAssertTrue(messageOf(err).contains("vault unreachable"),
      "the failure must carry the PROVIDER'S own message, got: " + messageOf(err))

    // CONTROL, which makes that zero mean REFUSED rather than UNWIRED: the
    // same construction with a WORKING provider must reach the same
    // transport, once, carrying the credential.
    let control = SecretsWire()
    let ok = secretsClient(control, [("feature", chainOpts(working("RAWKEY01")))])
    driveEntityOp(ok, control)

    XCTAssertEqual(1, control.api().count,
      "the control operation did not reach system.fetch exactly once, so "
        + "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "RAWKEY01")
  }

  // THE RAW PATHS, which run NO feature hooks at all. If resolution lived in
  // the PreSpec hook these would send an unauthenticated request and never
  // notice; they are covered because the TRANSPORT is where resolution
  // happens.

  func testDirectCarriesTheChainCredentialAndFailsClosed() {
    let w = SecretsWire()
    let client = secretsClient(w, [("feature", chainOpts(working("DIRECTKEY01")))])

    let res = client.direct(vm(("path", .string("/direct-probe"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "direct refused: " + messageOf(errOf(res)))
    XCTAssertEqual(1, w.api().count, "expected one direct call on the wire: " + w.wire())
    credentialIs(w.api()[0].auth, "DIRECTKEY01")

    // And fail-closed holds for raw access too: a broken chain refuses the
    // direct call before anything reaches the wire, IN BAND.
    let brokenw = SecretsWire()
    let bclient = secretsClient(brokenw, [("feature", chainOpts(broken))])

    let bres = bclient.direct(vm(("path", .string("/direct-probe"))))
    XCTAssertEqual(0, brokenw.api().count,
      "a broken chain must not yield a raw request: " + brokenw.wire())
    XCTAssertEqual(.bool(false), bres.entries["ok"], "a broken chain must refuse the raw path")
    XCTAssertTrue(messageOf(errOf(bres)).contains("vault unreachable"),
      "direct must report the PROVIDER'S own refusal, got: " + messageOf(errOf(bres)))
  }

  func testGraphqlCarriesTheChainCredentialAndFailsClosed() {
    let w = SecretsWire()
    let client = secretsClient(w, [("feature", chainOpts(working("GQLKEY01")))])

    let res = client.graphql("{ thing }", nil, nil)
    XCTAssertEqual(.bool(true), res.entries["ok"], "graphql refused: " + messageOf(errOf(res)))
    XCTAssertEqual(1, w.api().count, "expected one graphql call on the wire: " + w.wire())
    credentialIs(w.api()[0].auth, "GQLKEY01")

    let brokenw = SecretsWire()
    let bclient = secretsClient(brokenw, [("feature", chainOpts(broken))])

    let bres = bclient.graphql("{ thing }", nil, nil)
    XCTAssertEqual(0, brokenw.api().count,
      "a broken chain must not yield a graphql request: " + brokenw.wire())
    XCTAssertEqual(.bool(false), bres.entries["ok"], "a broken chain must refuse graphql")
    XCTAssertTrue(messageOf(errOf(bres)).contains("vault unreachable"),
      "graphql must report the PROVIDER'S own refusal, got: " + messageOf(errOf(bres)))
  }

  // ===================================================================
  // FAIL CLOSED ON A CONSTRUCTION FAILURE. The chain a project configures
  // can be wrong before a single lookup happens, and initFeature cannot
  // fail the client construction the way ts's throwing init does - so it
  // HOLDS the error (`initerr`) and the transport gate refuses to send.
  //
  // The entry pinned here is one the constructor refuses but init used to
  // never SHOW it: a bare kind name where a spec belongs. A loop over the
  // providers list with arms for a Provider, a ProviderSpec and a map, and
  // no `else`, silently DROPPED the entry - the chain got SHORTER rather
  // than broken, and every request went out unauthenticated while the gate
  // had nothing to refuse. That is fail-open by omission, and it survives
  // every other case in this file because each of them configures the
  // chain correctly.
  //
  // Three cases for the three wire paths - the entity pipeline, direct()
  // and graphql() - each with its own CONTROL leg through the SAME live
  // transport, so a zero means REFUSED and not UNWIRED. The refusal is
  // matched on sekreto's OWN message, so an unrelated failure cannot stand
  // in for it.

  // A kind NAME where a provider or spec belongs - the natural slip for a
  // reader of the ts docs.
  private let MALFORMED: Value = .string("hashicorp")
  private let NOTAPROVIDER = "not a provider or a provider spec"

  func testAMalformedProviderEntryFailsTheEntityOpAndNothingReachesTheWire() {
    // CONTROL FIRST, so the zero below is known to be observable at all.
    let control = SecretsWire()
    let ok = secretsClient(control, [("feature", chainOpts(working("INITKEY01")))])
    driveEntityOp(ok, control)
    XCTAssertEqual(1, control.api().count,
      "the control operation did not reach system.fetch exactly once, so "
        + "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE.
    let w = SecretsWire()
    let client = secretsClient(w, [("feature", chainOpts(MALFORMED))])

    // The feature must still be INSTALLED: a construction failure that
    // silently uninstalled it would be the same fail-open by another route,
    // with nothing downstream gating anything.
    XCTAssertNotNil(secretsOf(client),
      "the secrets feature must stay installed on a construction failure")

    let err = driveEntityOpUntil(client, "refused the operation or sent one") { last in
      0 < w.api().count || messageOf(last).contains(NOTAPROVIDER)
    }

    XCTAssertEqual(0, w.api().count,
      "a malformed providers entry was DROPPED and the shortened chain sent "
        + "an UNAUTHENTICATED request: " + w.wire())
    XCTAssertNotNil(err, "the entity op must fail when the chain cannot be built")
    XCTAssertTrue(messageOf(err).contains(NOTAPROVIDER),
      "the refusal must carry sekreto's own message (\(NOTAPROVIDER)), got: " + messageOf(err))
  }

  func testAMalformedProviderEntryFailsDirectRatherThanSending() {
    // CONTROL FIRST.
    let control = SecretsWire()
    let res = secretsClient(control, [("feature", chainOpts(working("INITKEY01")))])
      .direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "the control request failed: " + messageOf(errOf(res)))
    XCTAssertEqual(1, control.api().count,
      "the control request did not reach system.fetch exactly once, so "
        + "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE. direct() runs no feature hook at all, so the ONLY thing
    // that can refuse it is the transport gate.
    let w = SecretsWire()
    let out = secretsClient(w, [("feature", chainOpts(MALFORMED))])
      .direct(vm(("path", .string("/thing"))))

    XCTAssertEqual(0, w.api().count,
      "a malformed providers entry was DROPPED and the shortened chain sent "
        + "an UNAUTHENTICATED direct request: " + w.wire())
    XCTAssertEqual(.bool(false), out.entries["ok"],
      "a chain that could not be built must refuse the raw path fail-closed")
    XCTAssertTrue(messageOf(errOf(out)).contains(NOTAPROVIDER),
      "the refusal must carry sekreto's own message (\(NOTAPROVIDER)), got: " + messageOf(errOf(out)))
  }

  func testAMalformedProviderEntryFailsGraphqlRatherThanSending() {
    // CONTROL FIRST.
    let control = SecretsWire()
    let res = secretsClient(control, [("feature", chainOpts(working("INITKEY01")))])
      .graphql("{ thing }", nil, nil)
    XCTAssertEqual(.bool(true), res.entries["ok"], "the control request failed: " + messageOf(errOf(res)))
    XCTAssertEqual(1, control.api().count,
      "the control request did not reach system.fetch exactly once, so "
        + "this test cannot observe a request going out at all: " + control.wire())
    credentialIs(control.api()[0].auth, "INITKEY01")

    // THE RULE.
    let w = SecretsWire()
    let out = secretsClient(w, [("feature", chainOpts(MALFORMED))])
      .graphql("{ thing }", nil, nil)

    XCTAssertEqual(0, w.api().count,
      "a malformed providers entry was DROPPED and the shortened chain sent "
        + "an UNAUTHENTICATED graphql request: " + w.wire())
    XCTAssertEqual(.bool(false), out.entries["ok"],
      "a chain that could not be built must refuse graphql fail-closed")
    XCTAssertTrue(messageOf(errOf(out)).contains(NOTAPROVIDER),
      "the refusal must carry sekreto's own message (\(NOTAPROVIDER)), got: " + messageOf(errOf(out)))
  }

  // A chain Sekreto's OWN constructor refuses (an unknown kind). This is
  // the case that pins WRAP FIRST, BUILD SECOND: with the wrap installed
  // after the constructor, a throw there would return before the wrap and
  // the held error would be dead code - a misconfigured chain sending
  // ordinary unauthenticated requests, exactly what java shipped.
  func testAChainTheConstructorRefusesFailsClosed() {
    // CONTROL FIRST.
    let control = SecretsWire()
    let res = secretsClient(control, [("feature", chainOpts(working("INITKEY02")))])
      .direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "the control request failed: " + messageOf(errOf(res)))
    XCTAssertEqual(1, control.api().count,
      "the control request did not reach system.fetch exactly once: " + control.wire())

    // THE RULE.
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.map(vm(("kind", .string("nosuchkind")))))),
    ])
    XCTAssertNotNil(secretsOf(client), "the feature must stay installed on a construction failure")
    XCTAssertNil(secretsOf(client)!.sekreto(), "a refused chain must not yield a Sekreto")

    let out = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(0, w.api().count,
      "a chain the constructor refused sent an UNAUTHENTICATED request: " + w.wire())
    XCTAssertEqual(.bool(false), out.entries["ok"], "a refused chain must refuse the raw path")
    XCTAssertTrue(messageOf(errOf(out)).contains("unknown provider kind: nosuchkind"),
      "the refusal must carry sekreto's own message, got: " + messageOf(errOf(out)))
  }

  func testAProviderRecoversAfterATransientFailure() {
    let countlock = NSLock()
    var calls = 0
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider("flaky:test") { _ in
        countlock.lock()
        calls += 1
        let n = calls
        countlock.unlock()
        if 1 == n {
          throw SecretsProbeError("vault unreachable")
        }
        return "RECOVERED01"
      }))),
    ])

    // A failed resolution is never cached, so the second op asks the chain
    // again and succeeds. Holding the failure would mean a transient vault
    // outage poisoned the client permanently.
    _ = driveEntityOpUntil(client, "consulted the chain") { _ in 0 < calls }
    XCTAssertEqual(0, w.api().count, "the first op must not reach the wire")

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "RECOVERED01")
  }

  func testUncachedMissRetractsTheCredential() {
    let havelock = NSLock()
    var have = true
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider("revocable:test") { _ in
        havelock.lock()
        defer { havelock.unlock() }
        return have ? "REVOCABLE01" : nil
      }), [("cache", .bool(false))])),
    ])

    driveEntityOp(client, w)
    credentialIs(w.api()[0].auth, "REVOCABLE01")

    havelock.lock()
    have = false
    havelock.unlock()

    driveEntityOp(client, w)
    let last = w.api().last!
    XCTAssertFalse(last.hasAuth && "" != last.auth,
      "after the chain reports a miss the retracted credential must not go "
        + "out; the wire saw \"" + last.auth + "\"")
  }

  // Concurrent operations share ONE resolution: the first caller asks the
  // chain, the rest wait on it, and every request goes out carrying the
  // credential. A per-request lookup would hit a vault N times for N
  // simultaneous first requests.
  func testConcurrentFirstRequestsShareOneResolution() {
    let countlock = NSLock()
    var lookups = 0
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider("slow:test") { _ in
        countlock.lock()
        lookups += 1
        countlock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        return "SHARED01"
      }))),
    ])

    let n = 8
    DispatchQueue.concurrentPerform(iterations: n) { _ in
      _ = client.direct(vm(("path", .string("/shared"))))
    }

    XCTAssertEqual(n, w.api().count, "every concurrent request must reach the wire: " + w.wire())
    for call in w.api() {
      credentialIs(call.auth, "SHARED01")
    }
    XCTAssertEqual(1, lookups,
      "\(n) concurrent first requests must share ONE resolution, the chain was asked \(lookups) times")
  }

  // ===================================================================
  // THE EXCHANGE. What the chain resolves is a REFRESH token; the feature
  // buys an ACCESS token from the token endpoint and that is what goes on
  // the wire.

  private func exchangeOn(_ extra: [(String, Value)] = []) -> (String, Value) {
    let x = VMap()
    x.entries["active"] = .bool(true)
    x.entries["path"] = .string("auth/token")
    for (k, v) in extra {
      x.entries[k] = v
    }
    return ("exchange", .map(x))
  }

  func testExchangeBuysAnAccessTokenWithTheRefreshToken() {
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "direct refused: " + messageOf(errOf(res)))

    // One purchase, at the token endpoint under the base, carrying the
    // refresh token in the configured request field.
    XCTAssertEqual(1, w.token().count, "expected one token purchase: " + w.wire())
    XCTAssertEqual(SecretsFeatureTest.BASE + "/auth/token", w.token()[0].url)
    XCTAssertTrue(w.token()[0].body.contains("\"refresh_token\":\"REFRESH01\""),
      "the purchase must carry the refresh token, got body: " + w.token()[0].body)

    // And the API request carries the ACCESS token, never the refresh one.
    XCTAssertEqual(1, w.api().count, "expected one API call: " + w.wire())
    credentialIs(w.api()[0].auth, "ACCESS01")
    XCTAssertEqual("ACCESS01", secretsOf(client)!.credential())
  }

  func testASpentTokenIsReboughtOnceAndTheRetryCarriesTheNewToken() {
    let w = SecretsWire()
    w.apistatus = [401, 200]
    let client = secretsClient(w, [
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "direct refused: " + messageOf(errOf(res)))

    // Two purchases (the first, then the rebuy), two API calls: the refused
    // one with the first token, the retry with the second.
    XCTAssertEqual(2, w.token().count, "expected the spent token to be rebought once: " + w.wire())
    XCTAssertEqual(2, w.api().count, "expected the refused request to be retried once: " + w.wire())
    credentialIs(w.api()[0].auth, "ACCESS01")
    credentialIs(w.api()[1].auth, "ACCESS02")
  }

  func testAnExplicitApikeyIsTheStartingAccessTokenWhenExchanging() {
    // With the exchange on, `apikey` is an access token the caller already
    // holds: it is SPENT first, and the API decides whether it is stale.
    let w = SecretsWire()
    w.apistatus = [401, 200]
    let client = secretsClient(w, [
      ("apikey", .string("STARTACCESS01")),
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "direct refused: " + messageOf(errOf(res)))

    XCTAssertEqual(2, w.api().count, "expected the stale starting token to be retried: " + w.wire())
    credentialIs(w.api()[0].auth, "STARTACCESS01")
    XCTAssertEqual(1, w.token().count, "nothing should be bought until the starting token is refused")
    credentialIs(w.api()[1].auth, "ACCESS01")
  }

  func testAFailedPurchaseAnswersWithTheApisOwnRefusal() {
    let w = SecretsWire()
    w.apistatus = [401]
    w.tokenok = 1
    let client = secretsClient(w, [
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    // The rebuy failed (500 from the token endpoint), so the API's 401 is
    // the answer - not the exchange error, which is a symptom.
    XCTAssertEqual(.bool(false), res.entries["ok"])
    XCTAssertEqual(.int(401), res.entries["status"], "expected the API's own refusal, got: \(stringify(.map(res)))")
    XCTAssertEqual(2, w.token().count, "expected the first purchase and one failed rebuy: " + w.wire())
  }

  func testNoRefreshTokenAnywhereFailsClosedWhenExchanging() {
    // CONTROL: the same construction with a refresh token reaches the wire.
    let control = SecretsWire()
    let ok = secretsClient(control, [
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ]).direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), ok.entries["ok"], "the control request failed: " + messageOf(errOf(ok)))
    XCTAssertEqual(1, control.api().count, "the control request did not reach the wire: " + control.wire())

    // THE RULE: no refresh token from the chain, no `exchange.refresh`, no
    // starting `apikey` - there is nothing to buy with, so the request is
    // refused with the feature's own message rather than sent bare.
    let w = SecretsWire()
    let out = secretsClient(w, [
      ("feature", chainOpts(.nat(SecretsProbeProvider("empty:test") { _ in nil }), [exchangeOn()])),
    ]).direct(vm(("path", .string("/thing"))))

    XCTAssertEqual(0, w.api().count, "a request went out with nothing to authenticate it: " + w.wire())
    XCTAssertEqual(.bool(false), out.entries["ok"])
    XCTAssertTrue(messageOf(errOf(out)).contains("no refresh token"),
      "expected the feature's own refusal, got: " + messageOf(errOf(out)))
  }

  func testExchangeDoesNotRetryADeliberatelyUnauthenticatedRefusal() {
    // `auth: null` sends NO credential; a 401 on such a request is not an
    // expired token and buying one would transmit exactly what the caller
    // suppressed.
    let w = SecretsWire()
    w.apistatus = [401]
    let client = secretsClient(w, [
      ("auth", .null),
      ("feature", chainOpts(working("REFRESH01"), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(false), res.entries["ok"])
    XCTAssertEqual(1, w.api().count, "a suppressed-auth 401 must not be retried: " + w.wire())
    XCTAssertFalse(w.api()[0].hasAuth, "auth null must keep the header off, got: " + w.api()[0].auth)
    // Resolution still ran once (the chain was consulted and the access
    // token bought, as go's resolveonce does whatever `auth` says); what
    // the suppression forbids is the REBUY after the refusal.
    XCTAssertEqual(1, w.token().count,
      "a suppressed-auth 401 must not buy another token: " + w.wire())
  }

  func testExchangeInTestModeBuysNothing() {
    // The test feature replaces the transport; a purchase would be the one
    // HTTP call it could not stop. A deterministic fake token instead.
    let fopts = VMap()
    fopts.entries["active"] = .bool(true)
    fopts.entries["providers"] = .list([working("REFRESH01")])
    fopts.entries["exchange"] = exchangeOn().1
    let opts = VMap()
    opts.entries["base"] = .string(SecretsFeatureTest.BASE)
    opts.entries["allow"] = .map(vm(("op", .string("direct,graphql"))))
    opts.entries["feature"] = .map(vm(("secrets", .map(fopts))))

    let client = withSecrets { extend in
      let use = clone(.map(opts)).asMap ?? VMap()
      if extend {
        use.entries["extend"] = .list([.nat(SecretsFeature())])
      }
      return UnivecSDK.testSDK(nil, use)
    }
    XCTAssertEqual("test", client.mode)

    _ = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual("test-access_token", secretsOf(client)!.credential(),
      "test mode must answer with the deterministic fake token")
  }

  func testTheExchangeBodyIsJsonEncoded() throws {
    // A refresh token carrying a quote, a backslash and a newline must
    // arrive as that literal value: the body is ENCODED, never concatenated.
    let nasty = "re\"fresh\\to\nken"
    let w = SecretsWire()
    let client = secretsClient(w, [
      ("feature", chainOpts(working(nasty), [exchangeOn()])),
    ])

    let res = client.direct(vm(("path", .string("/thing"))))
    XCTAssertEqual(.bool(true), res.entries["ok"], "direct refused: " + messageOf(errOf(res)))
    XCTAssertEqual(1, w.token().count, "expected one purchase: " + w.wire())

    let body = try JSON.parse(w.token()[0].body)
    XCTAssertEqual(nasty, gp(body, "refresh_token").asString,
      "the refresh token did not survive the body encoding: " + w.token()[0].body)
  }
}
