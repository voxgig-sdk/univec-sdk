package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core.{Context, Entity, Schema, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

// Payload validation against the model's own field types. The scala port of
// tm/ts/src/feature/validate/ValidateFeature.ts.
//
// The specs are NOT written here and not written in the model either: every
// entity field already carries a canonical type sentinel (`$STRING`,
// `$INTEGER`, the `$ONE` union for an OpenAPI multi-type), which is the same
// vocabulary Struct.validate speaks. The generator maps them once
// (helpers/canonSpec) and emits `Schema.entityspec`, so a field whose type
// changes in the API spec changes what this feature enforces with no edit
// anywhere.
//
// WHAT IS CHECKED
//   outbound (preSpec)  the payload the caller asked to send, against
//                       spec.op[opname] - the operation's request shape.
//   inbound  (preDone)  each record the operation returned, against
//                       spec.data - the entity's own field types.
//
// WHAT IS NOT. The model carries no array element types, no nested object
// schemas, no enums, formats or bounds, so this checks the shape the model
// knows and nothing more.
class ValidateFeature extends BaseFeature("validate", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var spec: JMap[String, Object] = new LinkedHashMap[String, Object]()

  private var request: Boolean = true
  private var response: Boolean = false
  private var mode: String = "throw"

  // The `onInvalid` callback, set after construction: the model types it a
  // `$FUNCTION` and an option map parsed out of JSON cannot carry one.
  var onInvalid: JMap[String, Object] => Unit = null

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    // DEFAULTS ARE APPLIED HERE, not by the option spec. The model's
    // `config.options` documents them and types them; it does not inject
    // them, because each feature entry in the spec is optional and struct
    // fills in nothing through an optional union. So every feature resolves
    // its own.
    this.request = FeatureOptions.foptBool(options, "request", true)
    this.response = FeatureOptions.foptBool(options, "response", false)

    // FAIL CLOSED. Only the exact string "report" selects report mode, so a
    // typo (`mode: "thow"`) still rejects rather than silently turning
    // enforcement off - the failure nobody would notice. The option spec
    // rejects the typo outright; this is what happens if it ever does not.
    this.mode =
      if ("report" == FeatureOptions.foptStr(options, "mode", "throw")) "report" else "throw"

    // `strict` is applied ONCE, here, by rebuilding the spec tree without the
    // `$OPEN` markers - rather than per call, which would clone a spec for
    // every request an SDK ever makes. REBUILT, not mutated: Schema.entityspec
    // is a lazy val every client in the process reads.
    this.spec =
      if (FeatureOptions.foptBool(options, "strict", false))
        ValidateFeature.close(Schema.entityspec).asInstanceOf[JMap[String, Object]]
      else Schema.entityspec
  }

  // Outbound. makeSpec throws a RuntimeException left in ctx.out["spec"], so
  // storing the error here rejects the operation before the request is built -
  // the same seam rbac uses one stage earlier through ctx.out["point"].
  override def preSpec(ctx: Context): Unit = {
    if (!this.active || !this.request) return

    val opname = opName(ctx)
    val opspec = opSpec(entitySpec(ctx), opname)
    if (opspec == null) return

    val errs = check(ctx, payload(ctx, opname), opspec, "request")
    if (errs.isEmpty || "report" == this.mode) return

    ctx.out.put("spec", ctx.makeError("validate_failed",
      "Invalid " + opname + " request for entity \"" + entName(ctx) + "\": " +
        errs.mkString("; ")))
  }

  // Inbound. preDone rather than preResult: the records are extracted from the
  // response body by makeResult, which runs between the two, so at preResult
  // there is nothing to check but the envelope.
  //
  // HOOK ORDER MATTERS HERE, and the default order is not the one you want.
  // preDone hooks fire in feature ADD order, which defaults to `test` first and
  // then names sorted - and `validate` sorts last, after audit, cost, debug,
  // metrics and telemetry. Those observers therefore record the operation as a
  // success before this hook has looked at it. Activating features as an
  // ORDERED LIST fixes it.
  override def preDone(ctx: Context): Unit = {
    if (!this.active || !this.response) return

    val espec = entitySpec(ctx)
    if (espec == null) return
    val dataspec = espec.get("data")
    if (dataspec == null) return

    if (ctx.result == null || ctx.result.resdata == null) return

    // A list op returns many records and a load returns one; both are checked
    // against the same record spec, because they are the same entity.
    val records = new ArrayList[Object]()
    ctx.result.resdata match {
      case l: JList[_] => records.addAll(l.asInstanceOf[JList[Object]])
      case v => records.add(v)
    }

    val errs = new ArrayList[String]()
    val it = records.iterator()
    while (it.hasNext) {
      val record = it.next()
      if (record != null) {
        // A NON-OBJECT IS A FAILURE, not something to skip. A load that
        // answered 42 where the entity's spec wants a record must not pass this
        // feature silently - struct rejects it with the field it could not find.
        check(ctx, ValidateFeature.unwrap(record), dataspec, "response")
          .foreach(e => errs.add(e))
      }
    }

    if (errs.isEmpty || "report" == this.mode) return

    val err = ctx.makeError("validate_failed",
      "Invalid response for entity \"" + entName(ctx) + "\": " +
        String.join("; ", errs))

    // BOTH, and `ok` is the load-bearing half: done returns resdata whenever
    // result.ok is true and never looks at err, so setting the error alone
    // would hand the caller the very records that failed the spec.
    ctx.result.ok = false
    ctx.result.err = err

    // AND THE DATA GOES. The load/update paths copy result.resdata into the
    // entity's own state on any non-null value, BEFORE done raises - so
    // rejecting the operation while leaving the records in place would leave
    // the caller holding an entity populated from a payload this feature had
    // just declared invalid.
    ctx.result.resdata = null
  }

  // The payload an operation is about to send.
  //
  // TWO SLOTS, AND THE OP PICKS. A body op (create/update/patch) carries the
  // caller's argument in reqdata over the entity's data; a match op
  // (load/list/remove) carries it in reqmatch over matchData. That is what the
  // entity operations pass to the context and what makePoint reads - so
  // reading reqdata for every op would check a load against the entity's STALE
  // stored match and reject it for the id the caller had just supplied.
  private def payload(ctx: Context, opname: String): JMap[String, Object] = {
    val body = "create" == opname || "update" == opname || "patch" == opname

    val base = if (body) ctx.data else ctx.matchData
    val req = if (body) ctx.reqdata else ctx.reqmatch

    val out = new LinkedHashMap[String, Object]()
    if (base != null) out.putAll(base)
    if (req != null) out.putAll(req)

    // `$action` SELECTS A CUSTOM ENDPOINT; it is not a field of the record.
    // makePoint reads it off this same argument and the request transformer
    // drops it before the body is built, so a spec built from the API's own
    // fields will never name it - and under `strict` every custom-action call
    // would be rejected for the one key that made it reachable.
    out.remove("$action")

    out
  }

  private def entitySpec(ctx: Context): JMap[String, Object] = {
    if (this.spec == null) return null
    this.spec.get(entName(ctx)) match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
      case _ => null
    }
  }

  private def opSpec(espec: JMap[String, Object], opname: String): Object = {
    if (espec == null) return null
    espec.get("op") match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]].get(opname)
      case _ => null
    }
  }

  private def opName(ctx: Context): String =
    if (ctx.op == null || ctx.op.name == null) "" else ctx.op.name

  private def entName(ctx: Context): String = {
    if (ctx.entity != null) {
      val name = ctx.entity.getName()
      if (name != null && name.nonEmpty) return name
    }
    if (ctx.op != null && ctx.op.entity != null) ctx.op.entity else ""
  }

  // One validate call. Errors are COLLECTED, never thrown: Struct.validate
  // throws on the first failure unless given an `errs` list, and a caller
  // fixing a payload wants every problem with it, not the first one.
  private def check(ctx: Context, data: Object, spec: Object,
                    direction: String): Seq[String] = {
    val collected = new ArrayList[Object]()
    val opts = new LinkedHashMap[String, Object]()
    opts.put("errs", collected)

    try {
      Struct.validate(data, spec, opts)
    } catch {
      case e: RuntimeException =>
        // A spec this port cannot run at all (rather than a payload that fails
        // it) must not take the operation down with it: report it like any
        // other failure and let `mode` decide.
        if (collected.isEmpty) {
          collected.add(if (e.getMessage == null) e.toString else e.getMessage)
        }
    }

    val errs = new ArrayList[String]()
    val it = collected.iterator()
    while (it.hasNext) errs.add(String.valueOf(it.next()))

    if (!errs.isEmpty && this.onInvalid != null) {
      // A callback receiving every failure, whatever `mode` does with it, so a
      // client can log or count invalid payloads without changing what the SDK
      // returns.
      val report = new LinkedHashMap[String, Object]()
      report.put("entity", entName(ctx))
      report.put("op", opName(ctx))
      report.put("direction", direction)
      report.put("errs", errs)
      report.put("data", data)
      try { this.onInvalid(report) }
      catch { case _: RuntimeException => /* a reporting callback must not fail the operation */ }
    }

    import scala.jdk.CollectionConverters._
    errs.asScala.toSeq
  }
}

