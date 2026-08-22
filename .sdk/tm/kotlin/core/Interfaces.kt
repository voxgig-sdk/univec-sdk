package KOTLINPACKAGE.core

/** Minimal entity contract used by the result pipeline (list wrapping). */
interface Entity {
  val name: String

  fun make(): Entity

  fun data(vararg args: Any?): Any?

  fun match(vararg args: Any?): Any?
}

/**
 * The full CRUD entity contract of the Univec SDK. Every generated
 * entity implements every operation; unsupported operations throw an
 * SdkError at runtime (see Helpers.unsupportedOp).
 */
interface SdkEntity : Entity {
  fun load(reqmatch: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any?

  fun list(reqmatch: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any?

  fun create(reqdata: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any?

  fun update(reqdata: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any?

  fun remove(reqmatch: MutableMap<String, Any?>?, ctrl: MutableMap<String, Any?>?): Any?

  // Runs `action` through the pipeline and returns a Sequence over result
  // items (the streaming feature's incremental output when active, else the
  // materialised items). See EntityBase.stream.
  fun stream(
    action: String,
    args: MutableMap<String, Any?>?,
    callopts: MutableMap<String, Any?>?,
  ): Sequence<Any?>
}

/**
 * A Univec SDK feature. Hook methods are dispatched by name via the
 * featureHook utility (reflectively, so features may also define extra
 * hooks beyond this interface).
 */
interface Feature {
  val version: String

  val name: String

  val active: Boolean

  fun init(ctx: Context, options: MutableMap<String, Any?>)

  fun postConstruct(ctx: Context)

  fun postConstructEntity(ctx: Context)

  fun setData(ctx: Context)

  fun getData(ctx: Context)

  fun getMatch(ctx: Context)

  fun setMatch(ctx: Context)

  fun prePoint(ctx: Context)

  fun preSpec(ctx: Context)

  fun preRequest(ctx: Context)

  fun preResponse(ctx: Context)

  fun preResult(ctx: Context)

  fun preDone(ctx: Context)

  fun preUnexpected(ctx: Context)
}

/**
 * Optional capability: a feature exposing add-time placement options
 * ("__before__", "__after__", "__replace__") read by the featureAdd
 * utility. Every BaseFeature implements this via its addOpts field.
 */
interface FeaturePlacement {
  fun addOptions(): MutableMap<String, Any?>?
}
