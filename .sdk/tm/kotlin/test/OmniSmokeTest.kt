package KOTLINPACKAGE.sdktest

// Smoke tests for the vendored omni runner itself: a runner that cannot
// FAIL a bad entry would turn every corpus suite vacuously green, so pin
// the failure paths, not just the happy one. (The kotlin peer of
// tm/ts/test/omni.test.ts and tm/java/test/OmniSmokeTest.java.)

import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

import voxgig.omni.OmniError

import KOTLINPACKAGE.core.UnivecSDK

class OmniSmokeTest {

  // A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
  // like the shared corpus).
  private fun smokeSpec(): MutableMap<String, Any?> = linkedMapOf(
    "primary" to linkedMapOf<String, Any?>(
      "smoke" to linkedMapOf<String, Any?>(
        "basic" to linkedMapOf<String, Any?>(
          "set" to mutableListOf<Any?>(
            linkedMapOf<String, Any?>("in" to 1, "out" to 2),
            linkedMapOf<String, Any?>("in" to 41, "out" to 42),
          ),
        ),
        "bad" to linkedMapOf<String, Any?>(
          "set" to mutableListOf<Any?>(
            linkedMapOf<String, Any?>("in" to 1, "out" to 999),
          ),
        ),
        "err" to linkedMapOf<String, Any?>(
          "set" to mutableListOf<Any?>(
            linkedMapOf<String, Any?>("in" to 0, "err" to "zero refused"),
          ),
        ),
      ),
    ),
  )

  private val smokeInc = OmniResolver.Subject { args ->
    val n = (args[0] as Number).toInt()
    if (0 == n) {
      throw RuntimeException("smoke: zero refused")
    }
    n + 1
  }

  private fun smokeRun(): OmniResolver.Run {
    val runner = OmniResolver.makeRunner(smokeSpec(), UnivecSDK.testSDK())
    val run = runner.runner("smoke", null)
    assertNotNull(run.spec, "smoke spec section did not resolve")
    return run
  }

  @Test
  fun runsetPassesACorrectSubject() {
    val run = smokeRun()
    run.runset(run.spec["basic"], smokeInc)
  }

  @Test
  fun runsetFailsAWrongResult() {
    val run = smokeRun()

    val err = assertThrows(
      OmniError::class.java,
      { run.runset(run.spec["bad"], smokeInc) },
      "a wrong result went unreported - the corpus suites would be vacuously green",
    )

    assertTrue(
      err.message.orEmpty().contains("result mismatch"),
      "expected a result mismatch failure, got: ${err.message}",
    )
  }

  @Test
  fun expectedErrorIsMatchedAndAMissingOneFails() {
    val run = smokeRun()

    // The erroring subject satisfies the expected-error entry.
    run.runset(run.spec["err"], smokeInc)

    // A subject that does NOT raise must fail that same entry.
    val err = assertThrows(
      OmniError::class.java,
      { run.runset(run.spec["err"], OmniResolver.Subject { args -> args[0] }) },
      "a missing expected error went unreported",
    )

    assertTrue(
      err.message.orEmpty().contains("expected error did not occur"),
      "expected an expected-error failure, got: ${err.message}",
    )
  }
}
