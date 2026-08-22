package voxgig.univecsdk.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.Supplier;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.core.UnivecSDK;
import voxgig.univecsdk.utility.Json;

@SuppressWarnings({"unchecked", "unused"})
public class ModelDirectTest {

  static Map<String, Object> jm(Object... kv) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < kv.length - 1; i += 2) {
      out.put(String.valueOf(kv[i]), kv[i + 1]);
    }
    return out;
  }

  @Test
  public void directListModel() {
    List<Object> mockres = new ArrayList<>();
    mockres.add(jm("id", "direct01"));
    mockres.add(jm("id", "direct02"));
    DirectSetup setup = directSetup(mockres);
    String mode = setup.live ? "live" : "unit";
    String reason = RunnerSupport.skipReason("direct", "direct-list-model", mode);
    Assumptions.assumeTrue(reason == null,
        reason == null || "".equals(reason)
            ? "skipped via sdk-test-control.json" : reason);
    UnivecSDK client = setup.client;


    Map<String, Object> result = client.direct(jm(
        "path", "v1/models",
        "method", "GET",
        "params", new LinkedHashMap<>()));
    if (setup.live) {
      // Live mode is lenient: synthetic IDs frequently 4xx and the
      // list-response shape varies wildly across public APIs. Skip
      // rather than fail when the call doesn't return a usable list.
      Assumptions.assumeTrue(Boolean.TRUE.equals(result.get("ok")),
          "list call not ok (likely synthetic IDs against live API): " + result);
      int status = Helpers.toInt(result.get("status"));
      Assumptions.assumeTrue(status >= 200 && status < 300,
          "expected 2xx status, got " + result.get("status"));
    }
    else {
      assertEquals(true, result.get("ok"), "expected ok to be true");
      assertEquals(200, Helpers.toInt(result.get("status")), "expected status 200");
    }

    if (!setup.live) {
      assertTrue(result.get("data") instanceof List,
          "expected data to be an array, got " + result.get("data"));
      assertEquals(2, ((List<Object>) result.get("data")).size(), "expected 2 items");

      assertEquals(1, setup.calls.size(), "expected 1 call");
    }
  }

  static class DirectSetup {
    UnivecSDK client;
    List<Map<String, Object>> calls;
    boolean live;
    Map<String, Object> idmap;
  }

  static DirectSetup directSetup(Object mockres) {
    RunnerSupport.loadEnvLocal();

    final List<Map<String, Object>> calls = new ArrayList<>();

    Map<String, Object> envm = new LinkedHashMap<>();
    envm.put("UNIVEC_TEST_MODEL_ENTID", new LinkedHashMap<>());
    envm.put("UNIVEC_TEST_LIVE", "FALSE");
    envm.put("UNIVEC_APIKEY", "NONE");
    Map<String, Object> env = RunnerSupport.envOverride(envm);

    boolean live = "TRUE".equals(env.get("UNIVEC_TEST_LIVE"));

    DirectSetup setup = new DirectSetup();
    setup.calls = calls;

    if (live) {
      Map<String, Object> mergedOpts = new LinkedHashMap<>();
      mergedOpts.put("apikey", env.get("UNIVEC_APIKEY"));
      setup.client = new UnivecSDK(mergedOpts);
      setup.live = true;

      Map<String, Object> idmap = new LinkedHashMap<>();
      Object entidRaw = env.get("UNIVEC_TEST_MODEL_ENTID");
      if (entidRaw instanceof String && ((String) entidRaw).startsWith("{")) {
        Map<String, Object> parsed = Helpers.toMapAny(Json.parseOrNull((String) entidRaw));
        if (parsed != null) {
          idmap = parsed;
        }
      }
      else if (entidRaw instanceof Map) {
        idmap = (Map<String, Object>) entidRaw;
      }
      setup.idmap = idmap;
      return setup;
    }

    final Object mockdata = mockres != null ? mockres : jm("id", "direct01");
    BiFunction<String, Map<String, Object>, Map<String, Object>> mockFetch =
        (url, init) -> {
          calls.add(jm("url", url, "init", init));
          return jm(
              "status", 200,
              "statusText", "OK",
              "headers", new LinkedHashMap<>(),
              "json", (Supplier<Object>) () -> mockdata);
        };

    setup.client = new UnivecSDK(jm(
        "base", "http://localhost:8080",
        "system", jm("fetch", mockFetch)));
    setup.live = false;
    setup.idmap = new LinkedHashMap<>();
    return setup;
  }
}
