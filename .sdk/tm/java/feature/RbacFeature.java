package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;

// Client-side role/permission enforcement. Before an operation resolves its
// endpoint, the required permission for that entity+operation is checked
// against the permissions the client holds; a disallowed call is
// short-circuited with an `rbac_denied` error (via ctx.out["point"], which
// makePoint surfaces) and never touches the network. Required permissions
// come from `rules` (keyed by `<entity>.<op>`, `<op>`, or `*`); the default
// when no rule matches is controlled by `deny` (default: allow when
// unspecified). Held permissions are the `permissions` list (a `*` grants
// everything).
public class RbacFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private Map<String, Boolean> granted = new LinkedHashMap<>();

  // Activity tracking (mirrors the ts client._rbac record).
  public int allowed = 0;
  public int denied = 0;
  public Map<String, Object> last;

  public RbacFeature() {
    super("rbac", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    this.granted = new LinkedHashMap<>();
    List<String> permissions = FeatureOptions.foptStrList(this.options, "permissions");
    if (permissions != null) {
      for (String p : permissions) {
        this.granted.put(p, true);
      }
    }
  }

  @Override
  public void prePoint(Context ctx) {
    if (!this.active) {
      return;
    }

    String required = required(ctx);
    if (required == null) {
      // No rule: honour the default policy.
      if (FeatureOptions.foptBool(this.options, "deny", false)) {
        reject(ctx, "<default-deny>");
      }
      return;
    }

    if (Boolean.TRUE.equals(this.granted.get("*"))
        || Boolean.TRUE.equals(this.granted.get(required))) {
      track(ctx, required, true);
      return;
    }

    reject(ctx, required);
  }

  private String required(Context ctx) {
    Map<String, Object> rules = FeatureOptions.foptMap(this.options, "rules");
    if (rules == null) {
      return null;
    }

    String entity = "";
    if (ctx.entity != null) {
      entity = ctx.entity.getName();
    }
    else if (ctx.op != null) {
      entity = ctx.op.entity;
    }
    String opname = "";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }

    for (String key : new String[] { entity + "." + opname, opname, "*" }) {
      Object r = rules.get(key);
      if (r instanceof String) {
        return (String) r;
      }
    }
    return null;
  }

  private void reject(Context ctx, String required) {
    track(ctx, required, false);

    String opname = "?";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }
    RuntimeException err = ctx.makeError("rbac_denied",
        "Permission \"" + required + "\" required for operation \"" + opname + "\"");

    // Short-circuit endpoint resolution; makePoint surfaces this error
    // before any network activity.
    ctx.out.put("point", err);
  }

  private void track(Context ctx, String required, boolean wasAllowed) {
    if (wasAllowed) {
      this.allowed++;
    }
    else {
      this.denied++;
    }
    String opname = "";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }
    Map<String, Object> rec = new LinkedHashMap<>();
    rec.put("required", required);
    rec.put("allowed", wasAllowed);
    rec.put("op", opname);
    this.last = rec;
  }
}
