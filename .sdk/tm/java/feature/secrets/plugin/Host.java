// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Host.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.asint;
import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.get;
import static JAVAPACKAGE.feature.secrets.plugin.Types.has;
import static JAVAPACKAGE.feature.secrets.plugin.Types.keys;
import static JAVAPACKAGE.feature.secrets.plugin.Types.map;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.num;
import static JAVAPACKAGE.feature.secrets.plugin.Types.same;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;
import static JAVAPACKAGE.feature.secrets.plugin.Types.truthy;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * The host: the lifecycle state machine (§5), extension points (§6), and
 * resource capture (§8).
 *
 * <p>TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * <p>Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
 * never interleaved; a transition triggered from inside a lifecycle
 * callback is {@code plugin_reentrant}. A hard rule, because it is the
 * only way the semantics can be identical in Go, in Java and in
 * single-threaded JavaScript.
 *
 * <p>Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by suspending
 * on a promise.
 *
 * <p>THIS HOST IS NOT THREAD-SAFE, and that is the model rather than an
 * omission: §5.2 makes transitions sequential, and a lock would only turn
 * a concurrent call into a slow one that still violated the ordering the
 * corpus pins.
 */
public final class Host {

  private final Object opts;
  private final String dependency;
  private final Object reserved;
  private final Object points;
  private Catalog catalog = new Catalog();

  private final Map<String, Entry> inst = new TreeMap<>();
  private final List<String> log = new ArrayList<>();

  /**
   * §14: the lifecycle event record. {@code seq} distinguishes ONE
   * INCARNATION of stripe$test from the next, which is the whole reason it
   * is not {@code pos} (§4 rule 4).
   */
  private final List<Object> events = new ArrayList<>();

  private double seqn;
  private long open;
  private boolean transition;

  /**
   * WHICH callback is running, not merely that one is. §8.1 puts resource
   * capture in {@code activate} and 8.3 says {@code release} outside
   * {@code activate} is {@code plugin_release_scope} - and a bare flag
   * cannot tell {@code activate} from {@code define}, so it admitted an
   * acquire in {@code define} whose scope {@code unload} would never
   * unwind.
   */
  private String phase = "";

  /**
   * Set for the duration of a bulk teardown, so {@code held} knows this is
   * a coordinated operation rather than an ad-hoc deactivation.
   */
  private boolean coordinated;

  public Host(Object options) {
    this.opts = null == options ? newmap() : options;
    String dep = str(get(this.opts, "dependency"));
    this.dependency = null == dep ? "restart" : dep;
    this.reserved = get(this.opts, "reserved");
    this.points = get(this.opts, "points");
  }

  public static Host makeHost(Object options) {
    return new Host(options);
  }

  public void define(Definition definition) {
    catalog.add(definition);
  }

  public Catalog catalog() {
    return catalog;
  }

  public void catalog(Catalog replacement) {
    this.catalog = replacement;
  }

  public boolean intransition() {
    return transition;
  }

  public String phase() {
    return phase;
  }

  public boolean haspoint(String name) {
    return has(points, name);
  }

  public void openinc() {
    open++;
  }

  public void opendec() {
    open--;
  }

  // --- observation ------------------------------------------------

