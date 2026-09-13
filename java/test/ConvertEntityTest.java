package voxgig.univecsdk.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.core.SdkEntity;
import voxgig.univecsdk.core.UnivecSDK;
import voxgig.univecsdk.utility.Json;
import voxgig.univecsdk.utility.struct.Struct;

@SuppressWarnings({"unchecked", "unused"})
public class ConvertEntityTest {

  @Test
  public void instance() {
    UnivecSDK testsdk = UnivecSDK.testSDK();
    SdkEntity ent = testsdk.convert(null);
    assertNotNull(ent, "expected non-null convert entity");
  }

  @Test
  public void basic() {
    RunnerSupport.EntityTestSetup setup = convertBasicSetup(null);
    // Per-op sdk-test-control.json skip — basic test exercises a flow
    // with multiple ops; skipping any op skips the whole flow.
    String mode = setup.live ? "live" : "unit";
    for (String op : new String[] { "create" }) {
      String reason = RunnerSupport.skipReason("entityOp", "convert." + op, mode);
      Assumptions.assumeTrue(reason == null,
          reason == null || "".equals(reason)
              ? "skipped via sdk-test-control.json" : reason);
    }
    // The basic flow consumes synthetic IDs from the fixture. In live mode
    // without an *_ENTID env override, those IDs hit the live API and 4xx.
    Assumptions.assumeFalse(setup.syntheticOnly,
        "live entity test uses synthetic IDs from fixture — set UNIVEC_TEST_CONVERT_ENTID JSON to run live");
    UnivecSDK client = setup.client;

    // CREATE
    SdkEntity convertRef01Ent = client.convert(null);
    Map<String, Object> convertRef01Data = Helpers.toMapAny(Struct.getprop(
        Struct.getpath(setup.data, "new.convert"), "convert_ref01"));

    Object convertRef01DataResult = convertRef01Ent.create(convertRef01Data, null);
    convertRef01Data = Helpers.toMapAny(convertRef01DataResult instanceof SdkEntity ? ((SdkEntity) convertRef01DataResult).data() : convertRef01DataResult);
    assertNotNull(convertRef01Data, "expected create result to be a map");

  }

  static RunnerSupport.EntityTestSetup convertBasicSetup(Map<String, Object> extra) {
    RunnerSupport.loadEnvLocal();

    Map<String, Object> entityData;
    try {
      String entityDataSource = Files.readString(Path.of(
          "..", ".sdk", "test", "entity", "convert", "ConvertTestData.json"));
      entityData = Helpers.toMapAny(Json.parse(entityDataSource));
    }
    catch (Exception e) {
      throw new AssertionError("failed to read convert test data: " + e.getMessage(), e);
    }

    Map<String, Object> options = new LinkedHashMap<>();
    options.put("entity", entityData.get("existing"));

    UnivecSDK client = UnivecSDK.testSDK(options, extra);

    // Generate idmap via transform, matching TS pattern.
    List<Object> idnames = new ArrayList<>();
    idnames.add("convert01");
    idnames.add("convert02");
    idnames.add("convert03");
    Object idmap = Struct.transform(idnames, Json.parse(
        "{\"`$PACK`\": [\"\", {"
        + "\"`$KEY`\": \"`$COPY`\","
        + "\"`$VAL`\": [\"`$FORMAT`\", \"upper\", \"`$COPY`\"]"
        + "}]}"));

    // Detect ENTID env override before envOverride consumes it. When live
    // mode is on without a real override, the basic test runs against
    // synthetic IDs from the fixture and 4xx's. Surface this so the test
    // can skip.
    String entidEnvRaw = RunnerSupport.getenv("UNIVEC_TEST_CONVERT_ENTID");
    boolean idmapOverridden = entidEnvRaw != null
        && entidEnvRaw.trim().startsWith("{");

    Map<String, Object> envm = new LinkedHashMap<>();
    envm.put("UNIVEC_TEST_CONVERT_ENTID", idmap);
    envm.put("UNIVEC_TEST_LIVE", "FALSE");
    envm.put("UNIVEC_TEST_EXPLAIN", "FALSE");
    envm.put("UNIVEC_APIKEY", "");
    Map<String, Object> env = RunnerSupport.envOverride(envm);

    Map<String, Object> idmapResolved = Helpers.toMapAny(env.get("UNIVEC_TEST_CONVERT_ENTID"));
    if (idmapResolved == null) {
      idmapResolved = Helpers.toMapAny(idmap);
    }

    boolean live = "TRUE".equals(env.get("UNIVEC_TEST_LIVE"));
    if (live) {
      // sdk-test-control.json's test.client.options seeds the live
      // client; the generated fields below overwrite anything they name.
      Map<String, Object> liveOpts =
          new LinkedHashMap<>(RunnerSupport.liveClientOptions());
      liveOpts.put("apikey", env.get("UNIVEC_APIKEY"));
      // An empty map, not a null one: merge answers null when its last
      // entry is null, and basicSetup is normally called with no extras -
      // so a bare null silently discarded the apikey and server values
      // above.
      Map<String, Object> extraOpts =
          extra == null ? new LinkedHashMap<>() : extra;
      Object mergedOpts = Struct.merge(Struct.jt(liveOpts, extraOpts));
      client = new UnivecSDK(Helpers.toMapAny(mergedOpts));
    }

    RunnerSupport.EntityTestSetup setup = new RunnerSupport.EntityTestSetup();
    setup.client = client;
    setup.data = entityData;
    setup.idmap = idmapResolved;
    setup.env = env;
    setup.explain = "TRUE".equals(env.get("UNIVEC_TEST_EXPLAIN"));
    setup.live = live;
    setup.syntheticOnly = live && !idmapOverridden;
    setup.now = System.currentTimeMillis();
    return setup;
  }
}
