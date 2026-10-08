import {
  cmp,
  File,
  Content,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


// The canary sweep: every credential slot holds a distinctive value, every
// diagnostic feature this SDK ships is switched on with a capturing sink, a
// real operation runs through every outcome, and every string that leaves
// the SDK is searched for the canaries and their encoded forms. It also
// proves its own sensitivity: with clean switched off the canary MUST show.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target } = props
  const javapackage: string = props.javapackage

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  File({ name: 'CleanTest.' + target.ext }, () => {
    Content(render(javapackage, model.const.Name + 'SDK', auth))
  })
})


function render(jp: string, sdk: string, auth: {
  suppressed: boolean, where: string, name: string, basic: boolean
}): string {
  return `package ${jp}.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.TreeMap;
import java.util.function.BiFunction;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.function.Supplier;
import java.util.logging.Handler;
import java.util.logging.Level;
import java.util.logging.LogRecord;
import java.util.logging.Logger;

import org.junit.jupiter.api.Test;

import ${jp}.core.Config;
import ${jp}.core.Context;
import ${jp}.core.Entity;
import ${jp}.core.Helpers;
import ${jp}.core.${sdk};
import ${jp}.core.SdkEntity;
import ${jp}.core.SdkError;
import ${jp}.core.Utility;
import ${jp}.feature.BaseFeature;
import ${jp}.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
public class CleanTest {

  // Generated: the credential's wire placement is fixed when the SDK is built.
  static final boolean AUTH_SUPPRESSED = ${auth.suppressed};
  static final String AUTH_WHERE = ${JSON.stringify(auth.where)};
  static final String AUTH_NAME = ${JSON.stringify(auth.name)};
  static final boolean AUTH_BASIC = ${auth.basic};

  static final String CANARY_APIKEY = "CANARY-APIKEY-k9x2m7q4p1";
  static final String CANARY_SECRET = "CANARY-SECRET-w3e8r5t2y6";
  static final String CANARY_HEADER = "CANARY-HEADER-z1x4c7v0b3";
  static final String CANARY_VALUE = "CANARY-VALUE-n5m8b2v9c4";

  static final String MASK = "[redacted]";

  static final String NO_OP =
      "no operation of this SDK completes against a plain 200; nothing to sweep";

  // The logger the log feature builds when handed none.
  static final String LOGGER_NAME = "${sdk}.log";

  // Every form a canary can travel in.
  static final List<String> FORMS = new ArrayList<>();

  static {
    for (String v : List.of(CANARY_APIKEY, CANARY_SECRET, CANARY_HEADER, CANARY_VALUE)) {
      FORMS.add(v);
      FORMS.add(base64(v));
      FORMS.add(URLEncoder.encode(v, StandardCharsets.UTF_8));
    }
    FORMS.add(base64(CANARY_APIKEY + ":" + CANARY_SECRET));
  }

  static String base64(String s) {
    return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
  }

  static final class Sink {
    final String name;
    final String text;

    Sink(String name, String text) {
      this.name = name;
      this.text = text;
    }
  }

  static Map<String, Object> jm(Object... kv) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < kv.length - 1; i += 2) {
      out.put(String.valueOf(kv[i]), kv[i + 1]);
    }
    return out;
  }

  // Header maps keep the caller's spelling; the assertion should not care.
  static Object header(Object map, String name) {
    Map<String, Object> m = Helpers.toMapAny(map);
    if (m == null) {
      return null;
    }
    for (Map.Entry<String, Object> e : m.entrySet()) {
      if (e.getKey().equalsIgnoreCase(name)) {
        return e.getValue();
      }
    }
    return null;
  }

  static List<String> leaks(String text) {
    List<String> out = new ArrayList<>();
    for (String f : FORMS) {
      if (text.contains(f)) {
        out.add(f);
      }
    }
    return out;
  }

  static boolean isFunction(Object v) {
    return v instanceof Function || v instanceof Supplier || v instanceof Consumer
        || v instanceof BiFunction || v instanceof Runnable || v instanceof Utility.CtxFn
        || v instanceof Utility.FetcherFn || v.getClass().isSynthetic();
  }

  // The SDK's JSON emitter prints only maps, lists and scalars, so the
  // sweep reads every other object the way a reflective serialiser would:
  // its public fields, plus its own toString. This is what lets the negative
  // control see the raw spec: with clean off the error carries the live Spec.
  // A context is read as its serialised record, which is what it prints.
  static Object plain(Object v, int depth, IdentityHashMap<Object, Boolean> seen) {
    if (v == null || v instanceof String || v instanceof Number || v instanceof Boolean
        || v instanceof Character || v instanceof Enum) {
      return v;
    }
    if (isFunction(v)) {
      return null;
    }
    if (32 <= depth || seen.containsKey(v)) {
      return "[circular]";
    }
    seen.put(v, Boolean.TRUE);
    try {
      if (v instanceof Map) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) {
          out.put(String.valueOf(e.getKey()), plain(e.getValue(), depth + 1, seen));
        }
        return out;
      }
      if (v instanceof List) {
        List<Object> out = new ArrayList<>();
        for (Object e : (List<Object>) v) {
          out.add(plain(e, depth + 1, seen));
        }
        return out;
      }
      if (v instanceof Context) {
        return plain(((Context) v).toMap(), depth + 1, seen);
      }
      Map<String, Object> out = new LinkedHashMap<>();
      out.put("$string", String.valueOf(v));
      if (v instanceof Throwable) {
        out.put("$message", String.valueOf(((Throwable) v).getMessage()));
      }
      for (Field f : v.getClass().getFields()) {
        if (Modifier.isStatic(f.getModifiers())) {
          continue;
        }
        try {
          out.put(f.getName(), plain(f.get(v), depth + 1, seen));
        }
        catch (ReflectiveOperationException | RuntimeException e) {
          // unreadable field: nothing to sweep
        }
      }
      return out;
    }
    finally {
      seen.remove(v);
    }
  }

  static String stack(Throwable err) {
    StringWriter sw = new StringWriter();
    err.printStackTrace(new PrintWriter(sw));
    return sw.toString();
  }

  interface Text {
    String get();
  }

  static void push(List<Sink> out, String name, Text fn) {
    try {
      out.add(new Sink(name, fn.get()));
    }
    catch (RuntimeException e) {
      // a print that throws leaks nothing
    }
  }

  // Every print of a value: the SDK's JSON, its stringify, the object's own
  // toString; for an error also the message and the stack trace.
  static void forms(List<Sink> out, String name, Object val) {
    push(out, name + ":json", () -> Struct.jsonify(plain(val, 0, new IdentityHashMap<>())));
    push(out, name + ":stringify", () -> Struct.stringify(plain(val, 0, new IdentityHashMap<>())));
    push(out, name + ":string", () -> String.valueOf(val));
    if (val instanceof Throwable) {
      push(out, name + ":message", () -> String.valueOf(((Throwable) val).getMessage()));
      push(out, name + ":stack", () -> stack((Throwable) val));
    }
    if (val instanceof SdkError) {
      push(out, name + ":map", () -> Struct.jsonify(((SdkError) val).toMap()));
    }
    if (val instanceof Context) {
      push(out, name + ":map", () -> Struct.jsonify(((Context) val).toMap()));
    }
  }

  // A sink that is BOTH a Function and a Consumer: the option spec types a
  // callback as a function, which the struct validator recognises only as
  // Function or Supplier, while the feature reads its sink as a Consumer.
  static final class Capture implements Consumer<Map<String, Object>>, Function<Object, Object> {
    final List<Sink> sinks;
    final String name;

    Capture(List<Sink> sinks, String name) {
      this.sinks = sinks;
      this.name = name;
    }

    @Override
    public void accept(Map<String, Object> rec) {
      forms(this.sinks, this.name, rec);
    }

    @Override
    public Object apply(Object rec) {
      forms(this.sinks, this.name, rec);
      return null;
    }
  }

  // Captures the serialised context from inside the pipeline: what a hook
  // author would hand to a logger. Public, as hook dispatch is reflective
  // and skips a method it cannot access.
  public static final class CaptureFeature extends BaseFeature {
    final List<Sink> sinks;

    CaptureFeature(List<Sink> sinks) {
      super("capture", "0.0.1", true);
      this.sinks = sinks;
    }

    @Override
    public void preRequest(Context ctx) {
      forms(this.sinks, "ctx@PreRequest", ctx);
    }

    @Override
    public void preResponse(Context ctx) {
      forms(this.sinks, "ctx@PreResponse", ctx);
    }

    @Override
    public void preUnexpected(Context ctx) {
      forms(this.sinks, "ctx@PreUnexpected", ctx);
    }
  }

  // A feature that fails from inside the pipeline, quoting the request it
  // saw in the code and the message. makeError cleans a failed stage, but
  // PreUnexpected fires inside makeError: what a hook throws there does not
  // pass through it.
  public static final class ThrowFeature extends BaseFeature {
    final boolean unexpected;

    ThrowFeature(boolean unexpected) {
      super("throwhook", "0.0.1", true);
      this.unexpected = unexpected;
    }

    static RuntimeException saw(Context ctx) {
      String saw = "hook saw " + Struct.jsonify(plain(ctx.spec, 0, new IdentityHashMap<>()));
      return ctx.makeError(saw, saw);
    }

    @Override
    public void preResponse(Context ctx) {
      throw saw(ctx);
    }

    @Override
    public void preUnexpected(Context ctx) {
      if (this.unexpected) {
        throw saw(ctx);
      }
    }
  }

  // A stream that fails while the caller iterates it, quoting a credential.
  public static final class StreamThrowFeature extends BaseFeature {
    StreamThrowFeature() {
      super("streamthrow", "0.0.1", true);
    }

    @Override
    public void preDone(Context ctx) {
      ctx.result.stream = () -> new Iterator<Object>() {
        @Override
        public boolean hasNext() {
          throw new RuntimeException("stream saw " + CANARY_APIKEY);
        }

        @Override
        public Object next() {
          throw new NoSuchElementException();
        }
      };
    }
  }

  // A stream that succeeds, yielding the result's items.
  public static final class StreamOkFeature extends BaseFeature {
    StreamOkFeature() {
      super("streamok", "0.0.1", true);
    }

    @Override
    public void preDone(Context ctx) {
      List<Object> items = new ArrayList<>();
      if (ctx.result.resdata instanceof List) {
        items.addAll((List<Object>) ctx.result.resdata);
      }
      else if (ctx.result.resdata != null) {
        items.add(ctx.result.resdata);
      }
      ctx.result.stream = items::iterator;
    }
  }

  static boolean hasFeature(String name) {
    Map<String, Object> fm = Helpers.toMapAny(Config.makeConfig().get("feature"));
    return fm != null && fm.get(name) != null;
  }

  static Map<String, Object> response(int status, Object data, Map<String, Object> headers) {
    Map<String, Object> h = new LinkedHashMap<>();
    h.put("content-type", "application/json");
    if (headers != null) {
      h.putAll(headers);
    }
    final Object body = data;
    return jm(
        "status", status,
        "statusText", status < 400 ? "OK" : "ERR",
        "headers", h,
        "json", (Supplier<Object>) () -> body,
        "body", Struct.jsonify(body));
  }

  static final class Scenario {
    final String name;
    final Utility.FetcherFn respond;

    Scenario(String name, Utility.FetcherFn respond) {
      this.name = name;
      this.respond = respond;
    }
  }

  static final List<Scenario> SCENARIOS = List.of(
      new Scenario("ok", (ctx, url, fetchdef) ->
          response(200, jm("id", "i1", "name", "n1"), jm("x-session-token", "RESP-TOKEN-a1b2c3d4e5"))),
      new Scenario("notfound", (ctx, url, fetchdef) ->
          response(404, jm("error", "no such record"), null)),
      new Scenario("server", (ctx, url, fetchdef) ->
          response(500, jm("error", "boom"), null)),
      new Scenario("transport", (ctx, url, fetchdef) -> {
        throw new RuntimeException("socket hang up (URL was: \\"" + url + "\\")");
      }),
      new Scenario("notjson", (ctx, url, fetchdef) -> jm(
          "status", 200,
          "statusText", "OK",
          "headers", new LinkedHashMap<String, Object>(),
          "json", (Supplier<Object>) () -> {
            throw new RuntimeException("Unexpected token < in JSON");
          },
          "body", "<html>")));

  // Offline, as every generated suite is: the test OPTION resolves a
  // required server variable to test-<name>, and installs no transport.
  static Map<String, Object> offline(Map<String, Object> opts) {
    Map<String, Object> out = new LinkedHashMap<>(opts);
    out.put("test", jm("active", true));
    return out;
  }

  // A client the sweep cannot build leaves nothing swept: a harness error,
  // not a leak.
  static ${sdk} construct(Map<String, Object> opts) {
    try {
      return new ${sdk}(offline(opts));
    }
    catch (RuntimeException e) {
      throw new IllegalStateException(
          "clean harness: the client could not be constructed, so nothing was swept: "
          + e.getMessage(), e);
    }
  }

  static ${sdk} makeSdk(Scenario scenario, List<Sink> sinks, Map<String, Object> cleanopts,
      BaseFeature... extra) {
    return construct(makeOpts(scenario, sinks, cleanopts, extra));
  }

  static Map<String, Object> makeOpts(Scenario scenario, List<Sink> sinks,
      Map<String, Object> cleanopts, BaseFeature... extra) {
    Map<String, Object> feature = new LinkedHashMap<>();
    if (hasFeature("log")) {
      feature.put("log", jm("active", true));
    }
    if (hasFeature("debug")) {
      feature.put("debug", jm("active", true, "onEntry", new Capture(sinks, "debug")));
    }
    if (hasFeature("audit")) {
      feature.put("audit", jm("active", true, "sink", new Capture(sinks, "audit")));
    }
    if (hasFeature("telemetry")) {
      feature.put("telemetry", jm("active", true, "exporter", new Capture(sinks, "telemetry")));
    }
    if (hasFeature("cost")) {
      feature.put("cost", jm("active", true, "sink", new Capture(sinks, "cost")));
    }
    if (hasFeature("metrics")) {
      feature.put("metrics", jm("active", true));
    }
    if (hasFeature("clienttrack")) {
      feature.put("clienttrack", jm("active", true));
    }

    Map<String, Object> clean = jm("values", CANARY_VALUE);
    if (cleanopts != null) {
      clean.putAll(cleanopts);
    }

    List<Object> extend = new ArrayList<>();
    extend.add(new CaptureFeature(sinks));
    extend.addAll(Arrays.asList(extra));

    Map<String, Object> opts = jm(
        "apikey", CANARY_APIKEY,
        "secret", CANARY_SECRET,
        "headers", jm("X-Custom-Token", CANARY_HEADER),
        "clean", clean,
        "feature", feature,
        "extend", extend,
        "utility", jm("fetcher", scenario.respond));
    return opts;
  }

  // Every log line the log feature emits, whichever level it chooses.
  static Handler capture(List<Sink> sinks) {
    Logger logger = Logger.getLogger(LOGGER_NAME);
    Handler handler = new Handler() {
      @Override
      public void publish(LogRecord record) {
        forms(sinks, "log." + record.getLevel().getName().toLowerCase(), record.getMessage());
      }

      @Override
      public void flush() {}

      @Override
      public void close() {}
    };
    handler.setLevel(Level.ALL);
    logger.addHandler(handler);
    return handler;
  }

  static void release(Handler handler) {
    Logger.getLogger(LOGGER_NAME).removeHandler(handler);
  }

  /** One discovered operation: the client accessor, the entity method, and its match. */
  static final class Op {
    final Method accessor;
    final Method call;
    final Map<String, Object> match;

    Op(Method accessor, Method call, Map<String, Object> match) {
      this.accessor = accessor;
      this.call = call;
      this.match = match;
    }
  }

  static Object invoke(${sdk} client, Op op, Map<String, Object> ctrl) throws Exception {
    return invokeOn(op.accessor.invoke(client, new Object[] {null}), op, ctrl);
  }

  static Object invokeOn(Object ent, Op op, Map<String, Object> ctrl) throws Exception {
    try {
      return op.call.invoke(ent, new LinkedHashMap<String, Object>(op.match), ctrl);
    }
    catch (InvocationTargetException ite) {
      Throwable cause = ite.getCause();
      if (cause instanceof Exception) {
        throw (Exception) cause;
      }
      throw ite;
    }
  }

  // Every path parameter an operation's points declare, filled in.
  static Map<String, Object> filled(String entname, String opname) {
    Map<String, Object> out = new LinkedHashMap<>();
    Object points = Struct.getpath(Config.sharedConfig(),
        List.of("entity", entname, "op", opname, "points"));
    if (!(points instanceof List)) {
      return out;
    }
    for (Object point : (List<Object>) points) {
      Object params = Struct.getpath(point, List.of("args", "params"));
      if (params instanceof List) {
        for (Object param : (List<Object>) params) {
          Object name = Struct.getprop(param, "name");
          if (name instanceof String) {
            out.put((String) name, "p1");
          }
        }
      }
    }
    return out;
  }

  // The first operation that completes against a plain 200: with no
  // arguments, else with every path parameter its points declare filled in.
  static Op usableOp() {
    Utility.FetcherFn ok = (ctx, url, fetchdef) -> response(200, jm("id", "i1"), null);
    Map<String, Object> plainOpts = jm("apikey", CANARY_APIKEY, "utility", jm("fetcher", ok));

    Map<String, Method> accessors = new TreeMap<>();
    ${sdk} probe = construct(plainOpts);
    for (Method m : probe.getClass().getMethods()) {
      if (1 != m.getParameterCount() || !Map.class.isAssignableFrom(m.getParameterTypes()[0])) {
        continue;
      }
      if (!Entity.class.isAssignableFrom(m.getReturnType())) {
        continue;
      }
      String entname;
      try {
        entname = ((Entity) m.invoke(probe, new Object[] {null})).getName();
      }
      catch (Exception e) {
        continue;
      }
      if (null != entname && !entname.isEmpty()) {
        accessors.put(entname, m);
      }
    }

    for (Map.Entry<String, Method> e : accessors.entrySet()) {
      Object ent;
      try {
        ent = e.getValue().invoke(probe, new Object[] {null});
      }
      catch (Exception ex) {
        continue;
      }
      for (String opname : List.of("list", "load", "create", "update", "patch", "remove")) {
        Method call;
        try {
          call = ent.getClass().getMethod(opname, Map.class, Map.class);
        }
        catch (NoSuchMethodException ex) {
          continue;
        }
        List<Map<String, Object>> matches =
            List.of(new LinkedHashMap<>(), filled(e.getKey(), opname));
        for (Map<String, Object> match : matches) {
          Op op = new Op(e.getValue(), call, match);
          try {
            invoke(construct(plainOpts), op, new LinkedHashMap<>());
            return op;
          }
          catch (Exception ex) {
            continue;
          }
        }
      }
    }
    return null;
  }

  // Nothing usable is a visible skip; the lane then misses the swept line.
  static Op usableOrSkip() {
    Op op = usableOp();
    if (op == null) {
      System.out.println("clean: skipped: " + NO_OP);
    }
    assumeTrue(op != null, NO_OP);
    return op;
  }

  static Exception drive(${sdk} sdk, Op op, Map<String, Object> ctrl, List<Sink> sinks) {
    // A caller may keep the record it passed rather than read ctrl's entry.
    Object held = ctrl.get("explain");
    Object ent = null;
    Object out = null;
    Exception err = null;
    try {
      ent = op.accessor.invoke(sdk, new Object[] {null});
      out = invokeOn(ent, op, ctrl);
    }
    catch (Exception e) {
      err = e;
    }
    if (err != null) {
      forms(sinks, "error", err);
    }
    if (out != null) {
      forms(sinks, "result", out);
    }
    // Raw, as a caller copying the match into another query reads it.
    if (ent instanceof Entity) {
      forms(sinks, "match", ((Entity) ent).match());
    }
    if (ctrl.get("explain") != null) {
      forms(sinks, "explain", ctrl.get("explain"));
    }
    if (held != null && held != ctrl.get("explain")) {
      forms(sinks, "explain:held", held);
    }
    return err;
  }

  @Test
  public void noCredentialLeavesTheSdkInAnyForm() throws Exception {
    Op op = usableOrSkip();

    List<Sink> sinks = new ArrayList<>();
    Map<String, Exception> errors = new LinkedHashMap<>();
    Map<String, Map<String, Object>> explains = new LinkedHashMap<>();
    Object numbered = null;
    Object named = null;

    Handler handler = capture(sinks);
    try {
      for (Scenario scenario : SCENARIOS) {
        for (String variant : List.of("throw", "explain", "nothrow")) {
          Map<String, Object> ctrl = new LinkedHashMap<>();
          if (!"throw".equals(variant)) {
            ctrl.put("explain", new LinkedHashMap<String, Object>());
          }
          if ("nothrow".equals(variant)) {
            ctrl.put("throw", false);
          }
          ${sdk} sdk = makeSdk(scenario, sinks, null);
          Exception err = drive(sdk, op, ctrl, sinks);
          String key = scenario.name + "/" + variant;
          if (err != null) {
            errors.put(key, err);
          }
          if (ctrl.get("explain") != null) {
            explains.put(key, (Map<String, Object>) ctrl.get("explain"));
          }
          forms(sinks, "sdk", sdk);
        }
      }

      // A name given at run time replaces the declared one: the match leaves
      // out whichever name prepareAuth placed.
      Map<String, Object> renamed = makeOpts(SCENARIOS.get(0), sinks, null);
      renamed.put("auth", jm("name", "zzcred"));
      drive(construct(renamed), op, new LinkedHashMap<>(), sinks);

      // No clean option at all: the schema defaults still apply.
      ${sdk} bare = construct(jm(
          "apikey", CANARY_APIKEY,
          "secret", CANARY_SECRET,
          "headers", jm("X-Custom-Token", CANARY_HEADER),
          "utility", jm("fetcher", SCENARIOS.get(1).respond)));
      assertNotNull(drive(bare, op, new LinkedHashMap<>(), sinks), "the 404 should fail");

      // A credential mistyped as a map. The java validator collects its
      // errors and substitutes the default rather than rejecting, so there
      // is no rejection to sweep: sweep the client, and what clean makes of
      // the value should anything quote it.
      try {
        ${sdk} mistyped = new ${sdk}(offline(jm(
            "apikey", jm("value", CANARY_APIKEY), "clean", jm("values", CANARY_VALUE))));
        forms(sinks, "mistyped", mistyped);
        forms(sinks, "mistyped:quoted", mistyped.getUtility().clean.apply(
            mistyped.getRootCtx(), "found map: " + CANARY_APIKEY));
      }
      catch (RuntimeException e) {
        forms(sinks, "mistyped:rejected", e);
      }

      // A number is registered as the text a message quotes it in.
      ${sdk} numeric = construct(jm("apikey", 918273645));
      numbered = numeric.getUtility().clean.apply(numeric.getRootCtx(), "found 918273645");

      for (boolean unexpected : new boolean[] {false, true}) {
        ${sdk} hooked = makeSdk(SCENARIOS.get(0), sinks, null, new ThrowFeature(unexpected));
        assertNotNull(drive(hooked, op, jm("explain", new LinkedHashMap<String, Object>()), sinks),
            "the throwing hook should fail the operation");
      }

      // Iterating a stream runs inside the same catch path as the operation,
      // and the explain record the caller passed is cleaned however it ends.
      Map<String, BaseFeature[]> streams = new LinkedHashMap<>();
      streams.put("stream", new BaseFeature[] {new StreamThrowFeature()});
      streams.put("stream-ok", new BaseFeature[] {new StreamOkFeature()});
      streams.put("stream-plain", new BaseFeature[] {});
      for (Map.Entry<String, BaseFeature[]> entry : streams.entrySet()) {
        String name = entry.getKey();
        SdkEntity streamed = (SdkEntity) op.accessor.invoke(
            makeSdk(SCENARIOS.get(0), sinks, null, entry.getValue()), new Object[] {null});
        Map<String, Object> explain = new LinkedHashMap<>();
        RuntimeException streamerr = null;
        try {
          streamed.stream(op.call.getName(), jm("reqmatch", new LinkedHashMap<>(op.match)),
              jm("ctrl", jm("explain", explain))).forEach(item -> { });
        }
        catch (RuntimeException e) {
          streamerr = e;
        }
        assertEquals("stream".equals(name), streamerr != null, name + ": only the failing stream throws");
        if (streamerr != null) {
          forms(sinks, name, streamerr);
        }
        assertTrue(!explain.isEmpty(), name + ": the explain record was not filled");
        forms(sinks, name + ":explain", explain);
      }

      // The raw path returns its failure rather than throwing it.
      Map<String, Object> raw = makeSdk(SCENARIOS.get(3), sinks, null).direct(jm("path", "raw"));
      assertTrue(Boolean.FALSE.equals(raw.get("ok")) && raw.get("err") instanceof Throwable,
          "a transport failure should fail direct() with an error");
      forms(sinks, "direct", raw.get("err"));

      // A registered value used as a property name is masked; names that
      // mask alike are kept apart.
      ${sdk} probe = makeSdk(SCENARIOS.get(0), sinks, null);
      named = probe.getUtility().clean.apply(probe.getRootCtx(),
          jm(CANARY_VALUE, 1, CANARY_HEADER, 2, "plain", 3));
      forms(sinks, "named", named);
    }
    finally {
      release(handler);
    }

    List<String> leaked = new ArrayList<>();
    for (Sink s : sinks) {
      List<String> found = leaks(s.text);
      if (!found.isEmpty()) {
        leaked.add(s.name + " [" + String.join(", ", found) + "]");
      }
    }

    System.out.println("clean: swept " + sinks.size() + " surface(s), " + leaked.size() + " leak(s)");

    assertEquals(0, leaked.size(), "credential leaked through: " + String.join("; ", leaked));

    assertEquals("found " + MASK, numbered);
    assertEquals(jm(MASK, 1, MASK + "#1", 2, "plain", 3), named);

    // The positive half: the slot the credential travelled in is masked,
    // and an unregistered token in a response header is masked by name.
    Exception notfound = errors.get("notfound/throw");
    assertNotNull(notfound, "the 404 scenario must throw");
    assertTrue(notfound instanceof SdkError, "the 404 scenario must throw the SDK error: " + notfound);
    SdkError sdkerr = (SdkError) notfound;
    assertEquals(404, sdkerr.status);
    Map<String, Object> spec = Helpers.toMapAny(sdkerr.spec);
    assertNotNull(spec, "the error should carry the cleaned spec as a map");
    if (!AUTH_SUPPRESSED) {
      if ("query".equals(AUTH_WHERE)) {
        assertEquals(MASK, header(spec.get("query"), AUTH_NAME));
      }
      else if ("cookie".equals(AUTH_WHERE)) {
        String cookie = String.valueOf(header(spec.get("headers"), "cookie"));
        assertTrue(cookie.contains(MASK), "cookie: " + cookie);
      }
      else {
        String cred = String.valueOf(header(spec.get("headers"), AUTH_NAME));
        assertTrue(cred.endsWith(MASK), AUTH_NAME + ": " + cred);
      }
    }
    assertEquals(MASK, header(spec.get("headers"), "x-custom-token"));

    Map<String, Object> explained = explains.get("ok/explain");
    assertNotNull(explained);
    Map<String, Object> result = Helpers.toMapAny(explained.get("result"));
    assertNotNull(result, "the explain record should carry the result");
    assertEquals(MASK, header(result.get("headers"), "x-session-token"));
  }

  @Test
  public void theSweepCanSeeALeakCleanSwitchedOffShowsTheCredential() {
    Op op = usableOrSkip();

    List<Sink> sinks = new ArrayList<>();
    ${sdk} sdk = makeSdk(SCENARIOS.get(1), sinks, jm("active", false));
    Exception err = drive(sdk, op, new LinkedHashMap<>(), sinks);
    assertNotNull(err);

    // Explaining a failure must not cost it its error.
    Exception explained = drive(makeSdk(SCENARIOS.get(1), new ArrayList<>(), jm("active", false)), op,
        jm("explain", new LinkedHashMap<String, Object>()), new ArrayList<>());
    assertEquals(err.getMessage(), explained == null ? null : explained.getMessage(),
        "with clean off, explain lost the error");

    int leaked = 0;
    for (Sink s : sinks) {
      if (!leaks(s.text).isEmpty()) {
        leaked++;
      }
    }
    assertTrue(0 < leaked, "with clean off, nothing showed the canary: the sweep is blind");

    if (!AUTH_SUPPRESSED) {
      assertTrue(err instanceof SdkError, "expected the SDK error: " + err);
      String text = Struct.jsonify(plain(((SdkError) err).spec, 0, new IdentityHashMap<>()));
      assertTrue(text.contains(CANARY_APIKEY)
          || text.contains(base64(CANARY_APIKEY + ":" + CANARY_SECRET)),
          "the raw spec should carry the credential when clean is off");
    }
  }

  // An entity block, of per-entity settings or seeded records keyed by
  // entity name and id, is not read at all, and nor are rbac's rules, keyed by
  // entity and operation names.
  @Test
  public void aFeatureNameDoesNotMakeItsSettingsSecret() {
    ${sdk} sdk = construct(jm(
        "apikey", CANARY_APIKEY,
        "feature", jm(
            "secrets", jm("active", false, "kind", "SETTING-KIND-4829", "token", CANARY_SECRET),
            "rbac", jm("active", false, "rules", jm("zztoken.load", "PLAINRULE-k7j5h3g1")),
            "test", jm("active", false, "entity",
                jm("zztoken", jm("ZZTOKEN01", jm("note", "PLAINRECORD-t5r3e1w9"))))),
        "entity", jm("zztoken", jm("alias", jm("zzkey", "PLAINALIAS-m2n4b6v8")))));
    Context root = sdk.getRootCtx();
    assertEquals("SETTING-KIND-4829 " + MASK,
        sdk.getUtility().clean.apply(root, "SETTING-KIND-4829 " + CANARY_SECRET));
    assertEquals("record PLAINRECORD-t5r3e1w9",
        sdk.getUtility().clean.apply(root, "record PLAINRECORD-t5r3e1w9"));
    assertEquals("alias PLAINALIAS-m2n4b6v8",
        sdk.getUtility().clean.apply(root, "alias PLAINALIAS-m2n4b6v8"));
    assertEquals("rule PLAINRULE-k7j5h3g1",
        sdk.getUtility().clean.apply(root, "rule PLAINRULE-k7j5h3g1"));
  }

  @Test
  public void theGeneratedConfigsOwnCleanBlockIsHonoured() {
    Map<String, Object> cfgclean = jm("keys", "zzsens", "values", "CONFIG-SEEDED-1");
    Utility utility = new Utility();
    Context ctx = utility.makeContext.apply(jm(
        "utility", utility,
        "config", jm("options", jm("clean", cfgclean)),
        "options", jm("clean", jm("values", "CALLER-SEEDED-2"))), null);
    ctx.options = utility.makeOptions.apply(ctx);

    assertEquals("a " + MASK + " b " + MASK,
        utility.clean.apply(ctx, "a CONFIG-SEEDED-1 b CALLER-SEEDED-2"));
    assertEquals(jm("my_zzsens", MASK, "other", "y"),
        utility.clean.apply(ctx, jm("my_zzsens", "x", "other", "y")));
    assertEquals("CONFIG-SEEDED-1", cfgclean.get("values"));
  }
}
`
}


export {
  TestClean
}
