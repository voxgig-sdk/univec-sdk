// Univec SDK — core runtime types.
//
// The whole pipeline type graph (mirrors the java core/* classes): the
// swappable Utility function bundle, the per-operation Context, the
// transport Spec/Response/Result, the Feature/Entity contracts and the
// SdkClient/EntityBase bases. Shared-mutable objects are held by
// std::shared_ptr so mutations are visible through every alias (the same
// reference semantics the java donor gets from GC references); the JSON
// data model is the vendored voxgig struct Value.

#ifndef SDK_CORE_TYPES_HPP
#define SDK_CORE_TYPES_HPP

#include <functional>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "struct.hpp"

namespace sdk {

// ---- forward declarations --------------------------------------------

class SdkError;
class Control;
class Spec;
class Response;
class Result;
class Operation;
class Point;
class Entity;
class Feature;
class Utility;
class Context;
class SdkClient;

using SdkErrorPtr = std::shared_ptr<SdkError>;
using ControlPtr = std::shared_ptr<Control>;
using SpecPtr = std::shared_ptr<Spec>;
using ResponsePtr = std::shared_ptr<Response>;
using ResultPtr = std::shared_ptr<Result>;
using OperationPtr = std::shared_ptr<Operation>;
using EntityPtr = std::shared_ptr<Entity>;
using FeaturePtr = std::shared_ptr<Feature>;
using UtilityPtr = std::shared_ptr<Utility>;
using CtxPtr = std::shared_ptr<Context>;

using OpMap = std::map<std::string, OperationPtr>;
using OpMapPtr = std::shared_ptr<OpMap>;

// Generated (core/config.hpp) — the embedded API config + feature factory.
inline Value makeConfig();
inline const Value& sharedConfig();
inline FeaturePtr makeFeature(const std::string& name);

// Defined in utility/pipeline.hpp; wires the Utility function fields.
inline void register_all(Utility& u);

// ---- Helpers ----------------------------------------------------------

namespace Helpers {

inline int toInt(const Value& v) { return v.is_number() ? static_cast<int>(v.as_int()) : -1; }
inline long long toLong(const Value& v, long long def) {
  return v.is_number() ? static_cast<long long>(v.as_int()) : def;
}
inline Value toMapAny(const Value& v) { return v.is_map() ? v : Value::undef(); }

SdkErrorPtr unsupportedOp(const std::string& opname, const std::string& entityname);

} // namespace Helpers

// ---- SdkError ---------------------------------------------------------

class SdkError : public std::runtime_error {
public:
  std::string sdk = "Univec";
  std::string code;
  std::string msg;
  Context* ctx = nullptr;
  ResultPtr result_obj;
  SpecPtr spec_obj;

  SdkError(const std::string& code_, const std::string& msg_, Context* ctx_)
      : std::runtime_error(msg_), code(code_), msg(msg_), ctx(ctx_) {}

  const char* what() const noexcept override { return msg.c_str(); }
  const std::string& getMessage() const { return msg; }
};

// ---- Control ----------------------------------------------------------

class Control {
public:
  // Tri-state: undef (default: throw), true, or false (return fallback data).
  Value throwing = Value::undef();
  SdkErrorPtr err;
  Value explain = Value::undef(); // map when explain-capture is active
  std::string actor = "";
  Value paging = Value::undef();
};

// ---- Spec -------------------------------------------------------------

class Spec {
public:
  Value parts = Value::undef();
  Value headers;
  Value alias;
  std::string base = "";
  std::string prefix = "";
  std::string suffix = "";
  Value params;
  Value query;
  std::string step = "";
  std::string method = "GET";
  Value body = Value::undef();
  std::string url = "";
  std::string path = "";

  Spec() {
    headers = vmap();
    alias = vmap();
    params = vmap();
    query = vmap();
  }

  explicit Spec(const Value& m) : Spec() {
    if (!m.is_map()) return;
    Value v = getp(m, "parts");
    if (v.is_list()) parts = v;
    v = getp(m, "headers");
    if (v.is_map()) headers = v;
    v = getp(m, "alias");
    if (v.is_map()) alias = v;
    v = getp(m, "base");
    if (v.is_string()) base = v.as_string();
    v = getp(m, "prefix");
    if (v.is_string()) prefix = v.as_string();
    v = getp(m, "suffix");
    if (v.is_string()) suffix = v.as_string();
    v = getp(m, "params");
    if (v.is_map()) params = v;
    v = getp(m, "query");
    if (v.is_map()) query = v;
    v = getp(m, "step");
    if (v.is_string()) step = v.as_string();
    v = getp(m, "method");
    if (v.is_string()) method = v.as_string();
    if (map_contains(m, "body")) body = mapget(m, "body");
    v = getp(m, "url");
    if (v.is_string()) url = v.as_string();
    v = getp(m, "path");
    if (v.is_string()) path = v.as_string();
  }

