package JAVAPACKAGE.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.utility.struct.Struct;

/** A single endpoint definition (typed view over a point map). */
@SuppressWarnings({"unchecked"})
public class Point {

  public Map<String, Object> args;
  public Map<String, Object> rename;
  public String method = "";
  public String orig = "";
  public List<Object> parts = new ArrayList<>();
  public List<Object> params;
  public Map<String, Object> select;
  // Absent in config means ACTIVE: emission drops `active: true` as a
  // default (sdkgen L0), so only an explicit `active: false` turns a point off.
  public boolean active = true;
  public List<Object> relations;
  public Map<String, Object> alias = new LinkedHashMap<>();
  public Map<String, Object> transform = new LinkedHashMap<>();

  public Point(Map<String, Object> pointmap) {
    Object v = Struct.getprop(pointmap, "args");
    if (v instanceof Map) {
      this.args = (Map<String, Object>) v;
    }
    if (this.args == null) {
      this.args = new LinkedHashMap<>();
      this.args.put("params", new ArrayList<>());
    }

    v = Struct.getprop(pointmap, "rename");
    if (v instanceof Map) {
      this.rename = (Map<String, Object>) v;
    }
    if (this.rename == null) {
      this.rename = new LinkedHashMap<>();
      this.rename.put("params", new LinkedHashMap<>());
    }

    v = Struct.getprop(pointmap, "method");
    if (v instanceof String) {
      this.method = (String) v;
    }

    v = Struct.getprop(pointmap, "orig");
    if (v instanceof String) {
      this.orig = (String) v;
    }

    v = Struct.getprop(pointmap, "parts");
    if (v instanceof List) {
      this.parts = (List<Object>) v;
    }

    v = Struct.getprop(pointmap, "params");
    if (v instanceof List) {
      this.params = (List<Object>) v;
    }

    v = Struct.getprop(pointmap, "select");
    if (v instanceof Map) {
      this.select = (Map<String, Object>) v;
    }

    v = Struct.getprop(pointmap, "active");
    if (v instanceof Boolean) {
      this.active = (Boolean) v;
    }

    v = Struct.getprop(pointmap, "relations");
    if (v instanceof List) {
      this.relations = (List<Object>) v;
    }

    v = Struct.getprop(pointmap, "alias");
    if (v instanceof Map) {
      this.alias = (Map<String, Object>) v;
    }

    v = Struct.getprop(pointmap, "transform");
    if (v instanceof Map) {
      this.transform = (Map<String, Object>) v;
    }
  }
}
