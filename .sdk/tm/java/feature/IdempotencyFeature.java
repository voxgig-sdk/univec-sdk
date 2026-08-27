package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Spec;

// Idempotency keys for mutating operations. Adds an `Idempotency-Key`
// header (name configurable via `header`) to unsafe requests so a server
// can de-duplicate retried writes. The key is set once, at PreRequest,
// before the request is built — so it is stable across transport-level
// retries of the same call. A caller-supplied header is never overwritten
// (case-insensitive). The key generator is injectable (`keygen`).
@SuppressWarnings({"unchecked"})
public class IdempotencyFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._idempotency record).
  public int issued = 0;
  public String last = "";

  public IdempotencyFeature() {
    super("idempotency", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
  }

  @Override
  public void preRequest(Context ctx) {
    if (!this.active) {
      return;
    }

    Spec spec = ctx.spec;
    if (spec == null) {
      return;
    }

    if (!mutating(ctx)) {
      return;
    }

    String header = FeatureOptions.foptStr(this.options, "header", "Idempotency-Key");
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap<>();
    }

    // Respect a key the caller already provided.
    if (FeatureOptions.fheaderHas(spec.headers, header)) {
      return;
    }

    String key = genkey();
    spec.headers.put(header, key);

    this.issued++;
    this.last = key;
  }

  private boolean mutating(Context ctx) {
    List<String> methods = FeatureOptions.foptStrList(this.options, "methods");
    if (methods == null) {
      methods = List.of("POST", "PUT", "PATCH", "DELETE");
    }
    String method = "";
    if (ctx.spec != null) {
      method = ctx.spec.method.toUpperCase();
    }
    if (!"".equals(method)) {
      for (String m : methods) {
        if (m.toUpperCase().equals(method)) {
          return true;
        }
      }
    }

    String opname = "";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }
    List<String> ops = FeatureOptions.foptStrList(this.options, "ops");
    if (ops == null) {
      ops = List.of("create", "update", "remove");
    }
    for (String o : ops) {
      if (o.equals(opname)) {
        return true;
      }
    }
    return false;
  }

  private String genkey() {
    if (this.options.get("keygen") instanceof Supplier) {
      return String.valueOf(((Supplier<Object>) this.options.get("keygen")).get());
    }
    ThreadLocalRandom r = ThreadLocalRandom.current();
    String key = String.format("%06x%06x%06x%06x",
        r.nextInt(0x1000000), r.nextInt(0x1000000),
        r.nextInt(0x1000000), r.nextInt(0x1000000));
    return key.substring(0, 24);
  }
}
