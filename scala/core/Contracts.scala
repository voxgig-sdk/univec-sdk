package voxgig.univecsdk.core

import java.util.{Map => JMap}

// Minimal entity contract used by the result pipeline (list wrapping).
trait Entity {
  def getName(): String
  def make(): Entity
  def data(args: Object*): Object
  def matchArgs(args: Object*): Object
}

// The full CRUD entity contract of the Univec SDK. Every generated
// entity implements every operation; unsupported operations throw an
// SdkError at runtime (see Helpers.unsupportedOp).
trait SdkEntity extends Entity {
  def load(reqmatch: JMap[String, Object], ctrl: JMap[String, Object]): Object
  def list(reqmatch: JMap[String, Object], ctrl: JMap[String, Object]): Object
  def create(reqdata: JMap[String, Object], ctrl: JMap[String, Object]): Object
  def update(reqdata: JMap[String, Object], ctrl: JMap[String, Object]): Object
  def remove(reqmatch: JMap[String, Object], ctrl: JMap[String, Object]): Object
  // Runs `action` through the pipeline and returns an Iterator over result
  // items (the streaming feature's incremental output when active, else the
  // materialised items). See EntityBase.stream.
  def stream(action: String, args: JMap[String, Object], callopts: JMap[String, Object]): Iterator[Object]
}

// A Univec SDK feature. Hook methods are dispatched by name via the
// featureHook utility. Concrete features extend BaseFeature and override the
// hooks they need.
trait Feature {

  def getVersion(): String
  def getName(): String
  def getActive(): Boolean

  def init(ctx: Context, options: JMap[String, Object]): Unit = {}

  def postConstruct(ctx: Context): Unit = {}
  def postConstructEntity(ctx: Context): Unit = {}
  def setData(ctx: Context): Unit = {}
  def getData(ctx: Context): Unit = {}
  def getMatch(ctx: Context): Unit = {}
  def setMatch(ctx: Context): Unit = {}
  def prePoint(ctx: Context): Unit = {}
  def preSpec(ctx: Context): Unit = {}
  def preRequest(ctx: Context): Unit = {}
  def preResponse(ctx: Context): Unit = {}
  def preResult(ctx: Context): Unit = {}
  def preDone(ctx: Context): Unit = {}
  def preUnexpected(ctx: Context): Unit = {}

  // Optional add-time placement options ("__before__"/"__after__"/
  // "__replace__") read by the featureAdd utility. Default: none.
  def addOptions(): JMap[String, Object] = null

  // Dispatch a named hook to the matching hook method (name is the hook
  // marker used in the pipeline, e.g. "PreRequest"). Replaces the java
  // donor's reflective dispatch.
  def hook(name: String, ctx: Context): Unit = name match {
    case "PostConstruct" => postConstruct(ctx)
    case "PostConstructEntity" => postConstructEntity(ctx)
    case "SetData" => setData(ctx)
    case "GetData" => getData(ctx)
    case "GetMatch" => getMatch(ctx)
    case "SetMatch" => setMatch(ctx)
    case "PrePoint" => prePoint(ctx)
    case "PreSpec" => preSpec(ctx)
    case "PreRequest" => preRequest(ctx)
    case "PreResponse" => preResponse(ctx)
    case "PreResult" => preResult(ctx)
    case "PreDone" => preDone(ctx)
    case "PreUnexpected" => preUnexpected(ctx)
    case _ => ()
  }
}
