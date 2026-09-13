package JAVAPACKAGE.sdktest;

// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (com.voxgig.omni.Runner.makeRunner(specref, provider)), presented to
// the corpus tests in the struct-runner shape they already use (run.spec,
// run.runset, run.runsetflags, run.client). No compat shim is vendored:
// the adapter below IS the whole bridge, per language, per the vendor-tag
// rollout (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes
// the engine half of RunnerSupport (runset/matchDeep) and the whole
// StructRunner class (support lives on in RunnerSupport).
//
// Java-specific decisions, each load-bearing:
//
// 1. CONTEXTS STAY MAPS ACROSS THE RUNNER. omni sets `entry.ctx` to the
//    contextified args[0] and `match: {ctx: ...}` assertions read THROUGH
//    it with omni's own getpath, which walks JSON maps only. A typed
//    Context there would make every ctx assertion read "absent". So the
//    subjects receive the MAP, build the typed Context with
//    OmniResolver.omniCtx(args[0], ...) at the call site, run the
//    utility, and write the observable ctx state back into the same map
//    with omniSyncCtx - which is what makes the live SDK reachable
//    through ctx.client for the generated utilities (the ts resolver gets
//    both for free from prototype delegation; maps-plus-sync is the same
//    idiom the go resolver uses for the same contract, omni#56).
//
// 2. ZERO-ARGUMENT ENTRIES. The corpus carries entries with no `in`,
//    `args` or `ctx`, meaning "call the subject with NO argument". The
//    vendored java port already distinguishes that case natively - such
//    an entry arrives as one Json.ABSENT argument (java has no
//    `undefined`, so absence is a sentinel) - which is why java needs no
//    novalargs spec rewrite (go) and no compat shim (lua/php). The
//    resolver's ONE conversion is the sentinel swap at the call boundary:
//    Json.ABSENT -> Struct.UNDEF on the way in (a whole argument only -
//    a parsed corpus value never contains one), Struct.UNDEF ->
//    Json.ABSENT on the way out, walked, because getpath can leave UNDEF
//    inside a partially-resolved node. Ported from the struct java port's
//    own omni bridge (voxgig/struct java/src/test/Omni.java).
//
// 3. THE VENDORED JAVA PORT LACKS THE omni#54 RUNNER FIXES the
//    TypeScript port has at this tag (voxgig/omni#64 landed them for
//    js/go/py only): Util.jsonstr has no cycle guard, and Runner.match
//    clones its base with Util.clone. Both only bite on CYCLIC values,
//    and java's Util.clone/jsonstr pass non-JSON values (a typed Context,
//    an SDK client) through without walking them - so decision 1 above
//    (JSON-only maps in entries, typed state kept out of them) is also
//    what keeps every value the runner clones or stringifies acyclic.
//    The errify half (non-Error throwables) cannot arise: java subjects
//    fail by THROWING, and the errify hook below keeps the SDK error's
//    code for `match: {err: {code: ...}}` assertions.
//
// 4. NO subject-by-name provider hook. Java's Utility fields are TYPED
//    functional interfaces (CtxFn<T> takes a Context), so a generic name
//    lookup cannot produce omni's (Object...) subject without a per-name
//    adapter; every generated call site passes its subject explicitly,
//    so the hook would be dead weight. DEF.client entries still resolve:
//    the client hook below builds another live test SDK.

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.voxgig.omni.Json;
import com.voxgig.omni.Runner;
import com.voxgig.omni.Util;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.UnivecSDK;
import JAVAPACKAGE.core.SdkError;
import JAVAPACKAGE.core.Utility;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked"})
public final class OmniResolver {

  // The sentinels, under the names the corpus tests already use.
  public static final String NULLMARK = Runner.NULLMARK;
  public static final String UNDEFMARK = Runner.UNDEFMARK;
  public static final String EXISTSMARK = Runner.EXISTSMARK;

  private OmniResolver() {}

  /** The function under test, in omni's native argument shape. */
  @FunctionalInterface
  public interface Subject {
    Object call(Object... args) throws Exception;
  }

  /** Resolves one named section of the spec. */
  @FunctionalInterface
  public interface NamedRunner {
    Run runner(String name, Object store);
  }

  /**
   * What the runner returns for one named spec section - the struct-runner
   * shape the corpus call sites consume. A failing entry throws
   * {@link Runner.OmniError}, which fails the JUnit test with the entry
   * named.
   */
  public static final class Run {
    public final Map<String, Object> spec;
    public final Object client;

