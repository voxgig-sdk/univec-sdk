// Requests in flight at once on one client. Each resolves its operation
// through the cache the client's root context shares with every request, and
// registers and cleans secrets through the one registry the client holds.

import java.util.concurrent.{ConcurrentLinkedQueue, CountDownLatch, CyclicBarrier}
import java.util.function.{BiFunction, Supplier}
import java.util.{Map => JMap}

import voxgig.univecsdk.core.{Context, Operation, UnivecSDK, Utility}

object SdkConcurrencyTestMain {

  private val Rounds = 200
  private val Width = 8
  private val Ops = 32

  private def om(kv: (String, Object)*): JMap[String, Object] = SdkTestSupport.om(kv*)

  // A live client whose transport answers at once.
  private def liveClient(): UnivecSDK = {
    val json: Supplier[Object] = () => om("ok" -> SdkTestSupport.B(true))
    val fetch: BiFunction[String, JMap[String, Object], Object] = (_, _) =>
      om("status" -> SdkTestSupport.I(200), "statusText" -> "OK", "headers" -> om(), "json" -> json)
    new UnivecSDK(om(
      "base" -> "http://concurrency.test/api",
      "allow" -> om("op" -> "direct"),
      "system" -> om("fetch" -> fetch)))
  }

  // Runs body on Width threads released together, and returns what they threw.
  private def atOnce(body: Int => Unit): List[Throwable] = {
    val start = new CyclicBarrier(Width)
    val thrown = new ConcurrentLinkedQueue[Throwable]()
    val threads = (0 until Width).map { n =>
      val runner: Runnable = () =>
        try {
          start.await()
          body(n)
        }
        catch { case e: Throwable => thrown.add(e); () }
      val thread = new Thread(runner)
      thread.start()
      thread
    }
    threads.foreach(_.join())
    thrown.toArray(new Array[Throwable](0)).toList
  }

  private def addedSecret(round: Int, n: Int, k: Int): String =
    "ADDED-SECRET-" + round + "-" + n + "-" + k

  // Registers thread n's secrets, then counts the thread out of registering.
  private def registerSecrets(utility: Utility, root: Context, round: Int, n: Int,
      registering: CountDownLatch): Unit =
    try {
      for (k <- 0 until Ops) utility.cleanAdd(root, addedSecret(round, n, k))
    }
    finally registering.countDown()

  // The first secret registered in the round that a clean leaves raw.
  private def unmasked(utility: Utility, root: Context, round: Int): Option[String] =
    (for (n <- 0 until Width / 2; k <- 0 until Ops) yield addedSecret(round, n, k))
      .find(added => "[redacted]" != utility.clean(root, added))

  // The first failure across the rounds, or null.
  private def firstFailure(round: Int => String): String = {
    var failure: String = null
    var n = 0
    while (failure == null && n < Rounds) {
      failure = round(n)
      n += 1
    }
    failure
  }

  def main(args: Array[String]): Unit = {
    val rep = new SdkTestReport()

    rep.scope("concurrency.requests") {
      val failure = firstFailure { round =>
        // A fresh client each round, so every request in it is a first request.
        val client = liveClient()
        val results = new Array[JMap[String, Object]](Width)
        val thrown = atOnce(n => results(n) = client.direct(om("path" -> ("p" + n))))
        val failed = (0 until Width).find(n =>
          results(n) == null || java.lang.Boolean.TRUE != results(n).get("ok"))
        if (thrown.nonEmpty) "round " + round + " threw: " + thrown
        else failed.map(n => "round " + round + ", request " + n + " failed: " + results(n)).orNull
      }
      rep.check("concurrency.requests", failure == null, failure)
    }

    rep.scope("concurrency.operations") {
      val failure = firstFailure { round =>
        val client = liveClient()
        val utility = client.getUtility()
        val root = client.getRootCtx()
        val got = Array.ofDim[Operation](Width, Ops)
        val thrown = atOnce { n =>
          for (k <- 0 until Ops) {
            got(n)(k) = utility.makeContext(om("opname" -> ("op" + k)), root).op
          }
        }
        val split = (0 until Ops).find { k =>
          val cached = utility.makeContext(om("opname" -> ("op" + k)), root).op
          (0 until Width).exists(n => !(got(n)(k) eq cached))
        }
        if (thrown.nonEmpty) "round " + round + " threw: " + thrown
        else split.map(k => "round " + round + ": op" + k + " resolved to more than one Operation").orNull
      }
      rep.check("concurrency.operations", failure == null, failure)
    }

    // Secrets registered on some threads while others clean: every clean
    // masks what was registered before it, the longer secret whole, and no
    // registration is lost.
    rep.scope("concurrency.registry") {
      val masked = "a [redacted] b [redacted] c"
      val failure = firstFailure { round =>
        if (round >= Rounds / 4) null
        else {
          val client = liveClient()
          val utility = client.getUtility()
          val root = client.getRootCtx()
          val inner = "INNER-SECRET-" + round
          utility.cleanAdd(root, inner)
          utility.cleanAdd(root, "OUTER-" + inner + "-TAIL")
          val text = "a " + inner + " b OUTER-" + inner + "-TAIL c"
          val before = utility.clean(root, text)
          val registering = new CountDownLatch(Width / 2)
          val wrong = new ConcurrentLinkedQueue[Object]()
          val thrown = atOnce { n =>
            if (n < Width / 2) registerSecrets(utility, root, round, n, registering)
            else {
              while (0L < registering.getCount) {
                val got = utility.clean(root, text)
                if (masked != got) wrong.add(got)
              }
            }
          }
          if (masked != before) "round " + round + " cleaned to: " + before
          else if (thrown.nonEmpty) "round " + round + " threw: " + thrown
          else if (!wrong.isEmpty) "round " + round + " cleaned to: " + wrong
          else unmasked(utility, root, round)
            .map(added => "round " + round + ": " + added + " was registered but not masked").orNull
        }
      }
      rep.check("concurrency.registry", failure == null, failure)
    }

    // Requests on one client while secrets register on it: each request
    // copies the client's options, the registry among them.
    rep.scope("concurrency.registry.requests") {
      val failure = firstFailure { round =>
        if (round >= Rounds / 4) null
        else {
          val client = liveClient()
          val utility = client.getUtility()
          val root = client.getRootCtx()
          val registering = new CountDownLatch(Width / 2)
          val failed = new ConcurrentLinkedQueue[Object]()
          val thrown = atOnce { n =>
            if (n < Width / 2) registerSecrets(utility, root, round, n, registering)
            else {
              var going = true
              while (going && 0L < registering.getCount) {
                val res = client.direct(om("path" -> ("p" + n)))
                if (java.lang.Boolean.TRUE != res.get("ok")) {
                  failed.add(res)
                  going = false
                }
              }
            }
          }
          if (thrown.nonEmpty) "round " + round + " threw: " + thrown
          else if (!failed.isEmpty) "round " + round + ", a request failed: " + failed
          else unmasked(utility, root, round)
            .map(added => "round " + round + ": " + added + " was registered but not masked").orNull
        }
      }
      rep.check("concurrency.registry.requests", failure == null, failure)
    }

    rep.finish("CONCURRENCY")
  }
}
