package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;

// Audit trail. Emits a structured record for every operation — who (actor),
// what (entity + op), the outcome, and a correlation id — suitable for
// compliance logging. Records accumulate on the feature (bounded by `max`,
// default 1000) and, when a `sink` callback is supplied, are also pushed to
// it (e.g. to forward to a SIEM). The actor is the per-call ctrl actor,
// falling back to the options `actor`, then "anonymous". Each operation is
// audited exactly once (the per-context marker in ctx.out prevents a
// PreDone + PreUnexpected double-log). Timestamps use the injectable `now`
// clock so tests stay deterministic.
@SuppressWarnings({"unchecked"})
public class AuditFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private int seq = 0;

  // Activity tracking (mirrors the ts client._audit record).
  public List<Map<String, Object>> records = new ArrayList<>();

  private static final String AUDIT_SEEN_KEY = "audit_seen";

  public AuditFeature() {
    super("audit", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
    this.seq = 0;
  }

  @Override
  public void preDone(Context ctx) {
    // Outcome reflects the actual result; a non-2xx reaches PreDone before
    // the pipeline errors.
    String outcome = "error";
    if (ctx.result != null && ctx.result.ok && ctx.result.err == null) {
      outcome = "ok";
    }
    emit(ctx, outcome);
  }

  @Override
  public void preUnexpected(Context ctx) {
    emit(ctx, "error");
  }

  private void emit(Context ctx, String outcome) {
    if (!this.active) {
      return;
    }

    // One record per operation (PreDone + a following PreUnexpected on a
    // failure must not double-log).
    if (Boolean.TRUE.equals(ctx.out.get(AUDIT_SEEN_KEY))) {
      return;
    }
    ctx.out.put(AUDIT_SEEN_KEY, true);

    this.seq++;

    String actor = "anonymous";
    String optActor = FeatureOptions.foptStr(this.options, "actor", "");
    if (!"".equals(optActor)) {
      actor = optActor;
    }
    if (ctx.ctrl != null && ctx.ctrl.actor != null && !"".equals(ctx.ctrl.actor)) {
      actor = ctx.ctrl.actor;
    }

    String entity = "_";
    String opname = "_";
    if (ctx.op != null) {
      entity = ctx.op.entity;
      opname = ctx.op.name;
    }

    Map<String, Object> record = new LinkedHashMap<>();
    record.put("seq", this.seq);
    record.put("ts", FeatureOptions.foptNow(this.options).getAsLong());
    record.put("actor", actor);
    record.put("entity", entity);
    record.put("op", opname);
    record.put("outcome", outcome);
    record.put("correlationId", ctx.id);
    if (ctx.result != null) {
      record.put("status", ctx.result.status);
    }

    this.records.add(record);
    int max = FeatureOptions.foptInt(this.options, "max", 1000);
    while (this.records.size() > max) {
      this.records.remove(0);
    }

    if (this.options.get("sink") instanceof Consumer) {
      ((Consumer<Map<String, Object>>) this.options.get("sink")).accept(record);
    }
  }
}
