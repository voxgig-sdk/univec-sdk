package JAVAPACKAGE.sdktest;

// Vendored from the voxgig struct java port's test Runner (src/test/Runner.java),
// adapted for this SDK: the corpus comes from ../.sdk/test/test.json (root key
// "struct"), and JSON handling uses the SDK's zero-dep Json/Struct utilities
// instead of Gson.

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;

import JAVAPACKAGE.utility.Json;
import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked", "rawtypes"})
public class StructRunner {
  public static final String NULLMARK = "__NULL__";
  public static final String UNDEFMARK = "__UNDEF__";
  public static final String EXISTSMARK = "__EXISTS__";

  private static volatile Map<String, Object> CORPUS;

  private StructRunner() {}

  public static synchronized Map<String, Object> loadCorpus() {
    if (CORPUS == null) {
      try {
        Path p = Path.of("..", ".sdk", "test", "test.json");
        String json = Files.readString(p);
        CORPUS = (Map<String, Object>) Json.parse(json);
      }
      catch (Exception e) {
        throw new AssertionError("Failed to load struct corpus: " + e.getMessage(), e);
      }
    }
    return CORPUS;
  }

  public static Map<String, Object> getSpec(String category, String name) {
    Map<String, Object> all = loadCorpus();
    Map<String, Object> struct = (Map<String, Object>) all.get("struct");
    if (struct == null) {
      return null;
    }
    Map<String, Object> cat = (Map<String, Object>) struct.get(category);
    if (cat == null) {
      return null;
    }
    return (Map<String, Object>) cat.get(name);
  }

  /** Drives a {@code subject} against a test set; collects per-entry pass/fail. */
  @FunctionalInterface
  public interface Subject {
    Object apply(Object in) throws Exception;
  }

  public static class Result {
    public final String name;
    public int passed;
    public int total;
    public final List<String> failures = new ArrayList<>();

    public Result(String name) {
      this.name = name;
    }

    @Override
    public String toString() {
      return name + ": " + passed + "/" + total;
    }
  }

  public static Result runset(String fullName, Map<String, Object> testspec, Subject subject) {
    return runsetflags(fullName, testspec, true, subject);
  }

  public static Result runsetflags(
      String fullName, Map<String, Object> testspec, boolean nullFlag, Subject subject) {
    Result res = new Result(fullName);
    Object setObj = testspec == null ? null : testspec.get("set");
    if (!(setObj instanceof List<?> set)) {
      return res;
    }

    for (int i = 0; i < set.size(); i++) {
      Object eo = set.get(i);
      if (!(eo instanceof Map<?, ?> em)) {
        continue;
      }
      Map<String, Object> entry = (Map<String, Object>) em;

      Object in =
          entry.containsKey("in")
              ? Struct.clone(entry.get("in"))
              : Struct.UNDEF;
      Object expected =
          entry.containsKey("out")
              ? entry.get("out")
              : (nullFlag ? null : Struct.UNDEF);

      // NULLMARK convention (mirrors js runner fixJSON): when nullFlag is set,
      // every JSON null in the input and expected output is encoded as the
      // sentinel string "__NULL__", and the function result is encoded the same
      // way before comparison. This preserves the null-vs-absent distinction
      // across the round-trip exactly as the canonical cross-port runner does.
      if (nullFlag) {
        // Only encode a *present* input; an absent `in` stays UNDEF so the
        // subject sees "undefined" (matches the canonical runner, which clones
        // the absent value rather than a null marker).
        if (entry.containsKey("in")) {
          in = fixJSON(in);
        }
        expected = fixJSON(expected);
      }

      res.total++;
      try {
        Object got = subject.apply(in);
        if (nullFlag) {
          got = fixJSON(got);
        }

        if (entry.containsKey("err")) {
          res.failures.add(
              String.format(
                  "[%d] expected err='%s' but call returned %s",
                  i, brief(entry.get("err")), brief(got)));
          continue;
        }

        if (deepEqual(got, expected)) {
          res.passed++;
        }
        else {
          res.failures.add(
              String.format(
                  "[%d] in=%s expected=%s got=%s",
                  i, brief(entry.get("in")), brief(expected), brief(got)));
        }
      }
      catch (Exception ex) {
        if (entry.containsKey("err")) {
          // Accept any thrown error when err is true, or substring match otherwise.
          Object expErr = entry.get("err");
          String msg = ex.getMessage() == null ? "" : ex.getMessage();
          if (Boolean.TRUE.equals(expErr)
              || (expErr instanceof String es
                  && (es.isEmpty() || msg.contains(es)
                      || msg.toLowerCase().contains(es.toLowerCase())))) {
            res.passed++;
          }
          else {
            res.failures.add(
                String.format(
                    "[%d] err mismatch: expected '%s' got '%s'", i, brief(expErr), msg));
          }
        }
        else {
          res.failures.add(
              String.format(
                  "[%d] in=%s threw=%s", i, brief(entry.get("in")), ex.getMessage()));
        }
      }
    }
    return res;
  }