  /**
   * Introspection NEVER advances the state (§5.2). A status page must not
   * be a way to accidentally import twenty packages.
   */
  public Map<String, Object> list() {
    Map<String, Object> out = newmap();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      out.put(e.getKey(), e.getValue().status);
    }
    return out;
  }

  /**
   * The instance record, or null when nothing is registered under that
   * ref. THE REF IS VALIDATED, not merely canonicalized: looking an
   * instance up by {@code "bad name"} is {@code plugin_bad_name}, not a
   * quiet miss.
   */
  public Entry instance(Object ref) {
    return inst.get(Refs.canonRef(ref));
  }

  public List<Object> trace() {
    return new ArrayList<>(events);
  }

  public Map<String, Object> observable(Object result) {
    Map<String, Object> out = newmap();
    out.put("status", list());
    out.put("open", (double) open);
    out.put("log", new ArrayList<Object>(log));
    out.put("result", result);
    return out;
  }

  // --- the state machine ------------------------------------------

  private void guard() {
    if (!transition) {
      return;
    }
    fail("plugin_reentrant", "transition attempted from inside a lifecycle callback", null);
  }

  private Entry need(Object ref) {
    String r = Refs.canonRef(ref);
    Entry entry = inst.get(r);
    if (null == entry) {
      fail("plugin_not_loaded", "no such instance: " + r, details("ref", r));
    }
    return entry;
  }

  private void checkreserved(String ref) {
    // `Types.list` spelled out: this class has its own `list()` (the
    // status map), and an unqualified call would resolve to that one.
    List<Object> list = Types.list(reserved);
    if (null == list || list.isEmpty()) {
      return;
    }
    if (!list.contains(Refs.refname(ref))) {
      return;
    }
    fail("plugin_ref_reserved", "ref is reserved by the host: " + ref, details("ref", ref));
  }

  private void run(Entry entry, String callback, String at) {
    log.add(entry.ref + ":" + at);
    Map<String, Object> event = newmap();
    event.put("ref", entry.ref);
    event.put("event", at);
    event.put("seq", entry.seq);
    event.put("status", entry.status);
    events.add(event);

    Definition.Callback func = entry.def.callback(callback);
    if (null == func) {
      return;
    }

    transition = true;
    phase = at;
    try {
      func.run(new Inst(this, entry));
    } catch (RuntimeException e) {
      // §12: `plugin_define_failed` and its three siblings are "a callback
      // raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A CODE
      // KEEPS IT - the code is the error's identity, and a plugin raising
      // `store_unreachable` must not have it rewritten. Only a code-less
      // error is wrapped.
      if (!Types.codeof(e).isEmpty()) {
        throw e;
      }
      fail(
          "plugin_" + at + "_failed",
          entry.ref + " raised in " + at + ": " + e.getMessage(),
          details("ref", entry.ref, "cause", e.getMessage()));
    } finally {
      transition = false;
      phase = "";
    }
  }

  /**
   * AUTO-TAGGING IS EXPLICIT (§4 rule 3). {@code declare("stripe", tag:
   * "?")} assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
   * assigned pair. Without {@code "?"}, a collision is an error.
   */
  private String autotag(String name) {
    long n = 1;
    while (true) {
      String cand = Refs.formatRef(name, String.valueOf(n));
      if (!inst.containsKey(cand)) {
        return cand;
      }
      n++;
    }
  }

  public Entry declare(Object ref, Object spec) {
    Object useref = ref;
    if ("?".equals(get(spec, "tag"))) {
      useref = autotag(Refs.refname(Refs.canonRef(ref)));
    }
    String r = Refs.canonRef(useref);
    if (!truthy(get(spec, "hostowned"))) {
      checkreserved(r);
    }
    String defname = null == str(get(spec, "definition")) ? Refs.refname(r) : str(get(spec, "definition"));
    Definition definition = catalog.get(defname);
    if (null == definition) {
      fail("plugin_unknown_definition", "not in catalog: " + defname, details("name", defname));
    }

    Entry existing = inst.get(r);
    if (null != existing) {
      // §4 rule 1: a pair addresses at most one instance. Re-declaring the
      // SAME definition is the idempotent case; a different one is a
      // duplicate, not a silent overwrite (seneca) and not an
      // impossibility (sdkgen).
      if (!existing.def.name.equals(definition.name)) {
        fail("plugin_ref_duplicate", "instance already declared: " + r, details("ref", r));
      }
      return existing;
    }

    Entry entry = new Entry(r, definition);
    Double pos = num(get(spec, "pos"));
    entry.pos = null == pos ? inst.size() : pos;
    entry.seq = seqn;
    Object options = get(spec, "options");
    entry.options = null == options ? newmap() : options;
    entry.order = get(spec, "order");
    seqn++;
    inst.put(r, entry);
    return entry;
  }

  /**
   * §9.1: a host that reserves a name MUST still be able to declare the
   * instance it reserved - "The host declares those instances itself,
   * after the user merge, and always wins."
   *
   * <p>THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit:
   * no language here can tell the embedding host from a plugin holding the
   * same host object. What reservation protects is CONFIGURATION -
   * documents, overlays, {@code VOXGIG_PLUGIN_*}, construction options and
   * ordinary declare/load/options - and all of that still checks.
   */
  public Entry hostdeclare(Object ref, Object spec) {
    guard();
    Map<String, Object> owned = newmap();
    Map<String, Object> given = map(spec);
    if (null != given) {
      owned.putAll(given);
    }
    owned.put("hostowned", Boolean.TRUE);
    return declare(ref, owned);
  }

  public Entry load(Object ref, Object spec) {
    guard();
    Entry entry = declare(ref, spec);
    if (!"declared".equals(entry.status)) {
      return entry; // idempotent trivially
    }

    // PRESENCE, NOT TRUTH: an empty options map must CLEAR what the
    // instance was declared with.
    if (has(spec, "options") && null != get(spec, "options")) {
      entry.options = get(spec, "options");
    }
    try {
      run(entry, "define", "define");
    } catch (RuntimeException e) {
      entry.status = "failed";
      throw e;
    }
    entry.status = "loaded";

    // AT LOAD, and before anything runs: a cycle through restart-causing
    // requirements does not settle, and the only safe time to report a
    // non-terminating reconcile is before it starts (§11.3). `provides` is
    // populated by `define`, which has just run, so this is the first
    // moment the graph is complete.
    try {
      Depend.checkcycle(graphnodes());
    } catch (RuntimeException e) {
      entry.status = "failed";
      throw e;
    }
    return entry;
  }

  /** The requirement graph as plain data, for the pure detector. */
  private List<Depend.Node> graphnodes() {
    List<Depend.Node> out = new ArrayList<>();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      List<String> provides = new ArrayList<>();
      for (Object p : e.getValue().provides) {
        provides.add(str(get(p, "name")));
      }
      out.add(new Depend.Node(e.getKey(), provides, Depend.requirements(e.getValue().options)));
    }
    return out;
  }

  public Entry activate(Object ref) {
    guard();
    Entry entry = need(ref);
    if ("live".equals(entry.status)) {
      return entry; // no-op returning success
    }
    if ("failed".equals(entry.status)) {
      fail("plugin_bad_state", "instance has failed: " + entry.ref, details("ref", entry.ref));
    }
    // §9.6: `active: false` bars the instance from running, and the bar is
    // on the INSTANCE rather than on the apply that set it. `ready`
    // reaches this through `activate`, so one guard covers both verbs the
    // design names.
    if (entry.barred) {
      fail(
          "plugin_inactive",
          "instance is barred by active: false: " + entry.ref,
          details("ref", entry.ref));
    }
    if ("declared".equals(entry.status)) {
      load(entry.ref, null);
    }

    // A declared requirement that is not live means `pending`: activation
    // is a STANDING REQUEST, not a one-shot event.
    List<String> unmet = unmetof(entry);
    if (!unmet.isEmpty()) {
      entry.unmet = unmet;
      entry.status = "pending";
      return entry;
    }

    try {
      run(entry, "activate", "activate");
    } catch (RuntimeException e) {
      // Unwind whatever the partial activation captured, in reverse.
      unwind(entry);
      entry.status = "failed";
      throw e;
    }
    // §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every later
    // question - the cascade, `hold`, `unmet` - reads it back rather than
    // re-ranking, which is what "always-reluctant" means.
    for (Object req : Depend.requirements(entry.options)) {
      chosen(entry, req, true);
    }
    entry.status = "live";
    reconcile();
    return entry;
  }

  public Entry deactivate(Object ref) {
    guard();
    Entry entry = need(ref);
    if ("loaded".equals(entry.status) || "declared".equals(entry.status)) {
      return entry;
    }

    // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
    if ("failed".equals(entry.status)) {
      fail("plugin_bad_state", "instance has failed: " + entry.ref, details("ref", entry.ref));
    }

    if ("pending".equals(entry.status)) {
      // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It never
      // reached activate, so it holds no scope and no live bindings;
      // running the definition's deactivate there would be teardown
      // without matching setup, which plugins are not written to survive
      // and which could fail an instance that had done nothing wrong. It
      // cannot fail.
      entry.status = "loaded";
      entry.unmet = new ArrayList<>();
      return entry;
    }

    held(entry.ref);
    cascade(entry.ref, new LinkedHashSet<>());

    try {
      run(entry, "deactivate", "deactivate");
    } catch (RuntimeException e) {
      unwind(entry);
      entry.status = "failed";
      throw e;
    }
    releasecheck(entry, unwind(entry));
    entry.status = "loaded";
    reconcile();
    return entry;
  }

  public void unload(Object ref) {
    guard();
    Entry entry = need(ref);
    if ("live".equals(entry.status) || "pending".equals(entry.status)) {
      if ("live".equals(entry.status)) {
        held(entry.ref);
        cascade(entry.ref, new LinkedHashSet<>());
        try {
          run(entry, "deactivate", "deactivate");
        } catch (RuntimeException e) {
          // §5.2: ANY failure during a transition lands the instance in
          // `failed`, with the scope STILL FULLY UNWOUND - and the
          // instance STAYS REGISTERED, because `failed` is a state an
          // operator has to be able to see.
          unwind(entry);
          entry.status = "failed";
          throw e;
        }
        releasecheck(entry, unwind(entry));
      }
      entry.status = "loaded";
    }
    if ("loaded".equals(entry.status) || "failed".equals(entry.status)) {
      try {
        run(entry, "close", "close");
      } finally {
        inst.remove(entry.ref);
      }
      return;
    }
    inst.remove(entry.ref);
  }

  /** Runs the whole forward path in one call (§5.1). */
  public Entry ready(Object ref) {
    guard();
    String r = Refs.canonRef(ref);
    if (!inst.containsKey(r)) {
      declare(r, null);
    }
    if ("declared".equals(inst.get(r).status)) {
      load(r, null);
    }
    return activate(r);
  }

  /**
   * Bindings go live only when activation succeeds (§8.1), so the teardown
   * is the exact inverse: reverse order, always. Returns the errors the
   * scope raised. §8.3: "A failing release does not stop the rest. Every
   * entry runs, in reverse order, whatever any of them does; the errors
   * are collected and raised as one {@code plugin_release_failed}."
   *
   * <p>A selection belongs to ONE activation (§11.4). Leaving {@code live}
   * by any door drops it, so the next activation ranks afresh - keeping it
   * would make a consumer prefer a provider it never actually ran against.
   */
  private List<RuntimeException> unwind(Entry entry) {
    entry.selected = new TreeMap<>();
    List<Entry.ScopeFn> scope = entry.scope;
    entry.scope = new ArrayList<>();
    List<RuntimeException> errors = new ArrayList<>();
    for (int i = scope.size() - 1; 0 <= i; i--) {
      try {
        scope.get(i).run();
      } catch (RuntimeException e) {
        errors.add(e);
      }
    }
    return errors;
  }

  /**
   * §8.3: "A failed release ends the instance in {@code failed}, exactly
   * as a failed callback does (5.2) - a release that raised may have
   * leaked, and an instance that may be holding resources it cannot
   * account for must not be reactivated."
   */
  private void releasecheck(Entry entry, List<RuntimeException> errors) {
    if (errors.isEmpty()) {
      return;
    }
    entry.status = "failed";
    List<String> causes = new ArrayList<>();
    for (RuntimeException e : errors) {
      causes.add(e.getMessage());
    }
    fail(
        "plugin_release_failed",
        "release failed for " + entry.ref + ": " + String.join("; ", causes),
        details("ref", entry.ref, "cause", Types.strings(causes)));
  }

  /**
   * A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1). A bare string
   * is shorthand for {@code {name}}. A ref satisfies too, because a host
   * that genuinely needs a specific instance should not have to invent a
   * capability for it.
   */
  private List<String> unmetof(Entry entry) {
    List<String> out = new ArrayList<>();
    for (Object req : Depend.requirements(entry.options)) {
      if (!Depend.gatesactivation(req)) {
        continue;
      }
      if (!providersof(req).isEmpty()) {
        continue;
      }
      out.add(str(get(req, "name")));
    }
    return out;
  }

  /**
   * §11.4's always-reluctant selection, and the ONE place a provider is
   * picked for a live instance. If this instance already selected a
   * provider for {@code req} and that provider is STILL a candidate, it
   * keeps it - a better-ranked newcomer does not take it.
   *
   * <p>{@code remember} is false for the questions asked ABOUT an instance
   * rather than BY it: introspection must not create a binding.
   */
  private String chosen(Entry entry, Object req, boolean remember) {
    List<Object> cands = providersof(req);
    if (cands.isEmpty()) {
      return null;
    }
    String name = str(get(req, "name"));
    String held = entry.selected.get(name);
    if (null != held) {
      for (Object c : cands) {
        if (held.equals(str(get(c, "ref")))) {
          return held;
        }
      }
    }
    String best = str(get(cands.get(0), "ref"));
    if (remember) {
      entry.selected.put(name, best);
    }
    return best;
  }

  private List<String> boundproviders(Entry entry) {
    List<String> out = new ArrayList<>();
    for (Object req : Depend.requirements(entry.options)) {
      if (!Depend.restartsonloss(req)) {
        continue;
      }
      String ref = chosen(entry, req, false);
      if (null != ref && !out.contains(ref)) {
        out.add(ref);
      }
    }
    return out;
  }

  /**
   * Live instances whose selected provider is {@code ref} and which would
   * be restarted by losing it.
   */
  private List<String> consumersof(String ref) {
    List<String> out = new ArrayList<>();
    for (Map.Entry<String, Entry> e : new TreeMap<>(inst).entrySet()) {
      if (e.getKey().equals(ref) || !"live".equals(e.getValue().status)) {
        continue;
      }
      if (boundproviders(e.getValue()).contains(ref)) {
        out.add(e.getKey());
      }
    }
    return out;
  }

  /**
   * §11.3's {@code hold} asks a DIFFERENT question from the cascade, and
   * reading it off {@code consumersof} answered the cascade's.
   *
   * <p>The cascade wants the edges that RESTART - mandatory-static and
   * optional-static - because a restart is what it performs. {@code hold}
   * says "deactivating a REQUIRED instance is {@code
   * plugin_dependency_held}", and required is cardinality: {@code
   * gatesactivation}, not {@code restartsonloss}. The two sets differ in
   * both directions and each difference was a real bug.
   */
  private List<String> holdersof(String ref) {
    List<String> out = new ArrayList<>();
    for (Map.Entry<String, Entry> e : new TreeMap<>(inst).entrySet()) {
      if (e.getKey().equals(ref) || !"live".equals(e.getValue().status)) {
        continue;
      }
      for (Object req : Depend.requirements(e.getValue().options)) {
        if (!Depend.gatesactivation(req)) {
          continue;
        }
        if (ref.equals(chosen(e.getValue(), req, false))) {
          out.add(e.getKey());
          break;
        }
      }
    }
    return out;
  }

  private List<Object> providersof(Object req) {
    Object name = get(req, "name");
    String want = Refs.canon(str(name));
    List<Object> cands = new ArrayList<>();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      Entry target = e.getValue();
      if (!"live".equals(target.status)) {
        continue;
      }
      // A ref satisfies directly.
      if (e.getKey().equals(want)) {
        Map<String, Object> cand = newmap();
        cand.put("ref", e.getKey());
        cand.put("pos", target.pos);
        Map<String, Object> prov = newmap();
        prov.put("name", name);
        cand.put("provides", prov);
        cands.add(cand);
        continue;
      }
      for (Object prov : target.provides) {
        if (!same(get(prov, "name"), name)) {
          continue;
        }
        Map<String, Object> cand = newmap();
        cand.put("ref", e.getKey());
        cand.put("pos", target.pos);
        cand.put("provides", prov);
        cands.add(cand);
      }
    }
    return Capability.resolveCapability(req, cands);
  }

  /**
   * CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
   *
   * <p>The cascade is part of the provider's own deactivation and runs
   * BEFORE the provider's {@code deactivate} callback and scope unwind, so
   * a consumer's teardown can still call the thing it depends on -
   * flushing a buffer to the store it is about to lose is exactly what a
   * {@code deactivate} callback is for, and a cascade that fired after the
   * provider was already gone would make that impossible.
   */
  private void cascade(String provider, Set<String> seen) {
    if (seen.contains(provider)) {
      return;
    }
    seen.add(provider);

    for (String r : consumersof(provider)) {
      Entry consumer = inst.get(r);
      if (null == consumer || !"live".equals(consumer.status)) {
        continue;
      }

      cascade(r, seen); // deepest-first
      boolean bad = false;
      try {
        run(consumer, "deactivate", "deactivate");
      } catch (RuntimeException e) {
        bad = true;
      }
      List<RuntimeException> errors = unwind(consumer);
      if (bad || !errors.isEmpty()) {
        // §5.2: ANY failure during a transition lands the instance in
        // `failed`. Marking it `pending` handed it straight back to
        // `reconcile`, which would activate it again the moment the
        // provider returned.
        consumer.status = "failed";
        continue;
      }
      consumer.status = "pending";
      consumer.unmet = unmetof(consumer);
    }
  }

  /**
   * The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
   * TEARDOWN. In a bulk operation that is removing the holders too -
   * {@code close}, or an {@code apply} plan whose own steps deactivate
   * them - it is suspended for exactly those holders, and the teardown
   * still runs consumers before providers.
   */
  private void held(String ref) {
    if (!"hold".equals(dependency)) {
      return;
    }
    if (coordinated) {
      return;
    }
    List<String> holders = holdersof(ref);
    if (holders.isEmpty()) {
      return;
    }
    fail(
        "plugin_dependency_held",
        "instance is required by live consumers: " + ref,
        details("ref", ref, "holders", Types.strings(holders)));
  }

  /**
   * EAGER reconciliation: run to a fixed point rather than scheduling.
   *
   * <p>Two directions, and both are the reason {@code pending} exists.
   * Activation is a STANDING REQUEST, not a one-shot event.
   */
  private void reconcile() {
    boolean moved = true;
    int rounds = 0;
    while (moved) {
      moved = false;
      rounds++;
      if (1000 < rounds) {
        break;
      }

      // Losses first, so a cascade settles in one pass rather than
      // alternating with re-activations.
      for (String r : new ArrayList<>(inst.keySet())) {
        Entry entry = inst.get(r);
        if (null == entry || !"live".equals(entry.status)) {
          continue;
        }
        List<Object> lost = new ArrayList<>();
        for (Object q : Depend.requirements(entry.options)) {
          if (Depend.gatesactivation(q) && providersof(q).isEmpty()) {
            lost.add(q);
          }
        }
        if (lost.isEmpty()) {
          continue;
        }
        // POLICY IS PER REQUIREMENT, not per instance (§11.3). A `dynamic`
        // requirement whose provider is gone leaves the consumer LIVE and
        // notified.
        boolean restarts = false;
        for (Object q : lost) {
          if (Depend.restartsonloss(q)) {
            restarts = true;
            break;
          }
        }
        if (!restarts) {
          continue;
        }

        boolean bad = false;
        try {
          run(entry, "deactivate", "deactivate");
        } catch (RuntimeException e) {
          bad = true;
        }
        List<RuntimeException> errors = unwind(entry);
        if (bad || !errors.isEmpty()) {
          entry.status = "failed";
          moved = true;
          continue;
        }
        entry.status = "pending";
        entry.unmet = unmetof(entry);
        moved = true;
      }

      for (String r : new ArrayList<>(inst.keySet())) {
        Entry entry = inst.get(r);
        if (null == entry || !"pending".equals(entry.status)) {
          continue;
        }
        if (!unmetof(entry).isEmpty()) {
          continue;
        }
        try {
          run(entry, "activate", "activate");
          entry.status = "live";
          entry.unmet = new ArrayList<>();
          moved = true;
        } catch (RuntimeException e) {
          unwind(entry);
          entry.status = "failed";
          moved = true;
        }
      }
    }
  }

  // --- ordering ---------------------------------------------------

  public List<String> order(String point) {
    // Sorted by declaration SEQUENCE, which is what makes the §7 sort's
    // fall-through deterministic in a language whose maps have no
    // insertion order. §7 breaks ties by `pos`; two instances CAN share
    // one - `declare` defaults `pos` to the registry size, so an unload
    // followed by a fresh declare reuses a surviving instance's - and past
    // that this was falling through to map order. `seq` is that order,
    // made explicit.
    List<Entry> live = new ArrayList<>();
    for (Entry entry : inst.values()) {
      if ("live".equals(entry.status)) {
        live.add(entry);
      }
    }
    live.sort((a, b) -> Double.compare(a.seq, b.seq));

    List<Order.Binding> bindings = new ArrayList<>();
    for (Entry entry : live) {
      bindings.add(new Order.Binding(entry.ref, entry.pos, entry.order));
    }
    Object pin = null == point ? null : get(get(points, point), "pin");
    return Order.resolveOrder(bindings, pin);
  }

  // --- points -----------------------------------------------------

  /**
   * Live bindings on a point, in resolved order. Recomputed on any change
   * to the live set (§7) rather than cached at startup - the bug a host
   * discovers only when something deactivates in production.
   */
  private List<Point.Bound> bound(String point) {
    List<Point.Bound> out = new ArrayList<>();
    for (String ref : order(point)) {
      Entry entry = inst.get(ref);
      if (null == entry) {
        continue;
      }
      // The band is the INSTANCE's ordering block (§7), stamped by the
      // host. A plugin passing its own would be ranking itself above the
      // order its document declared.
      Long band = asint(get(entry.order, "band"));
      for (Point.Bound b : entry.bindings) {
        if (!b.point.equals(point)) {
          continue;
        }
        out.add(b.withBand(null == band ? 0 : band));
      }
    }
    return out;
  }

  private Object pointspec(String point, String want) {
    if (!has(points, point)) {
      fail("plugin_point_unknown", "no such point: " + point, details("point", point));
    }
    Object spec = get(points, point);
    Object kind = get(spec, "kind");
    if ("hook".equals(want)) {
      // A point with no declared kind is a hook, which is what makes `{}`
      // the minimal point declaration.
      if (null != kind && !"hook".equals(kind)) {
        fail(
            "plugin_point_kind",
            "point is not a hook: " + point,
            details("point", point, "kind", kind));
      }
      return spec;
    }
    if (!want.equals(kind)) {
      fail(
          "plugin_point_kind",
          "point is not a " + want + ": " + point,
          details("point", point, "kind", kind));
    }
    return spec;
  }

  public Object emit(String point, Object arg) {
    Object spec = pointspec(point, "hook");
    String mode = str(get(spec, "mode"));
    return Point.emit(bound(point), null == mode ? "emit" : mode, arg);
  }

  public Object call(String point, Object[] args) {
    Object spec = pointspec(point, "chain");
    Object base = get(spec, "base");
    Point.NextFn basefn =
        base instanceof Point.NextFn
            ? (Point.NextFn) base
            : a -> 0 < a.length ? a[0] : null;
    return Point.compose(bound(point), basefn).call(args);
  }

  public Object provider(String point, Object[] args) {
    Object spec = pointspec(point, "provider");
    Point.Picked pick = Point.provider(bound(point), spec);
    if (null == pick.winner) {
      return get(spec, "default");
    }
    return pick.winner.func.call(null, args);
  }

  /** The losers are VISIBLE rather than silently ignored (§6.3). */
  public List<String> shadowed(String point) {
    if (!has(points, point)) {
      return new ArrayList<>();
    }
    return Point.provider(bound(point), get(points, point)).shadowed;
  }

  public Object exports(String spec) {
    List<Export.Exported> all = new ArrayList<>();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      Entry entry = e.getValue();
      // Exports of a `loaded` (not live) instance are VISIBLE (§11).
      if ("declared".equals(entry.status) || "failed".equals(entry.status)) {
        continue;
      }
      for (Map.Entry<String, Object> x : entry.exports.entrySet()) {
        all.add(new Export.Exported(e.getKey(), x.getKey(), x.getValue()));
      }
    }
    return Export.resolveExport(spec, all);
  }

  /** The live providers of a capability, best-first (§11.1). */
  public List<String> capability(String name) {
    List<Object> cands = new ArrayList<>();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      Entry entry = e.getValue();
      if (!"live".equals(entry.status)) {
        continue;
      }
      for (Object prov : entry.provides) {
        if (!name.equals(str(get(prov, "name")))) {
          continue;
        }
        Map<String, Object> cand = newmap();
        cand.put("ref", e.getKey());
        cand.put("pos", entry.pos);
        cand.put("provides", prov);
        cands.add(cand);
      }
    }
    Map<String, Object> req = newmap();
    req.put("name", name);
    List<String> out = new ArrayList<>();
    for (Object c : Capability.resolveCapability(req, cands)) {
      out.add(str(get(c, "ref")));
    }
    return out;
  }

  // --- documents --------------------------------------------------

  /**
   * §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what changed,
   * and move activation state to match", with the stated ordering -
   * "deactivations and unloads first (reverse load order), then loads,
   * then activations in load order".
   *
   * <p>FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
   * document once, which never looked at instances the new document had
   * DROPPED - so an integration removed from a config reload stayed live
   * with its bindings and resources.
   */
  public void apply(Object doc, Object profile) {
    guard();
    Object useprofile = null == profile ? get(opts, "profile") : profile;

    Map<String, Object> input = newmap();
    input.put("doc", doc);
    input.put("profile", useprofile);
    input.put("keys", get(opts, "keys"));
    input.put("reserved", reserved);
    Map<String, Object> norm = Config.normalizeConfig(input);

    List<Object> wantlist = Types.list(norm.get("order"));
    List<String> want = new ArrayList<>();
    for (Object r : wantlist) {
      want.add(str(r));
    }

    Object defaults = get(opts, "defaults");
    Map<String, Object> optionsof = newmap();
    for (String ref : want) {
      Map<String, Object> oin = newmap();
      oin.put("ref", ref);
      oin.put("doc", doc);
      oin.put("profile", useprofile);
      oin.put("shape", shapeof(ref));
      oin.put("hostdefaults", get(defaults, Refs.refname(ref)));
      optionsof.put(ref, Config.resolveOptions(oin));
    }

    Object instances = norm.get("instance");

    // --- phase 1: deactivations and unloads, REVERSE load order ----
    List<String> drop = new ArrayList<>();
    for (Map.Entry<String, Entry> e : inst.entrySet()) {
      if ("declared".equals(e.getValue().status) || wantlive(instances, e.getKey())) {
        continue;
      }
      drop.add(e.getKey());
    }
    // Highest `pos` first, ref-descending for a tie, so a consumer
    // declared after its provider goes down first.
    drop.sort(
        (a, b) -> {
          double pa = inst.get(a).pos;
          double pb = inst.get(b).pos;
          if (pa != pb) {
            return Double.compare(pb, pa);
          }
          return b.compareTo(a);
        });
    for (String ref : drop) {
      unload(ref);
    }

    // --- phase 2: declare and patch EVERYTHING, in load order ------
    for (String ref : want) {
      Object ent = get(instances, ref);
      Map<String, Object> spec = newmap();
      spec.put("options", optionsof.get(ref));
      spec.put("order", get(ent, "order"));
      spec.put("pos", get(ent, "pos"));
      Entry entry = declare(ref, spec);
      // The bar is REASSERTED ON EVERY APPLY, in both directions - a
      // document that turns the instance back on clears it, which is the
      // whole point of a config switch.
      entry.barred = !truthy(get(ent, "active"));
      // REPLACE rather than refill: `Inst.options()` reads the field back
      // through the entry every time, so no callback is holding a map that
      // needs emptying in place.
      entry.options = optionsof.get(ref);
      entry.order = get(ent, "order");
      Double pos = num(get(ent, "pos"));
      entry.pos = null == pos ? 0 : pos;
    }

    // --- phase 3: loads, in load order -----------------------------
    // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
    // twenty map entries and no executed code" (§9.6).
    for (String ref : want) {
      if (wantlive(instances, ref)) {
        load(ref, null);
      }
    }

    // --- phase 4: activations, in load order -----------------------
    for (String ref : want) {
      if (wantlive(instances, ref)) {
        activate(ref);
      }
    }
  }

  /**
   * Should this ref be LIVE after the apply? False for a ref the document
   * declares lazy or inactive AND for one it does not name at all - which
   * is what makes "unload what is gone" and "unload what was toggled off"
   * one rule rather than two.
   */
  private static boolean wantlive(Object instances, String ref) {
    Object ent = get(instances, ref);
    return null != ent && truthy(get(ent, "active")) && "eager".equals(get(ent, "start"));
  }

  private Object shapeof(String ref) {
    Definition definition = catalog.get(Refs.refname(ref));
    return null == definition ? null : definition.shape;
  }

  public void options(Object ref, Object patch) {
    guard();
    Entry entry = need(ref);
    Object previous = entry.options;

    Map<String, Object> merged = newmap();
    Map<String, Object> prev = map(previous);
    if (null != prev) {
      merged.putAll(prev);
    }
    for (String k : keys(patch)) {
      merged.put(k, get(patch, k));
    }

    Map<String, Object> input = newmap();
    input.put("ref", entry.ref);
    input.put("shape", shapeof(entry.ref));
    input.put("doc", newmap());
    input.put("patch", merged);
    entry.options = Config.resolveOptions(input);

    if (!"live".equals(entry.status)) {
      return;
    }

    if (null != entry.def.reconfigure) {
      transition = true;
      try {
        entry.def.reconfigure.run(new Inst(this, entry), entry.options, previous);
      } finally {
        transition = false;
      }
    } else {
      // Always correct and sometimes expensive; `reconfigure` exists to
      // make the common case cheap (§9.4).
      deactivate(entry.ref);
      activate(entry.ref);
    }
  }

  public void close() {
    // A bulk teardown removing the holders too, so `hold` is suspended for
    // exactly those holders (§11.3) - while the consumers-first cascade
    // still runs, which is the half that matters.
    coordinated = true;
    try {
      List<String> refs = new ArrayList<>(inst.keySet());
      Collections.reverse(refs);
      for (String ref : refs) {
        if (inst.containsKey(ref)) {
          unload(ref);
        }
      }
    } finally {
      coordinated = false;
    }
  }

  /**
   * The same record §6.6 gives a plugin about itself, reachable from
   * outside for the corpus.
   */
  public Object positionof(String ref, String point) {
    String myref = Refs.canon(ref);
    Entry entry = inst.get(myref);
    if (null == entry) {
      fail("plugin_not_loaded", "no such instance: " + ref, details("ref", ref));
    }
    List<String> ranked = order(point);
    int index = ranked.indexOf(entry.ref);
    Map<String, Object> out = newmap();
    out.put("index", (double) index);
    out.put("count", (double) ranked.size());
    // §6.2 composes b1(b2(b3(base))) with the FIRST binding OUTERMOST, so
    // these are not index 0 and index count-1 the other way round.
    out.put("outermost", 0 == index);
    out.put("innermost", index == ranked.size() - 1);
    return out;
  }
}
