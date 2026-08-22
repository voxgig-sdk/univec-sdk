package JAVAPACKAGE.core;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** The resolved HTTP request specification for one operation. */
@SuppressWarnings({"unchecked"})
public class Spec {

  public List<Object> parts;
  public Map<String, Object> headers = new LinkedHashMap<>();
  public Map<String, Object> alias = new LinkedHashMap<>();
  public String base = "";
  public String prefix = "";
  public String suffix = "";
  public Map<String, Object> params = new LinkedHashMap<>();
  public Map<String, Object> query = new LinkedHashMap<>();
  public String step = "";
  public String method = "GET";
  public Object body;
  public String url = "";
  public String path = "";

  public Spec() {}

  public Spec(Map<String, Object> specmap) {
    if (specmap == null) {
      return;
    }

    Object v = specmap.get("parts");
    if (v instanceof List) {
      this.parts = (List<Object>) v;
    }
    v = specmap.get("headers");
    if (v instanceof Map) {
      this.headers = (Map<String, Object>) v;
    }
    v = specmap.get("alias");
    if (v instanceof Map) {
      this.alias = (Map<String, Object>) v;
    }
    v = specmap.get("base");
    if (v instanceof String) {
      this.base = (String) v;
    }
    v = specmap.get("prefix");
    if (v instanceof String) {
      this.prefix = (String) v;
    }
    v = specmap.get("suffix");
    if (v instanceof String) {
      this.suffix = (String) v;
    }
    v = specmap.get("params");
    if (v instanceof Map) {
      this.params = (Map<String, Object>) v;
    }
    v = specmap.get("query");
    if (v instanceof Map) {
      this.query = (Map<String, Object>) v;
    }
    v = specmap.get("step");
    if (v instanceof String) {
      this.step = (String) v;
    }
    v = specmap.get("method");
    if (v instanceof String) {
      this.method = (String) v;
    }
    if (specmap.containsKey("body")) {
      this.body = specmap.get("body");
    }
    v = specmap.get("url");
    if (v instanceof String) {
      this.url = (String) v;
    }
    v = specmap.get("path");
    if (v instanceof String) {
      this.path = (String) v;
    }
  }
}
