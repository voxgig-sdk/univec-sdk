// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Entry.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** One instance's record. Mutable, and owned by the host. */
public final class Entry {

  /** A registered teardown (§8.3). */
  public interface ScopeFn {
    void run();
  }

  public final String ref;
  public final Definition def;
  public String status = "declared";
  public double pos;
  public double seq;
  public Object options = Types.newmap();
  public final Map<String, Object> state = new TreeMap<>();
  public Object order;
  public List<String> unmet = new ArrayList<>();
  public List<ScopeFn> scope = new ArrayList<>();

  /**
   * §11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
   * this instance's activation actually chose, per requirement name.
   * Re-ranking on every question silently re-points a live consumer at any
   * better newcomer, and then losing the provider it was really using does
   * not restart it.
   */
  public Map<String, String> selected = new TreeMap<>();

  public List<Point.Bound> bindings = new ArrayList<>();
  public final Map<String, Object> exports = new TreeMap<>();
  public List<Object> provides = new ArrayList<>();
  public Host inner;
  public boolean barred;

  public Entry(String ref, Definition def) {
    this.ref = ref;
    this.def = def;
  }
}
