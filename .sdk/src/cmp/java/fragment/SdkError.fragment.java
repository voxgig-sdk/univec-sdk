package JAVAPACKAGE.core;

/**
 * ProjectName SDK error. Carries the SDK error code, the operation
 * context, and cleaned copies of the result and spec at failure time.
 */
public class SdkError extends RuntimeException {

  public final String sdk = "ProjectName";
  public String code;
  public String msg;
  public transient Context ctx;
  public transient Object result;
  public transient Object spec;

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

  @Override
  public String getMessage() {
    return this.msg;
  }
}
