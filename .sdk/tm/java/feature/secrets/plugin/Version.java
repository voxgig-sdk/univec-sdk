// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Version.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.at;
import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.num;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Versions and ranges (§11.2).
 *
 * <p>TWO FIELDS AND ONE PREDICATE. A capability declares {@code version},
 * a concrete version. A requirement declares {@code range}. A requirement
 * is satisfied when the names match, the {@code match} passes, and the
 * provider's {@code version} falls inside the requirement's {@code range}.
 *
 * <p>That is the whole rule. There is no third field and no second
 * comparison - an earlier draft added a provider-side {@code compat}
 * range, which left three values and no statement of how they combine, and
 * three defensible readings of one declaration is worse than the ambiguity
 * it was introduced to fix.
 */
public final class Version {

  private Version() {}

  /**
   * A COMPONENT IS BOUNDED, and the bound is the model's, not the host
   * language's. Java's {@code long} and JavaScript's {@code Number}
   * disagree past 2**53, so a twenty-digit component parsed to an exact
   * value in one and a rounded one in the other. 2**31-1 is the smallest
   * bound every target language holds exactly, which makes it the model's.
   */
  public static final long COMPONENT_MAX = 2147483647L;

  private static long component(String digits, String whole, String field) {
    long value;
    try {
      value = Long.parseLong(digits);
    } catch (NumberFormatException e) {
      // Too long for a long is out of range by definition - the parse
      // failure and the bound check are the same answer, so they give the
      // same code.
      value = COMPONENT_MAX + 1;
    }
    if (COMPONENT_MAX < value) {
      fail(
          "plugin_bad_range",
          "version component out of range in " + whole + ": " + digits,
          details(field, whole));
    }
    return value;
  }

  /**
   * {@code 1}, {@code 1.2} or {@code 1.2.3}, fully anchored - and there is
   * no regex here, so "anchored" is what the code does rather than what an
   * engine was asked for.
   */
  private static long[] parts(String text, String whole, String field) {
    String[] pieces = text.split("\\.", -1);
    if (0 == pieces.length || 3 < pieces.length) {
      return null;
    }
    long[] out = new long[] {0, 0, 0};
    for (int i = 0; i < pieces.length; i++) {
      String piece = pieces[i];
      if (piece.isEmpty()) {
        return null;
      }
      for (int j = 0; j < piece.length(); j++) {
        char c = piece.charAt(j);
        if (c < '0' || '9' < c) {
          return null;
        }
      }
      out[i] = component(piece, whole, field);
    }
    return out;
  }

  /**
   * Two forms and no more (§11.2):
   *
   * <pre>
   *   '2.1'    &gt;= 2.1.0 and &lt; 3.0.0
   *   '~2.1'   &gt;= 2.1.0 and &lt; 2.2.0
   * </pre>
   */
  public static Map<String, Object> parseRange(Object range) {
    String text = str(range);
    if (null == text || text.isEmpty()) {
      fail("plugin_bad_range", "invalid range: " + Json.write(range), details("range", range));
    }

    boolean tilde = text.startsWith("~");
    String body = tilde ? text.substring(1) : text;
    long[] got = parts(body, text, "range");
    if (null == got) {
      fail("plugin_bad_range", "invalid range: " + text, details("range", range));
    }

    List<Object> lo = new ArrayList<>();
    lo.add((double) got[0]);
    lo.add((double) got[1]);
    lo.add((double) got[2]);

    List<Object> hi = new ArrayList<>();
    if (tilde) {
      hi.add((double) got[0]);
      hi.add((double) (got[1] + 1));
      hi.add(0.0);
    } else {
      hi.add((double) (got[0] + 1));
      hi.add(0.0);
      hi.add(0.0);
    }

    Map<String, Object> out = newmap();
    out.put("lo", lo);
    out.put("hi", hi);
    return out;
  }

  public static long[] parseVersion(Object version) {
    String text = str(version);
    if (null == text) {
      fail(
          "plugin_bad_range",
          "invalid version: " + Json.write(version),
          details("version", version));
    }
    long[] got = parts(text, text, "version");
    if (null == got) {
      fail("plugin_bad_range", "invalid version: " + text, details("version", version));
    }
    return got;
  }

  /** The one satisfaction predicate: lo &lt;= version &lt; hi. */
  public static boolean satisfies(Object version, Object range) {
    long[] v = parseVersion(version);
    Map<String, Object> r = parseRange(range);
    return 0 <= compare(v, triple(r.get("lo"))) && 0 > compare(v, triple(r.get("hi")));
  }

  /**
   * satisfies for the internal callers that treat an unparseable version
   * or range as "does not satisfy" - Capability and Graph, both of which
   * run over data the corpus has already admitted.
   */
  public static boolean satisfiesq(Object version, Object range) {
    try {
      return satisfies(version, range);
    } catch (PluginException e) {
      return false;
    }
  }

  private static long[] triple(Object value) {
    long[] out = new long[3];
    for (int i = 0; i < 3; i++) {
      Double n = num(at(value, i));
      out[i] = null == n ? 0 : (long) (double) n;
    }
    return out;
  }

  private static int compare(long[] a, long[] b) {
    for (int i = 0; i < 3; i++) {
      if (a[i] != b[i]) {
        return a[i] < b[i] ? -1 : 1;
      }
    }
    return 0;
  }

  /** The version triple as a comparable key, for the capability rank. */
  public static List<Long> versionParts(String text) {
    List<Long> out = new ArrayList<>();
    for (String piece : text.split("\\.", -1)) {
      try {
        out.add(Long.parseLong(piece));
      } catch (NumberFormatException e) {
        out.add(0L);
      }
    }
    return out;
  }
}
