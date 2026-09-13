package JAVAPACKAGE.sdktest;

// Smoke tests for the vendored omni runner itself: a runner that cannot
// FAIL a bad entry would turn every corpus suite vacuously green, so pin
// the failure paths, not just the happy one. (The java peer of
// tm/ts/test/omni.test.ts and tm/go/test/omnismoke_test.go.)

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.voxgig.omni.Runner;

import JAVAPACKAGE.core.UnivecSDK;

public class OmniSmokeTest {

  // A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
  // like the shared corpus).
  static Map<String, Object> smokeSpec() {
    Map<String, Object> spec = new LinkedHashMap<>();
    Map<String, Object> primary = new LinkedHashMap<>();
    Map<String, Object> smoke = new LinkedHashMap<>();

    Map<String, Object> basic = new LinkedHashMap<>();
    basic.put("set", List.of(
        Map.of("in", 1, "out", 2),
        Map.of("in", 41, "out", 42)));
    smoke.put("basic", basic);

    Map<String, Object> bad = new LinkedHashMap<>();
    bad.put("set", List.of(Map.of("in", 1, "out", 999)));
    smoke.put("bad", bad);

    Map<String, Object> err = new LinkedHashMap<>();
    err.put("set", List.of(Map.of("in", 0, "err", "zero refused")));
    smoke.put("err", err);

    primary.put("smoke", smoke);
    spec.put("primary", primary);
    return spec;
  }

  static Object smokeInc(Object... args) {
    int n = ((Number) args[0]).intValue();
    if (0 == n) {
      throw new RuntimeException("smoke: zero refused");
    }
    return n + 1;
  }

  static OmniResolver.Run smokeRun() {
    OmniResolver.NamedRunner runner =
        OmniResolver.makeRunner(smokeSpec(), UnivecSDK.testSDK());
    OmniResolver.Run run = runner.runner("smoke", null);
    assertNotNull(run.spec, "smoke spec section did not resolve");
    return run;
  }

  @Test
  public void runsetPassesACorrectSubject() {
    OmniResolver.Run run = smokeRun();
    run.runset(run.spec.get("basic"), OmniSmokeTest::smokeInc);
  }

  @Test
  public void runsetFailsAWrongResult() {
    OmniResolver.Run run = smokeRun();

    Runner.OmniError err = assertThrows(Runner.OmniError.class,
        () -> run.runset(run.spec.get("bad"), OmniSmokeTest::smokeInc),
        "a wrong result went unreported - the corpus suites would be vacuously green");

    assertTrue(err.getMessage().contains("result mismatch"),
        "expected a result mismatch failure, got: " + err.getMessage());
  }

  @Test
  public void expectedErrorIsMatchedAndAMissingOneFails() {
    OmniResolver.Run run = smokeRun();

    // The erroring subject satisfies the expected-error entry.
    run.runset(run.spec.get("err"), OmniSmokeTest::smokeInc);

    // A subject that does NOT raise must fail that same entry.
    Runner.OmniError err = assertThrows(Runner.OmniError.class,
        () -> run.runset(run.spec.get("err"), (args) -> args[0]),
        "a missing expected error went unreported");

    assertTrue(err.getMessage().contains("expected error did not occur"),
        "expected an expected-error failure, got: " + err.getMessage());
  }
}
