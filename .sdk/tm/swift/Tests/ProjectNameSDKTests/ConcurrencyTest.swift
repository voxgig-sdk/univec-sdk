// Requests in flight at once on one client. Each registers and cleans
// secrets through the one registry the client holds. A context keeps its own
// copy of the operation cache, so requests share no cache to race on.

import Foundation
import XCTest

@testable import UnivecSdk

final class ConcurrencyTest: XCTestCase {
  private static let rounds = 200
  private static let width = 8
  private static let ops = 32
  private static let masked = "a [redacted] b [redacted] c"

  // What the racing threads report, under one lock.
  private final class Outcome {
    private let lock = NSLock()
    private var notes: [String] = []
    private var left: Int

    init(registering: Int) {
      left = registering
    }

    func note(_ what: String) {
      lock.lock()
      defer { lock.unlock() }
      notes.append(what)
    }

    var first: String? {
      lock.lock()
      defer { lock.unlock() }
      return notes.first
    }

    func registered() {
      lock.lock()
      defer { lock.unlock() }
      left -= 1
    }

    var registering: Bool {
      lock.lock()
      defer { lock.unlock() }
      return 0 < left
    }
  }

  // A live client whose transport answers at once.
  private static func liveClient() -> UnivecSDK {
    let fetcher: FetcherFunc = { _, _, _ in
      let res = VMap()
      res.entries["status"] = .int(200)
      res.entries["statusText"] = .string("OK")
      res.entries["headers"] = .map(VMap())
      res.entries["json"] = .nat({ () -> Value in .map(vm(("ok", .bool(true)))) } as NativeCall0)
      return .map(res)
    }
    return UnivecSDK(vm(
      ("base", .string("http://concurrency.test/api")),
      ("allow", .map(vm(("op", .string("direct"))))),
      ("utility", .map(vm(("fetcher", .nat(fetcher)))))))
  }

  // Runs body on width threads, released once every one is waiting; a
  // thread's error is noted.
  private static func atOnce(_ outcome: Outcome, _ body: @escaping (Int) throws -> Void) {
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let done = DispatchGroup()
    for n in 0..<width {
      done.enter()
      let thread = Thread {
        ready.signal()
        start.wait()
        do {
          try body(n)
        } catch {
          outcome.note("threw: \(error)")
        }
        done.leave()
      }
      thread.start()
    }
    for _ in 0..<width {
      ready.wait()
    }
    for _ in 0..<width {
      start.signal()
    }
    done.wait()
  }

  private static func addedSecret(_ round: Int, _ n: Int, _ k: Int) -> String {
    return "ADDED-SECRET-\(round)-\(n)-\(k)"
  }

  // Registers thread n's secrets, then counts the thread out.
  private static func registerSecrets(
    _ utility: Utility, _ root: Context, _ round: Int, _ n: Int, _ outcome: Outcome
  ) {
    defer { outcome.registered() }
    for k in 0..<ops {
      utility.cleanAdd(root, .string(addedSecret(round, n, k)))
    }
  }

  // The first secret registered in the round that a clean leaves raw.
  private static func unmaskedSecret(_ utility: Utility, _ root: Context, _ round: Int) -> String? {
    for n in 0..<(width / 2) {
      for k in 0..<ops {
        let added = addedSecret(round, n, k)
        if utility.clean(root, .string(added)).asString != "[redacted]" {
          return added
        }
      }
    }
    return nil
  }

  func testConcurrentFirstRequestsSucceed() {
    for round in 0..<ConcurrencyTest.rounds {
      // A fresh client each round, so every request in it is a first request.
      let client = ConcurrencyTest.liveClient()
      let outcome = Outcome(registering: 0)
      ConcurrencyTest.atOnce(outcome) { n in
        let res = client.direct(vm(("path", .string("p\(n)"))))
        if gp(res, "ok") != .bool(true) {
          outcome.note("request \(n) failed: \(stringify(.map(res)))")
        }
      }
      if let first = outcome.first {
        XCTFail("round \(round): \(first)")
        return
      }
    }
  }

  // Secrets registered on some threads while others clean: every clean masks
  // what was registered before it, the longer secret whole, and no
  // registration is lost.
  func testConcurrentRegistrationKeepsEverySecretMasked() {
    let half = ConcurrencyTest.width / 2
    let masked = ConcurrencyTest.masked
    for round in 0..<(ConcurrencyTest.rounds / 4) {
      let client = ConcurrencyTest.liveClient()
      let utility = client.getUtility()
      let root = client.getRootCtx()
      let inner = "INNER-SECRET-\(round)"
      utility.cleanAdd(root, .string(inner))
      utility.cleanAdd(root, .string("OUTER-\(inner)-TAIL"))
      let text = "a \(inner) b OUTER-\(inner)-TAIL c"
      XCTAssertEqual(utility.clean(root, .string(text)).asString, masked, "round \(round)")

      let outcome = Outcome(registering: half)
      ConcurrencyTest.atOnce(outcome) { n in
        if n < half {
          ConcurrencyTest.registerSecrets(utility, root, round, n, outcome)
          return
        }
        while outcome.registering {
          let got = utility.clean(root, .string(text)).asString ?? ""
          if got != masked {
            outcome.note("cleaned to: \(got)")
            return
          }
        }
      }
      if let first = outcome.first {
        XCTFail("round \(round) \(first)")
        return
      }
      if let raw = ConcurrencyTest.unmaskedSecret(utility, root, round) {
        XCTFail("round \(round): \(raw) was registered but not masked")
        return
      }
    }
  }

  // Requests on one client while secrets register on it: each request copies
  // the client's options, the registry among them.
  func testConcurrentRequestsSurviveRegistration() {
    let half = ConcurrencyTest.width / 2
    for round in 0..<(ConcurrencyTest.rounds / 4) {
      let client = ConcurrencyTest.liveClient()
      let utility = client.getUtility()
      let root = client.getRootCtx()
      let outcome = Outcome(registering: half)
      ConcurrencyTest.atOnce(outcome) { n in
        if n < half {
          ConcurrencyTest.registerSecrets(utility, root, round, n, outcome)
          return
        }
        while outcome.registering {
          let res = client.direct(vm(("path", .string("p\(n)"))))
          if gp(res, "ok") != .bool(true) {
            outcome.note("a request failed: \(stringify(.map(res)))")
            return
          }
        }
      }
      if let first = outcome.first {
        XCTFail("round \(round) \(first)")
        return
      }
      if let raw = ConcurrencyTest.unmaskedSecret(utility, root, round) {
        XCTFail("round \(round): \(raw) was registered but not masked")
        return
      }
    }
  }
}
