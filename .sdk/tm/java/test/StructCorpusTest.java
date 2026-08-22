package JAVAPACKAGE.sdktest;

// Drives the shared struct corpus (../.sdk/test/test.json, root key "struct")
// against the vendored struct utility, mirroring the go target's
// struct_utility_test.go coverage. Adapted from the voxgig struct java
// port's StructCorpusTest; here the corpus is a green-bar test — any
// failing entry fails the build. Categories absent from this SDK's
// test.json are skipped.

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.function.Function;

import JAVAPACKAGE.utility.struct.Struct;

@SuppressWarnings({"unchecked", "rawtypes"})
public class StructCorpusTest {

  private static final Map<String, StructRunner.Result> SCOREBOARD = new TreeMap<>();

  private static Object getp(Object in, String key) {
    if (in instanceof Map<?, ?> m) {
      return ((Map<String, Object>) m).get(key);
    }
    return null;
  }

  private static Object getpDef(Object in, String key, Object def) {
    if (in instanceof Map<?, ?> m && ((Map<String, Object>) m).containsKey(key)) {
      return ((Map<String, Object>) m).get(key);
    }
    return def;
  }

  @TestFactory
  Iterable<DynamicTest> corpus() {
    List<DynamicTest> tests = new ArrayList<>();

    // ===== minor (29 names) =====
    add(tests, "minor", "isnode", true, in -> Struct.isnode(in));
    add(tests, "minor", "ismap", true, in -> Struct.ismap(in));
    add(tests, "minor", "islist", true, in -> Struct.islist(in));
    add(tests, "minor", "iskey", false, in -> Struct.iskey(in));
    add(tests, "minor", "strkey", false, in -> Struct.strkey(in));
    add(tests, "minor", "isempty", false, in -> Struct.isempty(in));
    add(tests, "minor", "isfunc", true, in -> Struct.isfunc(in));
    add(tests, "minor", "getprop", false, in -> {
      Object val = getp(in, "val");
      Object key = getp(in, "key");
      Object alt = getpDef(in, "alt", Struct.UNDEF);
      return alt == Struct.UNDEF
          ? Struct.getprop(val, key)
          : Struct.getprop(val, key, alt);
    });
    add(tests, "minor", "getelem", false, in -> {
      Object val = getp(in, "val");
      Object key = getp(in, "key");
      Object alt = getpDef(in, "alt", Struct.UNDEF);
      return alt == Struct.UNDEF
          ? Struct.getelem(val, key)
          : Struct.getelem(val, key, alt);
    });
    add(tests, "minor", "clone", false, in -> Struct.clone(in));
    add(tests, "minor", "items", true, in -> Struct.items(in));
    add(tests, "minor", "keysof", true, in -> Struct.keysof(in));
    add(tests, "minor", "haskey", false, in -> Struct.haskey(getp(in, "src"), getp(in, "key")));
    add(tests, "minor", "setprop", true, in -> {
      Object parent = getpDef(in, "parent", Struct.UNDEF);
      Object key = getp(in, "key");
      Object val = getp(in, "val");
      return Struct.setprop(parent == Struct.UNDEF ? null : parent, key, val);
    });
    add(tests, "minor", "delprop", true, in -> {
      Object parent = getpDef(in, "parent", Struct.UNDEF);
      Object key = getp(in, "key");
      return Struct.delprop(parent == Struct.UNDEF ? null : parent, key);
    });
    add(tests, "minor", "stringify", false, in -> {
      // null:false keeps a JSON-null val as a real null (rendered "null"); an
      // absent val is UNDEF (rendered ""). Mirrors the canonical harness.
      Object val = getpDef(in, "val", Struct.UNDEF);
      Object max = getp(in, "max");
      Integer m = max instanceof Number n ? n.intValue() : null;
      return Struct.stringify(val, m);
    });
    add(tests, "minor", "jsonify", false, in -> {
      Object val = getp(in, "val");
      Object flags = getp(in, "flags");
      return Struct.jsonify(val, flags);
    });
    add(tests, "minor", "pathify", false, in -> {
      // null:false keeps a JSON-null path as a real null ("<unknown-path:null>")
      // and an absent path as UNDEF ("<unknown-path>"); null parts are dropped.
      Object path = getpDef(in, "path", Struct.UNDEF);
      Object from = getp(in, "from");
      Object to = getp(in, "to");
      return Struct.pathify(path, from, to);
    });
    add(tests, "minor", "escre", true, in -> Struct.escre(in));
    add(tests, "minor", "escurl", true, in -> Struct.escurl(in));
    add(tests, "minor", "join", false, in -> {
      Object val = getp(in, "val");
      Object sep = getp(in, "sep");
      Object url = getp(in, "url");
      return Struct.join(val, sep, url);
    });
    add(tests, "minor", "flatten", true, in -> {
      Object val = getp(in, "val");
      Object depth = getp(in, "depth");
      Integer d = depth instanceof Number n ? n.intValue() : null;
      return Struct.flatten(val, d == null ? 1 : d);
    });
    add(tests, "minor", "filter", true, in -> {
      Object val = getp(in, "val");
      String check = Objects.toString(getp(in, "check"), "");
      Struct.ItemCheck pred = "gt3".equals(check)
          ? (Struct.ItemCheck) item -> {
            Object v = item.get(1);
            return v instanceof Number n && n.doubleValue() > 3;
          }
          : (Struct.ItemCheck) item -> {
            Object v = item.get(1);
            return v instanceof Number n && n.doubleValue() < 3;
          };
      return Struct.filter(val, pred);
    });
    add(tests, "minor", "typename", true, in -> Struct.typename(in));
    add(tests, "minor", "typify", false, in -> Struct.typify(in));
    add(tests, "minor", "size", false, in -> Struct.size(in));
    add(tests, "minor", "slice", false, in -> {
      Object val = getp(in, "val");
      Object start = getp(in, "start");
      Object end = getp(in, "end");
      return Struct.slice(val, start, end);
    });
    add(tests, "minor", "pad", false, in -> {
      Object val = getp(in, "val");
      Object pad = getp(in, "pad");
      Object pc = getp(in, "char");
      return Struct.pad(val, pad, pc);
    });
    add(tests, "minor", "setpath", false, in -> {
      Object store = getp(in, "store");
      Object path = getp(in, "path");
      Object val = getp(in, "val");
      return Struct.setpath(store, path, val);
    });

    // ===== walk =====
    add(tests, "walk", "basic", true, in -> Struct.walk(in,
        (k, v, p, t) -> v instanceof String s ? s + "~" + String.join(".", t) : v));
    add(tests, "walk", "depth", false, in -> {
      Object src = getp(in, "src");
      Object md = getp(in, "maxdepth");
      int maxdepth = md instanceof Number n ? n.intValue() : 32;
      Object[] top = new Object[1];
      Object[] cur = new Object[1];
      Struct.WalkApply copy =
          (key, val, parent, path) -> {
            if (key == null || Struct.isnode(val)) {
              Object child =
                  Struct.islist(val) ? new ArrayList<Object>() : new LinkedHashMap<String, Object>();
              if (key == null) {
                top[0] = child;
                cur[0] = child;
              } else {
                Struct.setprop(cur[0], key, child);
                cur[0] = child;
              }
            } else {
              Struct.setprop(cur[0], key, val);
            }
            return val;
          };
      Struct.walk(src, copy, null, maxdepth);
      return top[0];
    });
    add(tests, "walk", "copy", true, in -> {
      Object[] cur = new Object[64];
      Struct.WalkApply walkcopy =
          (key, val, parent, path) -> {
            if (key == null) {
              cur[0] =
                  Struct.ismap(val)
                      ? new LinkedHashMap<String, Object>()
                      : Struct.islist(val) ? new ArrayList<Object>() : val;
              return val;
            }
            Object v = val;
            int i = path.size();
            if (Struct.isnode(v)) {
              v =
                  Struct.ismap(v)
                      ? new LinkedHashMap<String, Object>()
                      : new ArrayList<Object>();
              cur[i] = v;
            }
            Struct.setprop(cur[i - 1], key, v);
            return val;
          };
      Struct.walk(in, walkcopy);
      return cur[0];
    });

    // ===== merge =====
    add(tests, "merge", "cases", true, in -> Struct.merge(in));
    add(tests, "merge", "array", true, in -> Struct.merge(in));
    add(tests, "merge", "integrity", true, in -> Struct.merge(in));
    add(tests, "merge", "depth", true, in -> {
      Object val = getp(in, "val");
      Object depth = getp(in, "depth");
      int d = depth instanceof Number n ? n.intValue() : 32;
      return Struct.merge(val, d);
    });

    // ===== getpath =====
    add(tests, "getpath", "basic", true, in -> Struct.getpath(getp(in, "store"), getp(in, "path")));
    add(tests, "getpath", "relative", true, in -> {
      Map<String, Object> inj = new LinkedHashMap<>();
      if (in instanceof Map<?, ?> m) {
        Map<String, Object> mm = (Map<String, Object>) m;
        if (mm.containsKey("dparent")) inj.put("dparent", mm.get("dparent"));
        if (mm.containsKey("dpath")) inj.put("dpath", mm.get("dpath"));
        if (mm.containsKey("base")) inj.put("base", mm.get("base"));
      }
      return Struct.getpath(getp(in, "store"), getp(in, "path"), inj.isEmpty() ? null : inj);
    });
    add(tests, "getpath", "special", true, in -> {
      Object inj = getp(in, "inj");
      Map<String, Object> injMap = inj instanceof Map<?, ?> m ? (Map<String, Object>) m : null;
      return Struct.getpath(getp(in, "store"), getp(in, "path"), injMap);
    });

    // ===== inject =====
    // inject.string passes the nullModifier so a resolved JSON null (encoded by
    // the runner's fixJSON as "__NULL__") renders as the literal text "null".
    add(tests, "inject", "string", true, in -> {
      Map<String, Object> opts = new LinkedHashMap<>();
      opts.put("modify", StructRunner.NULL_MODIFIER);
      return Struct.inject(getp(in, "val"), getp(in, "store"), opts);
    });
    add(tests, "inject", "deep", true, in -> Struct.inject(getp(in, "val"), getp(in, "store")));

    // ===== transform =====
    add(tests, "transform", "paths", true, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "cmds", true, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "each", true, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "pack", true, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "modify", true, in -> {
      Map<String, Object> opts = new LinkedHashMap<>();
      // Match JS test guard: only mutate string leaves.
      opts.put(
          "modify",
          (Struct.Modify)
              (val, key, parent, inj, store) -> {
                if (key != null && parent instanceof Map<?, ?> m && val instanceof String s) {
                  ((Map<String, Object>) m).put(Objects.toString(key), "@" + s);
                }
              });
      return Struct.transform(getp(in, "data"), getp(in, "spec"), opts);
    });
    add(tests, "transform", "ref", true, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "format", false, in -> Struct.transform(getp(in, "data"), getp(in, "spec")));
    add(tests, "transform", "apply", true, in -> {
      Map<String, Object> opts = new LinkedHashMap<>();
      Map<String, Object> extra = new LinkedHashMap<>();
      extra.put(
          "apply",
          (Function<Object, Object>) v -> v instanceof String s ? s.toUpperCase(Locale.ROOT) : v);
      opts.put("extra", extra);
      return Struct.transform(getp(in, "data"), getp(in, "spec"), opts);
    });

    // ===== validate =====
    add(tests, "validate", "basic", false, in -> Struct.validate(getp(in, "data"), getp(in, "spec")));
    add(tests, "validate", "child", true, in -> Struct.validate(getp(in, "data"), getp(in, "spec")));
    add(tests, "validate", "one", true, in -> Struct.validate(getp(in, "data"), getp(in, "spec")));
    add(tests, "validate", "exact", true, in -> Struct.validate(getp(in, "data"), getp(in, "spec")));
    add(tests, "validate", "invalid", false, in -> Struct.validate(getp(in, "data"), getp(in, "spec")));
    add(tests, "validate", "special", true, in -> {
      Map<String, Object> inj = null;
      if (in instanceof Map<?, ?> m) {
        Object injObj = ((Map<String, Object>) m).get("inj");
        if (injObj instanceof Map<?, ?> im) {
          inj = (Map<String, Object>) im;
        }
      }
      return Struct.validate(getp(in, "data"), getp(in, "spec"), inj);
    });

    // ===== select =====
    add(tests, "select", "basic", true, in -> Struct.select(getp(in, "obj"), getp(in, "query")));
    add(tests, "select", "operators", true, in -> Struct.select(getp(in, "obj"), getp(in, "query")));
    add(tests, "select", "edge", true, in -> Struct.select(getp(in, "obj"), getp(in, "query")));
    add(tests, "select", "alts", true, in -> Struct.select(getp(in, "obj"), getp(in, "query")));

    return tests;
  }

