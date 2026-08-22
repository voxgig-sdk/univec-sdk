package JAVAPACKAGE.core;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.utility.struct.Struct;

/** A resolved entity operation (name, input kind, endpoint definitions). */
@SuppressWarnings({"unchecked"})
public class Operation {

  public String entity = "_";
  public String name = "_";
  public String input = "_";
  public List<Map<String, Object>> points = new ArrayList<>();
  public Map<String, Object> alias;

  public Operation(Map<String, Object> opmap) {
    Object v = Struct.getprop(opmap, "entity");
    if (v instanceof String && !"".equals(v)) {
      this.entity = (String) v;
    }
    v = Struct.getprop(opmap, "name");
    if (v instanceof String && !"".equals(v)) {
      this.name = (String) v;
    }
    v = Struct.getprop(opmap, "input");
    if (v instanceof String && !"".equals(v)) {
      this.input = (String) v;
    }

    Object rawPoints = Struct.getprop(opmap, "points");
    if (rawPoints instanceof List) {
      for (Object t : (List<Object>) rawPoints) {
        if (t instanceof Map) {
          this.points.add((Map<String, Object>) t);
        }
      }
    }

    Object rawAlias = Struct.getprop(opmap, "alias");
    if (rawAlias instanceof Map) {
      this.alias = (Map<String, Object>) rawAlias;
    }
  }
}
