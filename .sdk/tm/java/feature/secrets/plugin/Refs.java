// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (java/src/voxgig/plugin/Refs.java)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package JAVAPACKAGE.feature.secrets.plugin;

import static JAVAPACKAGE.feature.secrets.plugin.Types.details;
import static JAVAPACKAGE.feature.secrets.plugin.Types.fail;
import static JAVAPACKAGE.feature.secrets.plugin.Types.newmap;
import static JAVAPACKAGE.feature.secrets.plugin.Types.str;

import java.util.Map;

/**
 * Identity: name+tag, written {@code name$tag} (§4).
 *
 * <p>The four pure functions, and the whole of what {@code ref} pins. They
 * are the first thing a new port implements and the first corpus section
 * it passes.
 *
 * <p>NO REGEX, and that is not an accident of style. {@code
 * java.util.regex}'s {@code $} matches before a final line terminator, so
 * a {@code ^...$} spelling would admit {@code "stripe\n"} as a name - the
 * hole the ruby port surfaced in python. A character-class walk cannot
 * have it, and the four {@code #trailing-newline} entries pass here
 * without the port having to know they exist.
 */
public final class Refs {

  private Refs() {}

  public static final int REF_MAX = 1024;

  /** §4: {@code ^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$}, max 1024. */
  public static boolean checkName(Object name) {
    String text = str(name);
    if (null == text || text.isEmpty() || REF_MAX < text.length()) {
      return false;
    }
    char first = text.charAt(0);
    if (!isAlpha(first) && '@' != first) {
      return false;
    }
    for (int i = 1; i < text.length(); i++) {
      char c = text.charAt(i);
      if (!isAlpha(c) && !isDigit(c) && '.' != c && '~' != c && '_' != c && '-' != c && '/' != c) {
        return false;
      }
    }
    return true;
  }

  /**
   * §4: {@code ^[a-zA-Z0-9.~_-]+$}, max 1024, or empty.
   *
   * <p>The asymmetry with a name is deliberate: a tag MAY start with a
   * digit because auto-tagging assigns integer tags ({@code stripe$1}),
   * and a tag admits neither {@code @} nor {@code /} because a name is a
   * package specifier and a tag is not.
   */
  public static boolean checkTag(Object tag) {
    String text = str(tag);
    if (null == text) {
      return false;
    }
    // The empty tag is an ordinary tag (§4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    if (text.isEmpty()) {
      return true;
    }
    if (REF_MAX < text.length()) {
      return false;
    }
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (!isAlpha(c) && !isDigit(c) && '.' != c && '~' != c && '_' != c && '-' != c) {
        return false;
      }
    }
    return true;
  }

  private static boolean isAlpha(char c) {
    return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z');
  }

  private static boolean isDigit(char c) {
    return '0' <= c && c <= '9';
  }

  /**
   * {@code name$tag} -> the pair. Canonicalizing: {@code stripe$} and
   * {@code stripe} both give tag "".
   */
  public static Map<String, Object> parseRef(Object value) {
    String text = str(value);
    if (null == text) {
      fail("plugin_bad_name", "ref must be a string", null);
    }

    // Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
    // in neither character class - so the corpus is the arbiter (§4 rule
    // 5), and it picks the split that blames the part actually at fault:
    // `a$b$c` is a good name with a bad tag, not the reverse.
    int cut = text.indexOf('$');
    String name = cut < 0 ? text : text.substring(0, cut);
    String tag = cut < 0 ? "" : text.substring(cut + 1);

    if (!checkName(name)) {
      fail("plugin_bad_name", "invalid plugin name: " + name, details("name", name));
    }
    if (!checkTag(tag)) {
      fail("plugin_bad_tag", "invalid plugin tag: " + tag, details("name", name, "tag", tag));
    }

    Map<String, Object> out = newmap();
    out.put("name", name);
    out.put("tag", tag);
    return out;
  }

  /**
   * The pair -> {@code name$tag}. An empty tag NEVER writes the separator,
   * which is the half of canonicalization this owns: parse tolerates
   * {@code stripe$}, format never produces it, so a round trip is
   * idempotent.
   */
  public static String formatRef(Object name, Object tag) {
    Object usetag = null == tag ? "" : tag;
    if (!checkName(name)) {
      fail("plugin_bad_name", "invalid plugin name: " + Json.write(name), details("name", name));
    }
    if (!checkTag(usetag)) {
      fail(
          "plugin_bad_tag",
          "invalid plugin tag: " + Json.write(usetag),
          details("name", name, "tag", usetag));
    }
    String text = str(usetag);
    return text.isEmpty() ? str(name) : str(name) + "$" + text;
  }

  /**
   * The canonical spelling of a ref. §4 rule 5: ports must canonicalize
   * before comparison.
   */
  public static String canonRef(Object value) {
    Map<String, Object> parsed = parseRef(value);
    return formatRef(parsed.get("name"), parsed.get("tag"));
  }

  /**
   * canonRef for the internal callers that want the input back unchanged
   * when it is not well formed. NEVER use it where a bad ref must be
   * reported - the corpus pins plugin_bad_name at every public entry.
   */
  public static String canon(String text) {
    try {
      return canonRef(text);
    } catch (PluginException e) {
      return text;
    }
  }

  public static String refname(String text) {
    try {
      return str(parseRef(text).get("name"));
    } catch (PluginException e) {
      return text;
    }
  }
}