  private void add(
      List<DynamicTest> tests,
      String category,
      String name,
      boolean nullFlag,
      StructRunner.Subject subject) {
    tests.add(
        DynamicTest.dynamicTest(
            category + "-" + name,
            () -> {
              Map<String, Object> spec = StructRunner.getSpec(category, name);
              if (spec == null) {
                // Category/name absent from this SDK's corpus: skip.
                return;
              }
              StructRunner.Result r =
                  StructRunner.runsetflags(category + "." + name, spec, nullFlag, subject);
              SCOREBOARD.put(category + "." + name, r);
              if (!r.failures.isEmpty()) {
                throw new AssertionError(
                    category + "." + name + ": " + r.passed + "/" + r.total
                        + " passed; failures:\n  " + String.join("\n  ", r.failures));
              }
            }));
  }

  @AfterAll
  static void printScoreboard() {
    int totalP = 0;
    int totalT = 0;
    StringBuilder banner = new StringBuilder();
    banner.append("\n========= STRUCT CORPUS SCOREBOARD =========\n");
    for (Map.Entry<String, StructRunner.Result> e : SCOREBOARD.entrySet()) {
      StructRunner.Result r = e.getValue();
      banner.append(String.format("  %-30s %4d / %4d%n", e.getKey(), r.passed, r.total));
      totalP += r.passed;
      totalT += r.total;
    }
    banner.append(String.format("  %-30s %4d / %4d%n", "TOTAL", totalP, totalT));
    banner.append("============================================\n");
    System.out.println(banner);
  }
}