    private final Runner.RunPack pack;

    private Run(Runner.RunPack pack, Object client) {
      this.pack = pack;
      this.client = client;
      this.spec = Helpers.toMapAny(pack.spec);
    }

    /** A named group of the resolved spec. */
    public Object set(String name) {
      return pack.set(name);
    }

    /** Run one set of test entries with omni's default flags. */
    public void runset(Object testspec, Subject subject) {
      runsetflags(testspec, null, subject);
    }

    /** Run one set of test entries with explicit flags. */
    public void runsetflags(Object testspec, Map<String, Object> flags, Subject subject) {
      Runner.Subject wrapped =
          null == subject
              ? null
              : args -> {
                Object[] sargs = new Object[args.length];
                for (int index = 0; index < args.length; index++) {
                  sargs[index] =
                      Util.isabsent(args[index]) ? Struct.UNDEF : args[index];
                }
                return toomni(subject.call(sargs));
              };
      pack.runsetflags(
          testspec, null == flags ? new LinkedHashMap<>() : flags, wrapped);
    }
  }

  /** Run-time options for a set of test entries ({@code flags("null", false)}). */
  public static Map<String, Object> flags(Object... pairs) {
    return Runner.flags(pairs);
  }

  /**
   * The struct runner's makeRunner(testfile, client) signature, backed by
   * vendored omni. `testfile` is a spec path (absolutized against the
   * working directory - omni's docs say a port must resolve the path
   * itself) or an already-parsed spec value (omni's own capability), which
   * keeps smoke tests free of fixture files.
   */
  public static NamedRunner makeRunner(Object testfile, Object client) {
    Object specref = testfile;
    if (testfile instanceof String) {
      specref = Path.of((String) testfile).toAbsolutePath().normalize().toString();
    }

    Runner.Provider provider = sdkProvider(client);
    Runner.RunnerPack runner = Runner.makeRunner(specref, provider);

    return (name, store) -> new Run(runner.runner(name, store), client);
  }

