package voxgig.univecsdk.sdktest

// Requests in flight at once on one client. Each resolves its operation
// through the cache the client's root context shares with every request, and
// registers and cleans secrets through the one registry the client holds.

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.function.BiFunction
import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import voxgig.univecsdk.core.Context
import voxgig.univecsdk.core.Operation
import voxgig.univecsdk.core.UnivecSDK
import voxgig.univecsdk.core.Utility

class ConcurrencyTest {

  private val rounds = 200
  private val width = 8
  private val ops = 32

  // A live client whose transport answers at once.
  private fun liveClient(): UnivecSDK {
    val fetch = BiFunction<String, MutableMap<String, Any?>, MutableMap<String, Any?>> { _, _ ->
      linkedMapOf<String, Any?>(
        "status" to 200,
        "statusText" to "OK",
        "headers" to linkedMapOf<String, Any?>(),
        "json" to Supplier<Any?> { linkedMapOf<String, Any?>("ok" to true) },
      )
    }
    return UnivecSDK(linkedMapOf<String, Any?>(
      "base" to "http://concurrency.test/api",
      "allow" to linkedMapOf<String, Any?>("op" to "direct"),
      "system" to linkedMapOf<String, Any?>("fetch" to fetch),
    ))
  }

  // Runs body on `width` threads released together, and returns what they threw.
  private fun atOnce(body: (Int) -> Unit): List<Throwable> {
    val start = CyclicBarrier(width)
    val thrown = ConcurrentLinkedQueue<Throwable>()
    val threads = (0 until width).map { n ->
      Thread {
        try {
          start.await()
          body(n)
        } catch (t: Throwable) {
          thrown.add(t)
        }
      }.also { it.start() }
    }
    threads.forEach { it.join() }
    return thrown.toList()
  }

  @Test
  fun concurrentFirstRequestsSucceed() {
    repeat(rounds) { round ->
      // A fresh client each round, so every request in it is a first request.
      val client = liveClient()
      val results = arrayOfNulls<MutableMap<String, Any?>>(width)
      val thrown = atOnce { n -> results[n] = client.direct(linkedMapOf<String, Any?>("path" to "p$n")) }

      assertTrue(thrown.isEmpty(), "round $round threw: $thrown")
      results.forEachIndexed { n, res ->
        assertEquals(true, res?.get("ok"), "round $round, request $n failed: $res")
      }
    }
  }

  @Test
  fun concurrentResolutionsShareOneCachedOperation() {
    repeat(rounds) { round ->
      val client = liveClient()
      val utility = client.getUtility()
      val root = client.getRootCtx()
      val got = Array(width) { arrayOfNulls<Operation>(ops) }
      val thrown = atOnce { n ->
        for (k in 0 until ops) {
          got[n][k] = utility.makeContext(linkedMapOf<String, Any?>("opname" to "op$k"), root).op
        }
      }

      assertTrue(thrown.isEmpty(), "round $round threw: $thrown")
      for (k in 0 until ops) {
        val cached = utility.makeContext(linkedMapOf<String, Any?>("opname" to "op$k"), root).op
        for (n in 0 until width) {
          assertSame(cached, got[n][k], "round $round: op$k resolved to more than one Operation")
        }
      }
    }
  }

  private fun addedSecret(round: Int, n: Int, k: Int) = "ADDED-SECRET-$round-$n-$k"

  // Registers thread n's secrets, then counts the thread out of registering.
  private fun registerSecrets(
    utility: Utility, root: Context, round: Int, n: Int, registering: CountDownLatch,
  ) {
    try {
      for (k in 0 until ops) {
        utility.cleanAdd(root, addedSecret(round, n, k))
      }
    } finally {
      registering.countDown()
    }
  }

  private fun assertEverySecretMasked(utility: Utility, root: Context, round: Int) {
    for (n in 0 until width / 2) {
      for (k in 0 until ops) {
        val added = addedSecret(round, n, k)
        assertEquals("[redacted]", utility.clean(root, added),
          "round $round: $added was registered but not masked")
      }
    }
  }

  // Secrets registered on some threads while others clean: every clean masks
  // what was registered before it, the longer secret whole, and no
  // registration is lost.
  @Test
  fun concurrentRegistrationKeepsEverySecretMasked() {
    repeat(rounds / 4) { round ->
      val client = liveClient()
      val utility = client.getUtility()
      val root = client.getRootCtx()
      val inner = "INNER-SECRET-$round"
      utility.cleanAdd(root, inner)
      utility.cleanAdd(root, "OUTER-$inner-TAIL")
      val text = "a $inner b OUTER-$inner-TAIL c"
      val masked = "a [redacted] b [redacted] c"
      assertEquals(masked, utility.clean(root, text))

      val registering = CountDownLatch(width / 2)
      val wrong = ConcurrentLinkedQueue<Any?>()
      val thrown = atOnce { n ->
        if (n < width / 2) {
          registerSecrets(utility, root, round, n, registering)
        } else {
          while (0L < registering.count) {
            val cleaned = utility.clean(root, text)
            if (masked != cleaned) {
              wrong.add(cleaned)
            }
          }
        }
      }

      assertTrue(thrown.isEmpty(), "round $round threw: $thrown")
      assertTrue(wrong.isEmpty(), "round $round cleaned to: $wrong")
      assertEverySecretMasked(utility, root, round)
    }
  }

  // Requests on one client while secrets register on it: each request copies
  // the client's options, the registry among them.
  @Test
  fun concurrentRequestsSurviveRegistration() {
    repeat(rounds / 4) { round ->
      val client = liveClient()
      val utility = client.getUtility()
      val root = client.getRootCtx()
      val registering = CountDownLatch(width / 2)
      val failed = ConcurrentLinkedQueue<Any?>()
      val thrown = atOnce { n ->
        if (n < width / 2) {
          registerSecrets(utility, root, round, n, registering)
        } else {
          while (0L < registering.count) {
            val res = client.direct(linkedMapOf<String, Any?>("path" to "p$n"))
            if (true != res["ok"]) {
              failed.add(res)
              break
            }
          }
        }
      }

      assertTrue(thrown.isEmpty(), "round $round threw: $thrown")
      assertTrue(failed.isEmpty(), "round $round, a request failed: $failed")
      assertEverySecretMasked(utility, root, round)
    }
  }
}