  // Value view for explain capture.
  Value toValue() const {
    Value o = vmap();
    map_put(o, "base", Value(base));
    map_put(o, "prefix", Value(prefix));
    map_put(o, "suffix", Value(suffix));
    map_put(o, "path", Value(path));
    map_put(o, "method", Value(method));
    map_put(o, "step", Value(step));
    map_put(o, "url", Value(url));
    map_put(o, "headers", headers);
    map_put(o, "params", params);
    map_put(o, "query", query);
    if (!body.is_undef()) map_put(o, "body", body);
    return o;
  }
};

// ---- Response ---------------------------------------------------------

// jsonFunc: a thunk yielding the parsed JSON body.
using JsonFunc = std::function<Value()>;

class Response {
public:
  int status = -1;
  std::string statusText = "";
  Value headers = Value::undef();
  JsonFunc jsonFunc;
  Value body = Value::undef();
  SdkErrorPtr err;

  Response() = default;

  explicit Response(const Value& m) {
    if (!m.is_map()) return;
    Value s = getp(m, "status");
    if (s.is_number()) status = Helpers::toInt(s);
    Value st = getp(m, "statusText");
    if (st.is_string()) statusText = st.as_string();
    headers = getp(m, "headers");
    Value jf = mapget(m, "json");
    if (jf.is_func()) {
      // A struct Injector thunk: invoke with dummy args to obtain the body.
      Value fnv = jf;
      jsonFunc = [fnv]() -> Value {
        if (fnv.is_injector()) {
          vs::Injection inj(Value::undef(), Value::undef());
          return fnv.as_injector()(inj, Value::undef(), std::string(""), Value::undef());
        }
        return Value::undef();
      };
    }
    body = getp(m, "body");
  }
};

// ---- Result -----------------------------------------------------------

class Result {
public:
  bool ok = false;
  int status = -1;
  std::string statusText = "";
  Value headers;
  Value body = Value::undef();
  SdkErrorPtr err;
  Value resdata = Value::undef();
  Value resmatch = Value::undef();

  // Feature extensions.
  Value paging = Value::undef();
  bool streaming = false;
  std::function<std::vector<Value>()> stream;

  Result() { headers = vmap(); }

  explicit Result(const Value& m) : Result() {
    if (!m.is_map()) return;
    Value o = getp(m, "ok");
    if (o.is_bool()) ok = o.as_bool();
    Value s = getp(m, "status");
    if (s.is_number()) status = Helpers::toInt(s);
    Value st = getp(m, "statusText");
    if (st.is_string()) statusText = st.as_string();
    Value h = getp(m, "headers");
    if (h.is_map()) headers = h;
    body = getp(m, "body");
    resdata = getp(m, "resdata");
    Value rm = getp(m, "resmatch");
    if (rm.is_map()) resmatch = rm;
  }

  Value toValue() const {
    Value o = vmap();
    map_put(o, "ok", Value(ok));
    map_put(o, "status", Value(status));
    map_put(o, "statusText", Value(statusText));
    map_put(o, "headers", headers);
    if (!body.is_undef()) map_put(o, "body", body);
    if (!resdata.is_undef()) map_put(o, "resdata", resdata);
    if (!resmatch.is_undef()) map_put(o, "resmatch", resmatch);
    if (err) map_put(o, "err", vmap({{"message", Value(err->msg)}}));
    return o;
  }
};

// ---- Operation --------------------------------------------------------

class Operation {
public:
  std::string entity = "_";
  std::string name = "_";
  std::string input = "_";
  std::vector<Value> points; // each point is a map Value
  Value alias = Value::undef();

  Operation() = default;

  explicit Operation(const Value& m) {
    Value v = getp(m, "entity");
    if (v.is_string() && !v.as_string().empty()) entity = v.as_string();
    v = getp(m, "name");
    if (v.is_string() && !v.as_string().empty()) name = v.as_string();
    v = getp(m, "input");
    if (v.is_string() && !v.as_string().empty()) input = v.as_string();
    Value pts = getp(m, "points");
    if (pts.is_list()) {
      for (const auto& t : *pts.as_list()) {
        if (t.is_map()) points.push_back(t);
      }
    }
    Value a = getp(m, "alias");
    if (a.is_map()) alias = a;
  }
};

// ---- Point (typed view over a point map) ------------------------------

class Point {
public:
  Value args;
  Value rename;
  std::string method = "";
  std::string orig = "";
  Value parts;
  Value params = Value::undef();
  Value select = Value::undef();
  bool active = false;
  Value relations = Value::undef();
  Value alias;
  Value transform;

  explicit Point(const Value& m) {
    args = getp(m, "args");
    if (!args.is_map()) {
      args = vmap();
      map_put(args, "params", vlist());
    }
    rename = getp(m, "rename");
    if (!rename.is_map()) {
      rename = vmap();
      map_put(rename, "params", vmap());
    }
    Value v = getp(m, "method");
    if (v.is_string()) method = v.as_string();
    v = getp(m, "orig");
    if (v.is_string()) orig = v.as_string();
    parts = getp(m, "parts");
    if (!parts.is_list()) parts = vlist();
    params = getp(m, "params");
    select = getp(m, "select");
    v = getp(m, "active");
    if (v.is_bool()) active = v.as_bool();
    relations = getp(m, "relations");
    alias = getp(m, "alias");
    if (!alias.is_map()) alias = vmap();
    transform = getp(m, "transform");
    if (!transform.is_map()) transform = vmap();
  }
};

// ---- Entity contract --------------------------------------------------

class Entity {
public:
  virtual ~Entity() = default;
  virtual std::string getName() = 0;
  virtual EntityPtr make() = 0;
  virtual Value data(const Value& arg = Value::undef()) = 0;
  virtual Value match(const Value& arg = Value::undef()) = 0;

