// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/PluginException.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

/**
 * Every error carries a §12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words would
 * make every translation a corpus change. The FORMAT, however, is pinned -
 * a parseable message is what makes a log searchable across twenty
 * languages.
 *
 * <p>UNCHECKED, deliberately. A checked exception would put {@code throws}
 * on every lifecycle callback signature in every plugin ever written, and
 * §19's budget is a library that stays small for the people embedding it.
 */
public class PluginException extends RuntimeException {

  private static final long serialVersionUID = 1L;

  public final String code;
  public final String text;

  /**
   * TRANSIENT because it is a live JSON value, not a serializable field:
   * nothing in this library or its suite serializes an exception, and
   * `-Xlint:serial` is right to ask rather than be silenced.
   */
  public final transient Object details;

  public PluginException(String code, String text, Object details) {
    super(Types.formaterror(code, text, details));
    this.code = code;
    this.text = text;
    this.details = details;
  }
}
