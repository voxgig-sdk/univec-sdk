// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Definition.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

/**
 * What a catalog registers: a name, an option shape, and the lifecycle
 * callbacks (§10.1).
 *
 * <p>A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
 * document could produce one, which is the property that makes a catalog a
 * data structure rather than a compile-time registry - and an abstract
 * base class would make every plugin a subclass of this library.
 */
public final class Definition {

  /** A lifecycle callback. It RAISES on failure, as the canonical does. */
  public interface Callback {
    void run(Inst inst);
  }

  /** §9.4's cheap path: the host hands the new options and the old ones. */
  public interface Reconfigure {
    void run(Inst inst, Object now, Object previous);
  }

  public final String name;
  public Object shape;
  public Callback define;
  public Callback activate;
  public Callback deactivate;
  public Callback close;
  public Reconfigure reconfigure;

  public Definition(String name) {
    this.name = name;
  }

  /** The callback for a phase, by the name the log and the corpus use. */
  public Callback callback(String at) {
    switch (at) {
      case "define":
        return define;
      case "activate":
        return activate;
      case "deactivate":
        return deactivate;
      case "close":
        return close;
      default:
        return null;
    }
  }
}
