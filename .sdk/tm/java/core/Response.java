package JAVAPACKAGE.core;

import java.util.Map;
import java.util.function.Supplier;

import JAVAPACKAGE.utility.struct.Struct;

/** A transport-level response (thin wrapper over the fetcher's map shape). */
public class Response {

  public int status = -1;
  public String statusText = "";
  public Object headers;
  public Supplier<Object> jsonFunc;
  public Object body;
  public RuntimeException err;

  public Response(Map<String, Object> resmap) {
    Object s = Struct.getprop(resmap, "status");
    if (s != null) {
      this.status = Helpers.toInt(s);
    }

    Object st = Struct.getprop(resmap, "statusText");
    if (st instanceof String) {
      this.statusText = (String) st;
    }

    this.headers = Struct.getprop(resmap, "headers", null);

    Object jf = Struct.getprop(resmap, "json");
    if (jf instanceof Supplier) {
      this.jsonFunc = castSupplier(jf);
    }

    this.body = Struct.getprop(resmap, "body", null);

    Object e = Struct.getprop(resmap, "err");
    if (e instanceof RuntimeException) {
      this.err = (RuntimeException) e;
    }
  }

  @SuppressWarnings("unchecked")
  private static Supplier<Object> castSupplier(Object jf) {
    return (Supplier<Object>) jf;
  }
}