  /** Normalize then deep-equal. Treats {@link Struct#UNDEF} as {@code null}. */
  public static boolean deepEqual(Object a, Object b) {
    return Objects.equals(normalize(a), normalize(b));
  }

  /**
   * Encode JSON null (and the {@link Struct#UNDEF} "no value" sentinel) as the
   * {@link #NULLMARK} string throughout a cloned structure. Mirrors
   * {@code fixJSON} in js/test/runner.js when {@code flags.null} is true.
   */
  public static Object fixJSON(Object v) {
    if (v == null || v == Struct.UNDEF) {
      return NULLMARK;
    }
    if (v instanceof Map<?, ?> m) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<?, ?> e : m.entrySet()) {
        out.put(Objects.toString(e.getKey()), fixJSON(e.getValue()));
      }
      return out;
    }
    if (v instanceof List<?> l) {
      List<Object> out = new ArrayList<>(l.size());
      for (Object x : l) {
        out.add(fixJSON(x));
      }
      return out;
    }
    return v;
  }

  /**
   * Modify callback mirroring {@code nullModifier} in js/test/runner.js: a bare
   * {@link #NULLMARK} becomes a real null, and an embedded {@link #NULLMARK}
   * inside a larger string is rewritten to the literal text {@code "null"}.
   */
  public static final Struct.Modify NULL_MODIFIER =
      (val, key, parent, inj, store) -> {
        if (!(val instanceof String s)) {
          return;
        }
        Object repl;
        if (NULLMARK.equals(s)) {
          repl = null;
        }
        else if (s.contains(NULLMARK)) {
          repl = s.replace(NULLMARK, "null");
        }
        else {
          return;
        }
        if (parent instanceof Map<?, ?> m) {
          ((Map<String, Object>) m).put(Objects.toString(key), repl);
        }
        else if (parent instanceof List<?> l && key instanceof Number n) {
          ((List<Object>) l).set(n.intValue(), repl);
        }
      };

  /**
   * Canonicalize a value for comparison:
   * numbers to Long/Double, maps to sorted TreeMap, lists recurse,
   * {@link Struct#UNDEF} treated as {@code null}.
   */
  public static Object normalize(Object v) {
    if (v == Struct.UNDEF || v == null) {
      return null;
    }
    if (v instanceof Number n) {
      double d = n.doubleValue();
      if (Double.isFinite(d) && Math.floor(d) == d) {
        return (long) d;
      }
      return d;
    }
    if (v instanceof Boolean || v instanceof String) {
      return v;
    }
    if (v instanceof Map<?, ?> m) {
      Map<String, Object> out = new TreeMap<>();
      for (Map.Entry<?, ?> e : m.entrySet()) {
        out.put(Objects.toString(e.getKey(), ""), normalize(e.getValue()));
      }
      return out;
    }
    if (v instanceof List<?> l) {
      List<Object> out = new ArrayList<>(l.size());
      for (Object x : l) {
        out.add(normalize(x));
      }
      return out;
    }
    return v.toString();
  }

  private static String brief(Object v) {
    if (v == Struct.UNDEF) {
      return UNDEFMARK;
    }
    try {
      String s = Struct.jsonify(v);
      return s.length() > 200 ? s.substring(0, 197) + "..." : s;
    }
    catch (Exception e) {
      return Objects.toString(v);
    }
  }
}