  // `remove` resolves to the entity, marked. The instance KEEPS the data it
  // held - a caller can still read what was deleted - but it is no longer a
  // live record.
  virtual void markDeleted() = 0;
  virtual bool deleted() = 0;
};

// ---- Feature contract -------------------------------------------------

class Feature {
public:
  virtual ~Feature() = default;
  virtual std::string getVersion() = 0;
  virtual std::string getName() = 0;
  virtual bool getActive() = 0;
  // FeaturePlacement: add-time ordering options ("__before__"/"__after__"/
  // "__replace__"); undef when the feature has no placement preference.
  virtual Value addOptions() { return Value::undef(); }

  virtual void init(CtxPtr ctx, const Value& options) {}
  virtual void postConstruct(CtxPtr ctx) {}
  virtual void postConstructEntity(CtxPtr ctx) {}
  virtual void setData(CtxPtr ctx) {}
  virtual void getData(CtxPtr ctx) {}
  virtual void getMatch(CtxPtr ctx) {}
  virtual void setMatch(CtxPtr ctx) {}
  virtual void prePoint(CtxPtr ctx) {}
  virtual void preSpec(CtxPtr ctx) {}
  virtual void preRequest(CtxPtr ctx) {}
  virtual void preResponse(CtxPtr ctx) {}
  virtual void preResult(CtxPtr ctx) {}
  virtual void preDone(CtxPtr ctx) {}
  virtual void preUnexpected(CtxPtr ctx) {}
};

// ---- CtxSpec (the makeContext argument; java's heterogeneous ctxmap) --

struct CtxSpec {
  bool has_opname = false;
  std::string opname;

  SdkClient* client = nullptr;
  UtilityPtr utility;
  Entity* entity = nullptr;
  ControlPtr ctrl;   // object form (rare)
  Value ctrlMap = Value::undef(); // map form: throw/explain/actor/paging

  Value config = Value::undef();
  Value options = Value::undef();
  Value shared = Value::undef();
  Value meta = Value::undef();
  Value entopts = Value::undef();
  Value point = Value::undef();
  Value data = Value::undef();
  Value reqdata = Value::undef();
  Value match = Value::undef();
  Value reqmatch = Value::undef();

  OpMapPtr opmap;

  void setOpname(const std::string& n) {
    opname = n;
    has_opname = true;
  }
};

// ---- CtxOut (the feature -> pipeline short-circuit channel) -----------

struct CtxOut {
  bool has_point = false;
  Value point = Value::undef();
  SdkErrorPtr pointError;
  SpecPtr spec;
  ResponsePtr request;
  ResponsePtr response;
  ResultPtr result;
};

// ---- Context ----------------------------------------------------------

class Context {
public:
  std::string id;
  CtxOut out;
  ControlPtr ctrl;
  Value meta = Value::undef();
  SdkClient* client = nullptr;
  UtilityPtr utility;
  OperationPtr op;
  Value point = Value::undef();
  Value config = Value::undef();
  Value entopts = Value::undef();
  Value options = Value::undef();
  OpMapPtr opmap;
  ResponsePtr response;
  ResultPtr result;
  SpecPtr spec;
  Value data = Value::undef();
  Value reqdata = Value::undef();
  Value match = Value::undef();
  Value reqmatch = Value::undef();
  Entity* entity = nullptr;
  Value shared = Value::undef();

  Context(const CtxSpec& cs, const CtxPtr& basectx);

  SdkErrorPtr makeError(const std::string& code, const std::string& msg);

private:
  OperationPtr resolveOp(const std::string& opname);
};

// ---- Utility (swappable pipeline function bundle) ---------------------

class Utility {
public:
  std::function<Value(CtxPtr, const Value&)> clean;
  std::function<Value(CtxPtr)> done;
  std::function<Value(CtxPtr, SdkErrorPtr)> makeError;
  std::function<void(CtxPtr, FeaturePtr)> featureAdd;
  std::function<void(CtxPtr, const std::string&)> featureHook;
  std::function<void(CtxPtr, FeaturePtr)> featureInit;
  std::function<Value(CtxPtr, const std::string&, const Value&)> fetcher;
  std::function<Value(CtxPtr)> makeFetchDef;
  std::function<CtxPtr(const CtxSpec&, CtxPtr)> makeContext;
  std::function<Value(CtxPtr)> makeOptions;
  std::function<ResponsePtr(CtxPtr)> makeRequest;
  std::function<ResponsePtr(CtxPtr)> makeResponse;
  std::function<ResultPtr(CtxPtr)> makeResult;
  std::function<Value(CtxPtr)> makePoint;
  std::function<SpecPtr(CtxPtr)> makeSpec;
  std::function<std::string(CtxPtr)> makeUrl;
  std::function<Value(CtxPtr, const Value&)> param;
  std::function<SpecPtr(CtxPtr)> prepareAuth;
  std::function<Value(CtxPtr)> prepareBody;
  std::function<Value(CtxPtr)> prepareHeaders;
  std::function<std::string(CtxPtr)> prepareMethod;
  std::function<Value(CtxPtr)> prepareParams;
  std::function<std::string(CtxPtr)> preparePath;
  std::function<Value(CtxPtr)> prepareQuery;
  std::function<ResultPtr(CtxPtr)> resultBasic;
  std::function<ResultPtr(CtxPtr)> resultBody;
  std::function<ResultPtr(CtxPtr)> resultHeaders;
  std::function<Value(CtxPtr)> transformRequest;
  std::function<Value(CtxPtr)> transformResponse;
  Value custom = vmap();