  /**
   * This port's model -> omni's. Walked, because {@code Struct.UNDEF} CAN
   * sit inside a result - getpath leaves it in a partially-resolved node -
   * and a container built by the port is its own, so rewriting it harms
   * nothing. (Subject ARGUMENTS are never walked: containers must cross by
   * identity so `match.args` sees in-place mutation, e.g. setpath.)
   */
  static Object toomni(Object val) {
    if (Struct.UNDEF == val) {
      return Json.ABSENT;
    }
    if (val instanceof Map) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : ((Map<String, Object>) val).entrySet()) {
        out.put(entry.getKey(), toomni(entry.getValue()));
      }
      return out;
    }
    if (val instanceof List) {
      List<Object> out = new ArrayList<>();
      for (Object entry : (List<Object>) val) {
        out.add(toomni(entry));
      }
      return out;
    }
    return val;
  }

  // defProviders marks the providers a spec's DEF.client block built - the
  // only ones omniCtx lets override a call site's explicit client (the
  // base provider rides on EVERY ctx entry, and letting it win would
  // defeat sections that deliberately construct a differently-optioned
  // client). Identity maps, guarded: JUnit may run tests concurrently.
  private static final Map<Runner.Provider, Object> PROVIDER_CLIENTS =
      new IdentityHashMap<>();
  private static final Set<Runner.Provider> DEF_PROVIDERS =
      java.util.Collections.newSetFromMap(new IdentityHashMap<>());

  private static synchronized void registerProvider(
      Runner.Provider provider, Object client) {
    PROVIDER_CLIENTS.put(provider, client);
  }

  private static synchronized void markDefProvider(Runner.Provider provider) {
    DEF_PROVIDERS.add(provider);
  }

  private static synchronized Object defProviderClient(Runner.Provider provider) {
    return DEF_PROVIDERS.contains(provider) ? PROVIDER_CLIENTS.get(provider) : null;
  }

  /** Wrap a live client as an omni provider (see decisions 1 and 4 above). */
  static Runner.Provider sdkProvider(Object client) {
    Runner.Provider provider = new Runner.Provider();

    // A DEF.client entry becomes another live test SDK, wrapped the same
    // way and marked as DEF-built so omniCtx resolves it back.
    provider.client = (options) -> {
      Map<String, Object> opts = Helpers.toMapAny(options);
      Runner.Provider sub =
          sdkProvider(UnivecSDK.testSDK(null,
              null == opts ? new LinkedHashMap<>() : opts));
      markDefProvider(sub);
      return sub;
    };

    // Client options may reference the runner store.
    provider.inject = (options, store) -> {
      Struct.inject(options, store);
      return options;
    };

    // Keep the SDK error's code beside its message, so a corpus
    // `match: {err: {code: ...}}` can assert on it - the java analogue of
    // the omni#54 errify fix (see decision 3 above).
    provider.errify = (err) -> {
      if (err instanceof SdkError) {
        SdkError sdkerr = (SdkError) err;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("name", "SdkError");
        out.put("message", sdkerr.getMessage());
        if (null != sdkerr.code && !sdkerr.code.isEmpty()) {
          out.put("code", sdkerr.code);
        }
        return out;
      }
      return Runner.errify(err);
    };

    registerProvider(provider, client);

    return provider;
  }

  /**
   * Build the typed Context a generated utility takes from the ctx MAP
   * omni handed the subject (args[0]). The map's `client` entry - an omni
   * provider when a DEF entry selected one - resolves back to the live SDK
   * it wraps; otherwise the given client is used. (The engine half of the
   * retired RunnerSupport.runset call sites did this as makeCtxFromMap +
   * fixctx, per section, by hand.)
   */
  public static Context omniCtx(Object arg, UnivecSDK client, Utility utility) {
    Map<String, Object> ctxmap = Helpers.toMapAny(arg);
    if (null == ctxmap) {
      ctxmap = new LinkedHashMap<>();
    }

    // Only a DEF-built client overrides the caller's: the base provider is
    // on every ctx entry, and a call site that constructed a special
    // client (a DEF.setup options set) must keep it.
    Object p = ctxmap.get("client");
    if (p instanceof Runner.Provider) {
      Object live = defProviderClient((Runner.Provider) p);
      if (live instanceof UnivecSDK) {
        client = (UnivecSDK) live;
        utility = client.getUtility();
      }
    }

    Context ctx = RunnerSupport.makeCtxFromMap(ctxmap, client, utility);
    RunnerSupport.fixctx(ctx, client);
    return ctx;
  }

  /**
   * Write the OBSERVABLE state of a typed context back into the ctx map
   * the entry holds, which is where a `match: {ctx: ...}` assertion reads.
   * The subject mutated the typed context; the map is what the runner can
   * walk. (The retired engine call sites did this per section, by hand,
   * as "update entry ctx for match".)
   */
  public static void omniSyncCtx(Object arg, Context ctx) {
    Map<String, Object> ctxmap = Helpers.toMapAny(arg);
    if (null == ctxmap || null == ctx) {
      return;
    }

    if (null != ctx.spec) {
      Map<String, Object> spec = new LinkedHashMap<>();
      spec.put("base", ctx.spec.base);
      spec.put("prefix", ctx.spec.prefix);
      spec.put("suffix", ctx.spec.suffix);
      spec.put("path", ctx.spec.path);
      spec.put("method", ctx.spec.method);
      spec.put("params", ctx.spec.params);
      spec.put("query", ctx.spec.query);
      spec.put("headers", ctx.spec.headers);
      spec.put("step", ctx.spec.step);
      spec.put("alias", ctx.spec.alias);
      if (null != ctx.spec.body) {
        spec.put("body", ctx.spec.body);
      }
      if (null != ctx.spec.url && !ctx.spec.url.isEmpty()) {
        spec.put("url", ctx.spec.url);
      }
      ctxmap.put("spec", spec);
    }

    if (null != ctx.result) {
      Map<String, Object> res = new LinkedHashMap<>();
      res.put("ok", ctx.result.ok);
      res.put("status", ctx.result.status);
      res.put("statusText", ctx.result.statusText);
      res.put("headers", ctx.result.headers);
      if (null != ctx.result.body) {
        res.put("body", ctx.result.body);
      }
      if (null != ctx.result.err) {
        Map<String, Object> err = new LinkedHashMap<>();
        err.put("message", ctx.result.err.getMessage());
        res.put("err", err);
      }
      if (null != ctx.result.resdata) {
        res.put("resdata", ctx.result.resdata);
      }
      if (null != ctx.result.resmatch) {
        res.put("resmatch", ctx.result.resmatch);
      }
      ctxmap.put("result", res);
    }

    if (null != ctx.response) {
      ctxmap.put("response", "exists");
    }
  }
}
