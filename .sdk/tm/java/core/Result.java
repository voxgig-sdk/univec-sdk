package JAVAPACKAGE.core;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Supplier;

import JAVAPACKAGE.utility.struct.Struct;

/** The processed outcome of one operation. */
@SuppressWarnings({"unchecked"})
public class Result {

  public boolean ok = false;
  public int status = -1;
  public String statusText = "";
  public Map<String, Object> headers = new LinkedHashMap<>();
  public Object body;
  public RuntimeException err;
  public Object resdata;
  public Map<String, Object> resmatch;

  // Feature extensions: pagination signals (paging feature) and the
  // incremental item iterator (streaming feature).
  public Map<String, Object> paging;
  public boolean streaming = false;
  public Supplier<Iterator<Object>> stream;

  public Result(Map<String, Object> resmap) {
    Object o = Struct.getprop(resmap, "ok");
    if (o instanceof Boolean) {
      this.ok = (Boolean) o;
    }

    Object s = Struct.getprop(resmap, "status");
    if (s != null) {
      this.status = Helpers.toInt(s);
    }

    Object st = Struct.getprop(resmap, "statusText");
    if (st instanceof String) {
      this.statusText = (String) st;
    }

    Object h = Struct.getprop(resmap, "headers");
    if (h instanceof Map) {
      this.headers = (Map<String, Object>) h;
    }

    this.body = Struct.getprop(resmap, "body", null);

    Object e = Struct.getprop(resmap, "err");
    if (e instanceof RuntimeException) {
      this.err = (RuntimeException) e;
    }

    this.resdata = Struct.getprop(resmap, "resdata", null);

    Object rm = Struct.getprop(resmap, "resmatch");
    if (rm instanceof Map) {
      this.resmatch = (Map<String, Object>) rm;
    }
  }
}