  Utility() { register_all(*this); }

private:
  struct NoRegister {};
  explicit Utility(NoRegister) {}

public:
  // A field-level copy sharing nothing mutable but the function refs and a
  // shallow copy of the custom map (function values preserved).
  UtilityPtr copy() const {
    auto u = std::shared_ptr<Utility>(new Utility(NoRegister{}));
    u->clean = clean;
    u->done = done;
    u->makeError = makeError;
    u->featureAdd = featureAdd;
    u->featureHook = featureHook;
    u->featureInit = featureInit;
    u->fetcher = fetcher;
    u->makeFetchDef = makeFetchDef;
    u->makeContext = makeContext;
    u->makeOptions = makeOptions;
    u->makeRequest = makeRequest;
    u->makeResponse = makeResponse;
    u->makeResult = makeResult;
    u->makePoint = makePoint;
    u->makeSpec = makeSpec;
    u->makeUrl = makeUrl;
    u->param = param;
    u->prepareAuth = prepareAuth;
    u->prepareBody = prepareBody;
    u->prepareHeaders = prepareHeaders;
    u->prepareMethod = prepareMethod;
    u->prepareParams = prepareParams;
    u->preparePath = preparePath;
    u->prepareQuery = prepareQuery;
    u->resultBasic = resultBasic;
    u->resultBody = resultBody;
    u->resultHeaders = resultHeaders;
    u->transformRequest = transformRequest;
    u->transformResponse = transformResponse;
    // Shallow copy of custom: keep the (function) Values by reference.
    u->custom = vmap();
    if (custom.is_map()) {
      for (const auto& kv : *custom.as_map()) {
        map_put(u->custom, kv.first, kv.second);
      }
    }
    return u;
  }
};

// ---- SdkClient --------------------------------------------------------

class SdkClient {
public:
  std::string mode = "live";
  std::vector<FeaturePtr> features;

  Value options = Value::undef();
  UtilityPtr utility;
  CtxPtr rootctx;

  explicit SdkClient(const Value& options_);
  virtual ~SdkClient() = default;

  Value optionsMap();
  UtilityPtr getUtility();
  CtxPtr getRootCtx() { return rootctx; }

  Value prepare(const Value& fetchargs);
  Value direct(const Value& fetchargs);
  Value graphql(const std::string& query, const Value& variables = Value::undef(),
                const Value& ctrl = Value::undef());

private:
  bool opAllowed(const std::string& op);
  Value opDenied(const std::string& op);
  Value rawRequest(const Value& fetchargs);

public:

  static Value testOptions(const Value& testopts, const Value& sdkopts);
};

// ---- SdkEntity contract -----------------------------------------------

class SdkEntity;
using SdkEntityPtr = std::shared_ptr<SdkEntity>;

// Every operation resolves to the ENTITY, not the raw data - `list` to a
// vector of them, one per record. The record is reached through `data()`.
// See AGENTS.md "Entity operations return ENTITIES".
//
// `Value` cannot carry an entity: it is a closed data union, and adding a
// variant to a general-purpose struct library to hold SDK objects would be
// wrong. So the CONTRACT lives in these signatures instead.
class SdkEntity : public Entity {
public:
  virtual SdkEntityPtr load(const Value& reqmatch, const Value& ctrl) = 0;
  virtual std::vector<SdkEntityPtr> list(const Value& reqmatch, const Value& ctrl) = 0;
  virtual SdkEntityPtr create(const Value& reqdata, const Value& ctrl) = 0;
  virtual SdkEntityPtr update(const Value& reqdata, const Value& ctrl) = 0;
  virtual SdkEntityPtr remove(const Value& reqmatch, const Value& ctrl) = 0;
};

// ---- EntityBase (shared entity runtime + runOp) -----------------------

class EntityBase : public SdkEntity,
                   public std::enable_shared_from_this<EntityBase> {
public:
  std::string name_ = "";
  // Set once a successful `remove` resolves on this instance.
  bool deleted_ = false;
  SdkClient* client = nullptr;
  UtilityPtr utility;
  Value entopts = Value::undef();
  Value data_ = Value::undef();
  Value match_ = Value::undef();
  CtxPtr entctx;

  EntityBase(const std::string& name, SdkClient* client_, const Value& entopts_);

  std::string getName() override { return name_; }

  void markDeleted() override { deleted_ = true; }
  bool deleted() override { return deleted_; }

  // The handle for this instance, as the ops return it.
  SdkEntityPtr self() {
    return std::static_pointer_cast<SdkEntity>(shared_from_this());
  }

  Value data(const Value& arg = Value::undef()) override;
  Value match(const Value& arg = Value::undef()) override;

  // stream runs `action` through the full pipeline and returns the result
  // items, so the streaming feature's incremental output is reachable from a
  // generated entity (a normal op call materialises the whole result). This
  // runtime is synchronous, so the returned vector is a materialised cursor
  // the caller iterates. `callopts` parameterises the call: inbound yields the
  // streaming feature's items when active, else the materialised items;
  // outbound attaches an iterable `body` to the request (reqdata `body$`);
  // `ctrl` threads pipeline control.
  std::vector<Value> stream(const std::string& action,
                            const Value& args = Value::undef(),
                            const Value& callopts = Value::undef());

protected:
  // runOp drives one operation through the pipeline with feature hooks.
  Value runOp(CtxPtr ctx, const std::function<void()>& postDone);
};

// =======================================================================
// Out-of-line method definitions (all classes now complete).
// =======================================================================

// ---- Helpers ----
inline SdkErrorPtr Helpers::unsupportedOp(const std::string& opname,
                                          const std::string& entityname) {
  return std::make_shared<SdkError>(
      "op_unsupported",
      "operation '" + opname + "' not supported by entity '" + entityname + "'", nullptr);
}

// ---- Context ----
inline Context::Context(const CtxSpec& cs, const CtxPtr& basectx) {
  static long long counter = 10000000;
  id = "C" + std::to_string(++counter);

  // Client
  client = cs.client;
  if (client == nullptr && basectx) client = basectx->client;

  // Utility
  utility = cs.utility;
  if (!utility && basectx) utility = basectx->utility;

  // Ctrl
  ctrl = std::make_shared<Control>();
  if (cs.ctrl) {
    ctrl = cs.ctrl;
  } else if (cs.ctrlMap.is_map()) {
    Value t = getp(cs.ctrlMap, "throw");
    if (t.is_bool()) ctrl->throwing = t;
    Value e = getp(cs.ctrlMap, "explain");
    if (e.is_map()) ctrl->explain = e;
    Value a = getp(cs.ctrlMap, "actor");
    if (a.is_string()) ctrl->actor = a.as_string();
    Value p = getp(cs.ctrlMap, "paging");
    if (p.is_map()) ctrl->paging = p;
  } else if (basectx && basectx->ctrl) {
    ctrl = basectx->ctrl;
  }

  // Meta
  meta = vmap();
  if (cs.meta.is_map()) meta = cs.meta;
  else if (basectx && basectx->meta.is_map()) meta = basectx->meta;

  // Config
  if (cs.config.is_map()) config = cs.config;
  if (config.is_undef() && basectx) config = basectx->config;

  // Entopts
  if (cs.entopts.is_map()) entopts = cs.entopts;
  if (entopts.is_undef() && basectx) entopts = basectx->entopts;

  // Options
  if (cs.options.is_map()) options = cs.options;
  if (options.is_undef() && basectx) options = basectx->options;

  // Entity
  entity = cs.entity;
  if (!entity && basectx) entity = basectx->entity;

  // Shared
  if (cs.shared.is_map()) shared = cs.shared;
  if (shared.is_undef() && basectx) shared = basectx->shared;

  // Opmap
  opmap = cs.opmap;
  if (!opmap && basectx) opmap = basectx->opmap;
  if (!opmap) opmap = std::make_shared<OpMap>();

  // Data / reqdata / match / reqmatch
  data = cs.data.is_map() ? cs.data : vmap();
  reqdata = cs.reqdata.is_map() ? cs.reqdata : vmap();
  match = cs.match.is_map() ? cs.match : vmap();
  reqmatch = cs.reqmatch.is_map() ? cs.reqmatch : vmap();

  // Point
  if (cs.point.is_map()) point = cs.point;
  if (point.is_undef() && basectx) point = basectx->point;

  // Spec / Result / Response inherited from basectx if present.
  if (!spec && basectx) spec = basectx->spec;
  if (!result && basectx) result = basectx->result;
  if (!response && basectx) response = basectx->response;

  // Resolve operation.
  op = resolveOp(cs.has_opname ? cs.opname : std::string(""));
}

inline OperationPtr Context::resolveOp(const std::string& opname) {
  std::string entname = "";
  if (entity) entname = entity->getName();
  std::string cacheKey = entname + ":" + opname;

  auto it = opmap->find(cacheKey);
  if (it != opmap->end()) return it->second;

  if (opname.empty()) {
    return std::make_shared<Operation>(vmap());
  }

  Value opcfg = Struct::getpath(config, {"entity", entname, "op", opname});

  std::string input = "match";
  if (opname == "update" || opname == "create") input = "data";

  Value points = Value::undef();
  if (opcfg.is_map()) {
    Value t = getp(opcfg, "points");
    if (t.is_list()) points = t;
  }
  if (!points.is_list()) points = vlist();

  Value opdef = vmap();
  map_put(opdef, "entity", Value(entname));
  map_put(opdef, "name", Value(opname));
  map_put(opdef, "input", Value(input));
  map_put(opdef, "points", points);

  auto op_ = std::make_shared<Operation>(opdef);
  (*opmap)[cacheKey] = op_;
  return op_;
}

inline SdkErrorPtr Context::makeError(const std::string& code, const std::string& msg) {
  return std::make_shared<SdkError>(code, msg, this);
}

// ---- SdkClient ----
inline SdkClient::SdkClient(const Value& options_) {
  utility = std::make_shared<Utility>();

  // The process-wide config (sdkgen rung L2): read-only on the request path,
  // so every client shares one rather than rebuilding it.
  Value config = sharedConfig();

  CtxSpec cs;
  cs.client = this;
  cs.utility = utility;
  cs.config = config;
  if (options_.is_map()) cs.options = options_;
  cs.shared = vmap();

  rootctx = utility->makeContext(cs, nullptr);

  options = utility->makeOptions(rootctx);

  if (is_true(Struct::getpath(options, {"feature", "test", "active"}))) {
    mode = "test";
  }

  rootctx->options = options;

  // Add features in the resolved order (makeOptions puts an explicit list
  // order first, else defaults to test-first). Ordering matters: the `test`
  // feature installs the base mock transport and the transport features
  // (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
  // must be added before them to sit at the base of the transport chain.
  Value featureOpts = Helpers::toMapAny(getp(options, "feature"));
  Value featureOrder = Struct::getpath(options, {"__derived__", "featureorder"});
  if (featureOpts.is_map() && featureOrder.is_list()) {
    for (const auto& fnamev : *featureOrder.as_list()) {
      if (!fnamev.is_string()) continue;
      Value fopts = Helpers::toMapAny(getp(featureOpts, fnamev.as_string()));
      if (fopts.is_map() && is_true(getp(fopts, "active"))) {
        FeaturePtr f = makeFeature(fnamev.as_string());
        if (f) utility->featureAdd(rootctx, f);
      }
    }
  }

  // Extension features (options.extend is a list of Feature ptrs — not
  // representable as struct Values; extension via options is not wired for
  // the C++ target, matching the "no extend list in Value" constraint).

  // Initialize features.
  std::vector<FeaturePtr> snapshot = features;
  for (auto& f : snapshot) {
    utility->featureInit(rootctx, f);
  }

  utility->featureHook(rootctx, "PostConstruct");
}

inline Value SdkClient::optionsMap() {
  Value out = Struct::clone(options);
  return out.is_map() ? out : vmap();
}

inline UtilityPtr SdkClient::getUtility() { return utility->copy(); }

inline Value SdkClient::testOptions(const Value& testopts, const Value& sdkopts) {
  Value sopts = sdkopts.is_map() ? Struct::clone(sdkopts) : vmap();
  Value topts = testopts.is_map() ? Struct::clone(testopts) : vmap();
  map_put(topts, "active", Value(true));
  Struct::setpath(sopts, {"feature", "test"}, topts);
  return sopts;
}

inline Value SdkClient::prepare(const Value& fetchargs_) {
  UtilityPtr u = utility;
  Value fetchargs = fetchargs_.is_map() ? fetchargs_ : vmap();

  Value ctrl = Helpers::toMapAny(getp(fetchargs, "ctrl"));
  if (!ctrl.is_map()) ctrl = vmap();

  CtxSpec cs;
  cs.setOpname("prepare");
  cs.ctrlMap = ctrl;
  CtxPtr ctx = u->makeContext(cs, rootctx);

  Value opts = options;

  Value pathRaw = getp(fetchargs, "path");
  std::string path = pathRaw.is_string() ? pathRaw.as_string() : "";
  Value methodRaw = getp(fetchargs, "method");
  std::string method = methodRaw.is_string() ? methodRaw.as_string() : "";
  if (method.empty()) method = "GET";

  Value params = Helpers::toMapAny(getp(fetchargs, "params"));
  if (!params.is_map()) params = vmap();
  Value query = Helpers::toMapAny(getp(fetchargs, "query"));
  if (!query.is_map()) query = vmap();

  Value headers = u->prepareHeaders(ctx);

  Value base = getp(opts, "base");
  Value prefix = getp(opts, "prefix");
  Value suffix = getp(opts, "suffix");

  Value specmap = vmap();
  map_put(specmap, "base", base.is_string() ? base : Value(""));
  map_put(specmap, "prefix", prefix.is_string() ? prefix : Value(""));
  map_put(specmap, "suffix", suffix.is_string() ? suffix : Value(""));
  map_put(specmap, "path", Value(path));
  map_put(specmap, "method", Value(method));
  map_put(specmap, "params", params);
  map_put(specmap, "query", query);
  map_put(specmap, "headers", headers);
  map_put(specmap, "body", getp(fetchargs, "body"));
  map_put(specmap, "step", Value("start"));
  ctx->spec = std::make_shared<Spec>(specmap);

  Value uheaders = Helpers::toMapAny(getp(fetchargs, "headers"));
  if (uheaders.is_map()) {
    for (const auto& item : Struct::items(uheaders)) {
      map_put(ctx->spec->headers, pair_key(item).as_string(), pair_val(item));
    }
  }

  u->prepareAuth(ctx);

  return u->makeFetchDef(ctx);
}

// Is this raw-access op permitted by the SDK's allow.op option?
inline bool SdkClient::opAllowed(const std::string& op) {
  Value allow = Struct::getpath(options, {"allow", "op"});
  if (!allow.is_string()) return false;
  return std::string::npos != allow.as_string().find(op);
}

inline Value SdkClient::opDenied(const std::string& op) {
  Value allow = Struct::getpath(options, {"allow", "op"});
  std::string a = allow.is_string() ? allow.as_string() : "";
  Value out = vmap();
  map_put(out, "ok", Value(false));
  map_put(out, "err", vmap({{"message", Value(
    "UnivecSDK: " + op + ": operation not allowed by"
    " SDK option allow.op value: \"" + a + "\"")}}));
  return out;
}

// Raw endpoint access is operator-controllable, like every entity op.
// Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
// either one reaches the same endpoint.
inline Value SdkClient::direct(const Value& fetchargs_) {
  if (!opAllowed("direct")) return opDenied("direct");
  return rawRequest(fetchargs_);
}

// Raw GraphQL access: the pressure valve that makes the generated surface's
// deliberate omissions (per-call selection sets, typed filter builders,
// batching, subscriptions) livable — the whole schema stays reachable.
//
// Thin wrapper over the same prepare/fetch path direct uses, with the one
// thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200 as
// a top-level `errors` array, so status alone would report a failed query as
// ok.
//
// NOTE: like direct, this bypasses the feature pipeline — no retry, ratelimit
// or paging features apply.
inline Value SdkClient::graphql(const std::string& query, const Value& variables,
                                const Value& ctrl) {
  if (!opAllowed("graphql")) return opDenied("graphql");

  Value res = rawRequest(vmap({
    {"method", Value(std::string("POST"))},
    {"headers", vmap({{"content-type", Value(std::string("application/json"))}})},
    {"body", vmap({
      {"query", Value(query)},
      {"variables", variables.is_map() ? variables : vmap()}})},
    {"ctrl", ctrl.is_map() ? ctrl : vmap()}}));

  // Errors are read BEFORE any status check: a GraphQL parse or validation
  // failure comes back as HTTP 400 carrying the standard { errors: [...] }
  // body, and the raw path represents a non-2xx as ok:false with no err — so
  // returning early on status would discard the server's own diagnostics,
  // which are the only useful part of that response.
  Value errors = getp(getp(res, "data"), "errors");

  if (errors.is_list() && !errors.as_list()->empty()) {
    Value first = (*errors.as_list())[0];
    Value m = getp(first, "message");
    std::string msg = m.is_string() && !m.as_string().empty()
      ? m.as_string() : "graphql error";
    map_put(res, "ok", Value(false));
    map_put(res, "err", vmap({{"message",
      Value("UnivecSDK: graphql: " + msg)}}));
    map_put(res, "graphql", errors);
  }

  return res;
}

// Ungated request path shared by direct and graphql, each of which checks its
// own allow.op token first. Private, rather than a flag on fetchargs: a
// caller-supplied marker would let anyone opt straight back out of the gate
// by passing it.
inline Value SdkClient::rawRequest(const Value& fetchargs_) {
  UtilityPtr u = utility;
  Value fetchargs = fetchargs_.is_map() ? fetchargs_ : vmap();

  Value ctrl = Helpers::toMapAny(getp(fetchargs, "ctrl"));
  if (!ctrl.is_map()) ctrl = vmap();

  CtxSpec cs;
  cs.setOpname("direct");
  cs.ctrlMap = ctrl;
  CtxPtr ctx = u->makeContext(cs, rootctx);

  Value out = vmap();

  Value fetchdef;
  try {
    fetchdef = this->prepare(fetchargs);
  } catch (const SdkErrorPtr& err) {
    map_put(out, "ok", Value(false));
    map_put(out, "err", vmap({{"message", Value(err->msg)}}));
    return out;
  }

  Value url = getp(fetchdef, "url");
  Value fetched;
  try {
    fetched = u->fetcher(ctx, url.is_string() ? url.as_string() : "", fetchdef);
  } catch (const SdkErrorPtr& err) {
    map_put(out, "ok", Value(false));
    map_put(out, "err", vmap({{"message", Value(err->msg)}}));
    return out;
  }

  if (is_nullish(fetched)) {
    map_put(out, "ok", Value(false));
    auto e = ctx->makeError("direct_no_response", "response: undefined");
    map_put(out, "err", vmap({{"message", Value(e->msg)}}));
    return out;
  }

  if (fetched.is_map()) {
    int status = Helpers::toInt(getp(fetched, "status"));
    Value headers = getp(fetched, "headers");

    std::string contentLength = "";
    if (headers.is_map()) {
      Value cl = mapget(headers, "content-length");
      if (!cl.is_undef() && !cl.is_null()) contentLength = Struct::stringify(cl);
    }
    bool noBody = status == 204 || status == 304 || contentLength == "0";

    Value jsonData = Value::undef();
    if (!noBody) {
      Value jf = mapget(fetched, "json");
      if (jf.is_injector()) {
        vs::Injection inj(Value::undef(), Value::undef());
        jsonData = jf.as_injector()(inj, Value::undef(), std::string(""), Value::undef());
      }
    }

    map_put(out, "ok", Value(status >= 200 && status < 300));
    map_put(out, "status", Value(status));
    map_put(out, "headers", headers);
    map_put(out, "data", jsonData);
    return out;
  }

  map_put(out, "ok", Value(false));
  auto e = ctx->makeError("direct_invalid", "invalid response type");
  map_put(out, "err", vmap({{"message", Value(e->msg)}}));
  return out;
}

// ---- EntityBase ----
inline EntityBase::EntityBase(const std::string& name, SdkClient* client_, const Value& entopts_)
    : name_(name), client(client_) {
  Value eo = entopts_.is_map() ? entopts_ : vmap();
  if (!map_contains(eo, "active")) {
    map_put(eo, "active", Value(true));
  } else if (is_false(getp(eo, "active"))) {
    // keep false
  } else {
    map_put(eo, "active", Value(true));
  }

  utility = client_->getUtility();
  entopts = eo;
  data_ = vmap();
  match_ = vmap();

  CtxSpec cs;
  cs.entity = this;
  cs.entopts = eo;
  entctx = utility->makeContext(cs, client_->getRootCtx());

  utility->featureHook(entctx, "PostConstructEntity");
}

inline Value EntityBase::data(const Value& arg) {
  if (!arg.is_undef()) {
    Value d = Helpers::toMapAny(Struct::clone(arg));
    data_ = d.is_map() ? d : vmap();
    utility->featureHook(entctx, "SetData");
  }
  utility->featureHook(entctx, "GetData");
  return Struct::clone(data_);
}

inline Value EntityBase::match(const Value& arg) {
  if (!arg.is_undef()) {
    Value m = Helpers::toMapAny(Struct::clone(arg));
    match_ = m.is_map() ? m : vmap();
    utility->featureHook(entctx, "SetMatch");
  }
  utility->featureHook(entctx, "GetMatch");
  return Struct::clone(match_);
}

inline Value EntityBase::runOp(CtxPtr ctx, const std::function<void()>& postDone) {
  UtilityPtr u = utility;
  try {
    u->featureHook(ctx, "PrePoint");

    Value point = u->makePoint(ctx);
    ctx->out.has_point = true;
    ctx->out.point = point;

    u->featureHook(ctx, "PreSpec");

    SpecPtr spec = u->makeSpec(ctx);
    ctx->out.spec = spec;

    u->featureHook(ctx, "PreRequest");

    ResponsePtr request = u->makeRequest(ctx);
    ctx->out.request = request;

    u->featureHook(ctx, "PreResponse");

    ResponsePtr response = u->makeResponse(ctx);
    ctx->out.response = response;

    u->featureHook(ctx, "PreResult");

    ResultPtr result = u->makeResult(ctx);
    ctx->out.result = result;

    u->featureHook(ctx, "PreDone");

    postDone();

    return u->done(ctx);
  } catch (const SdkErrorPtr& err) {
    if (ctx->ctrl->err && err == ctx->ctrl->err) throw;
    return u->makeError(ctx, err);
  }
}

inline std::vector<Value> EntityBase::stream(const std::string& action,
                                             const Value& args,
                                             const Value& callopts) {
  UtilityPtr u = utility;

  Value streamOpts = callopts.is_map() ? callopts : vmap();

  Value ctrl = Helpers::toMapAny(getp(streamOpts, "ctrl"));
  if (!ctrl.is_map()) ctrl = vmap();
  map_put(ctrl, "stream", streamOpts);

  CtxSpec cs;
  cs.setOpname(action);
  cs.ctrlMap = ctrl;
  cs.match = match_;
  cs.data = data_;
  cs.reqmatch = args.is_map() ? args : vmap();
  CtxPtr ctx = u->makeContext(cs, entctx);

  // Outbound: attach a caller iterable `body` so the transport can stream a
  // request payload.
  Value body = getp(streamOpts, "body");
  if (!is_nullish(body)) {
    Value reqdata = ctx->reqdata.is_map() ? ctx->reqdata : vmap();
    map_put(reqdata, "body$", body);
    ctx->reqdata = reqdata;
  }

  try {
    u->featureHook(ctx, "PrePoint");
    Value point = u->makePoint(ctx);
    ctx->out.has_point = true;
    ctx->out.point = point;

    u->featureHook(ctx, "PreSpec");
    SpecPtr spec = u->makeSpec(ctx);
    ctx->out.spec = spec;

    u->featureHook(ctx, "PreRequest");
    ResponsePtr request = u->makeRequest(ctx);
    ctx->out.request = request;

    u->featureHook(ctx, "PreResponse");
    ResponsePtr response = u->makeResponse(ctx);
    ctx->out.response = response;

    u->featureHook(ctx, "PreResult");
    ResultPtr result = u->makeResult(ctx);
    ctx->out.result = result;

    u->featureHook(ctx, "PreDone");

    // Inbound: prefer the streaming feature's incremental producer; else fall
    // back to the materialised items so stream always yields.
    ResultPtr res = ctx->result;
    if (res && res->stream) {
      return res->stream();
    }

    Value data = u->done(ctx);
    std::vector<Value> out;
    if (data.is_list()) {
      for (const auto& item : *data.as_list()) out.push_back(item);
    } else if (!is_nullish(data)) {
      out.push_back(data);
    }
    return out;
  } catch (const SdkErrorPtr& err) {
    if (ctx->ctrl->err && err == ctx->ctrl->err) throw;
    u->makeError(ctx, err);
    return std::vector<Value>();
  }
}

} // namespace sdk

#endif // SDK_CORE_TYPES_HPP
