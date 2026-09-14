// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Inst.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.asint;
import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.Map;

/**
 * What a definition's callbacks see.
 *
 * <p>Deliberately not the internal record: a plugin that could reach
 * {@code status} could also write it.
 */
public final class Inst {

  public final Host host;
  public final String ref;
  public final String name;
  public final String tag;

  private final Entry entry;

  Inst(Host host, Entry entry) {
    this.host = host;
    this.entry = entry;
    this.ref = entry.ref;
    Map<String, Object> parsed = Refs.parseRef(entry.ref);
    this.name = str(parsed.get("name"));
    this.tag = str(parsed.get("tag"));
  }

  /**
   * The resolved options, READ FRESH. {@code apply} and {@code options}
   * replace the map wholesale, so a callback that cached this at {@code
   * define} would hold the values a later document already changed.
   */
  public Object options() {
    return entry.options;
  }

  /**
   * The instance's own state (§5.4), LIVE: a java map is a reference, so a
   * callback that keeps this sees every later write, and the counter
   * surviving a deactivate/activate cycle is that reference and nothing
   * else.
   */
  public Map<String, Object> state() {
    return entry.state;
  }

  /**
   * Foreign resources the host did not hand out are registered explicitly
   * (§8.3); host calls are recorded automatically.
   *
   * <p>SYMMETRIC WITH {@code acquire}, and it has to be: {@code open}
   * counts the resources CURRENTLY HELD, so an entry that is registered
   * and then unwound must leave the count where it found it.
   */
  public void release(Entry.ScopeFn func) {
    // §8.3: "`inst.release` outside `activate` is
    // `plugin_release_scope`". A flag saying merely that a transition is
    // running is true in `define` too, and a scope entry registered there
    // is never unwound.
    if (!"activate".equals(host.phase())) {
      fail("plugin_release_scope", "release called outside activate", null);
    }
    boolean[] done = new boolean[] {false};
    entry.scope.add(
        () -> {
          if (done[0]) {
            return;
          }
          done[0] = true;
          host.opendec();
          func.run();
        });
    host.openinc();
  }

  /**
   * The synthetic counter the driver owns, so "what is open" is data
   * rather than an assertion each port words differently.
   *
   * <p>Returns its own release, so a plugin can hand one back early. The
   * scope still holds the entry and unwinding it twice is a no-op -
   * releasing early must not make teardown wrong.
   */
  public Entry.ScopeFn acquire() {
    // §8.1: resources are "acquired during `activate` - the scope's actual
    // job". Same reason as `release` above.
    if (!"activate".equals(host.phase())) {
      fail("plugin_release_scope", "acquire called outside activate", null);
    }
    boolean[] done = new boolean[] {false};
    Entry.ScopeFn rel =
        () -> {
          if (done[0]) {
            return;
          }
          done[0] = true;
          host.opendec();
        };
    entry.scope.add(rel);
    host.openinc();
    return rel;
  }

  /**
   * Bind into a host point. Declared in {@code define}; the host inserts
   * it only after {@code activate} returns successfully (§8.1), which is
   * why a failing activate leaves no live binding behind.
   */
  public void bind(String point, Point.BindFn func, Object band) {
    // §12 has carried `plugin_bind_scope` - "binding declared outside
    // `define`" - since before anything raised it. §8.1 puts binding
    // DECLARATION in `define` and INSERTION at a successful activate, and
    // the guard was the half nobody wrote: a binding added from `activate`
    // went live without being part of the loaded definition, and a
    // deactivate/activate cycle appended it again.
    if (!"define".equals(host.phase())) {
      fail(
          "plugin_bind_scope",
          "bind called outside define: " + point,
          details("ref", ref, "point", point));
    }
    if (!host.haspoint(point)) {
      fail("plugin_point_unknown", "no such point: " + point, details("point", point));
    }
    Long value = asint(band);
    entry.bindings.add(new Point.Bound(ref, point, func, null == value ? 0 : value));
  }

  /** Published for other plugins and for the application (§11). */
  public void export(String key, Object value) {
    entry.exports.put(key, value);
  }

  /** What this instance can do for others (§11.1). */
  public void provides(Object prov) {
    entry.provides.add(prov);
  }

  /**
   * Where this binding landed (§6.6) - the plugin-side counterpart to a
   * host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
   * available. Verification tells a plugin it was misplaced; a pin (§7)
   * stops the misplacement from being expressible at all. The two are not
   * substitutes.
   */
  public Object position(String point) {
    return host.positionof(ref, point);
  }

  /**
   * AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
   * INNER ONE'S LIFETIME. Registering the teardown in the instance scope
   * is what makes that true rather than aspirational.
   */
  public Host nest(Object nestopts) {
    if (!host.intransition()) {
      fail("plugin_release_scope", "nest called outside a lifecycle callback", null);
    }
    Host inner = new Host(nestopts);
    entry.scope.add(inner::close);
    entry.inner = inner;
    return inner;
  }
}