object ValidateFeature {

  // Built rather than written, so the backticks cannot be lost in an edit.
  private val OPEN: String = 96.toChar.toString + "$OPEN" + 96.toChar.toString

  // A RESULT RECORD AS DATA.
  //
  // makeResult turns every record of a LIST into an entity instance, so what
  // reaches preDone for a list is wrappers, not records - and a wrapper checked
  // against a field spec fails on every required field while its actual data
  // goes unchecked. A load returns the record itself, so this handles both.
  private def unwrap(record: Object): Object = record match {
    case e: Entity =>
      val data = e.data()
      if (data != null) data else record
    case _ => record
  }

  // The spec tree with every `$OPEN` marker removed, so an undeclared key is an
  // error rather than a pass. Rebuilt rather than mutated: Schema's entity spec
  // is shared by every client in the process.
  private def close(node: Object): Object = node match {
    case l: JList[_] =>
      val out = new ArrayList[Object]()
      val it = l.asInstanceOf[JList[Object]].iterator()
      while (it.hasNext) out.add(close(it.next()))
      out
    case m: JMap[_, _] =>
      val out = new LinkedHashMap[String, Object]()
      val it = m.asInstanceOf[JMap[String, Object]].entrySet().iterator()
      while (it.hasNext) {
        val e = it.next()
        if (OPEN != e.getKey) out.put(e.getKey, close(e.getValue))
      }
      out
    case v => v
  }
}
