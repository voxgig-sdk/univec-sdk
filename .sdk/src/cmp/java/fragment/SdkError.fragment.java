package JAVAPACKAGE.core;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.utility.struct.Struct;

/**
 * ProjectName SDK error. Carries the SDK error code, the operation
 * context, and cleaned copies of the result and spec at failure time.
 */
public class SdkError extends RuntimeException {

  public final String sdk = "ProjectName";
  public String code;
  public String msg;
  public Object result;
  public Object spec;

  // Reachable for a debugger, invisible to a serialiser: the context holds
  // the live spec and options, and an error is what gets logged. Private,
  // so a reflective walk of the public fields never reaches it.
  private transient Context ctx;

  /**
   * HTTP status of the response that caused this error, or -1 when the
   * request never got one. PROMOTED to the top level: it used to be
   * reachable only at `err.result.status`, so every consumer coupled itself
   * to the internal shape of `result`.
   */
  public int status = -1;

  public boolean notFound() {
    return 404 == this.status;
  }

  public SdkError(String code, String msg, Context ctx) {
    super(msg);
    this.code = code == null ? "" : code;
    this.msg = msg;
    this.ctx = ctx;
  }

  /** The operation context at failure time, for a debugger; never printed. */
  public Context ctx() {
    return this.ctx;
  }

  @Override
  public String getMessage() {
    return this.msg;
  }

  /** What makeError attached is already cleaned; the context is not part of the record. */
  public Map<String, Object> toMap() {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("sdk", this.sdk);
    out.put("code", this.code);
    out.put("message", this.msg);
    out.put("status", this.status);
    out.put("result", this.result);
    out.put("spec", this.spec);
    return out;
  }

  @Override
  public String toString() {
    return "ProjectNameSDK error [" + this.code + "] " + this.msg
        + " (status " + this.status + ")"
        + (this.spec == null ? "" : " spec=" + Struct.jsonify(this.spec, Map.of("indent", 0)));
  }
}
