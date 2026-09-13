// Univec SDK — pipeline utility builders (mirrors java utility/*.java).
//
// Every pipeline step is a free function bound onto the Utility function
// fields by register_all(). Features and tests may replace individual
// fields (notably `fetcher`) on a per-instance basis.

#ifndef SDK_UTILITY_PIPELINE_HPP
#define SDK_UTILITY_PIPELINE_HPP

#include <algorithm>
#include <memory>
#include <cctype>
#include <string>
#include <vector>

#include "../core/types.hpp"

namespace sdk {
namespace util {

// ---- small string helper ---------------------------------------------

inline std::string replace_all(std::string s, const std::string& from, const std::string& to) {
  if (from.empty()) return s;
  size_t pos = 0;
  while ((pos = s.find(from, pos)) != std::string::npos) {
    s.replace(pos, from.size(), to);
    pos += to.size();
  }
  return s;
}

// ---- makeContext ------------------------------------------------------

inline CtxPtr makeContext(const CtxSpec& cs, CtxPtr basectx) {
  return std::make_shared<Context>(cs, basectx);
}

// ---- clean ------------------------------------------------------------

inline Value clean(CtxPtr ctx, const Value& val) { return val; }

// ---- makeError --------------------------------------------------------

// Forward declaration: makeError fires the PreUnexpected feature hook, whose
// definition appears later in this header.
inline void featureHook(CtxPtr ctx, const std::string& name);

inline Value makeError(CtxPtr ctx, SdkErrorPtr err) {
  std::string opname = (!ctx->op) ? "" : ctx->op->name;
  if (opname.empty() || opname == "_") opname = "unknown operation";

  ResultPtr result = ctx->result;
  if (!result) result = std::make_shared<Result>();
  result->ok = false;

  if (!err) err = result->err;
  if (!err) err = ctx->makeError("unknown", "unknown error");

  std::string errmsg = err->getMessage();
  std::string msg = "UnivecSDK: " + opname + ": " + errmsg;

  result->err = nullptr;

  SpecPtr spec = ctx->spec;

  if (ctx->ctrl->explain.is_map()) {
    Value errRecord = vmap();
    map_put(errRecord, "message", Value(msg));
    map_put(ctx->ctrl->explain, "err", errRecord);
  }

  std::string code = err->code;

  auto sdkErr = std::make_shared<SdkError>(code, msg, ctx.get());
  sdkErr->result_obj = result;
  sdkErr->spec_obj = spec;

  ctx->ctrl->err = sdkErr;

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after ctx->ctrl->err is set so hooks can read
  // the error; features guard against double-recording when PreDone fired.
  featureHook(ctx, "PreUnexpected");

  if (is_false(ctx->ctrl->throwing)) {
    return result->resdata;
  }

  throw sdkErr;
}

// ---- done -------------------------------------------------------------

inline Value done(CtxPtr ctx) {
  if (ctx->ctrl->explain.is_map()) {
    Value explainResult = getp(ctx->ctrl->explain, "result");
    Value rm = Helpers::toMapAny(explainResult);
    if (rm.is_map()) map_remove(rm, "err");
  }

  if (ctx->result && ctx->result->ok) {
    return ctx->result->resdata;
  }

  return makeError(ctx, nullptr);
}

// ---- featureAdd -------------------------------------------------------

inline void featureAdd(CtxPtr ctx, FeaturePtr f) {
  SdkClient* client = ctx->client;
  auto& features = client->features;

  Value fopts = f->addOptions();

  if (fopts.is_map()) {
    std::string before = as_str(getp(fopts, "__before__"));
    std::string after = as_str(getp(fopts, "__after__"));
    std::string replace = as_str(getp(fopts, "__replace__"));

    if (!before.empty() || !after.empty() || !replace.empty()) {
      for (size_t i = 0; i < features.size(); i++) {
        std::string name = features[i]->getName();
        if (before == name) {
          features.insert(features.begin() + i, f);
          return;
        }
        if (after == name) {
          features.insert(features.begin() + i + 1, f);
          return;
        }
        if (replace == name) {
          features[i] = f;
          return;
        }
      }
    }
  }

  features.push_back(f);
}

// ---- featureInit ------------------------------------------------------

inline void featureInit(CtxPtr ctx, FeaturePtr f) {
  std::string fname = f->getName();
  Value fopts = vmap();

  if (ctx->options.is_map()) {
    Value featureOpts = Helpers::toMapAny(getp(ctx->options, "feature"));
    if (featureOpts.is_map()) {
      Value fo = Helpers::toMapAny(getp(featureOpts, fname));
      if (fo.is_map()) fopts = fo;
    }
  }

  if (is_true(getp(fopts, "active"))) {
    f->init(ctx, fopts);
  }
}

// ---- featureHook (name -> virtual dispatch; no reflection) ------------

inline void dispatch_hook(const FeaturePtr& f, const std::string& name, const CtxPtr& ctx) {
  if (name == "PostConstruct") f->postConstruct(ctx);
  else if (name == "PostConstructEntity") f->postConstructEntity(ctx);
  else if (name == "SetData") f->setData(ctx);
  else if (name == "GetData") f->getData(ctx);
  else if (name == "GetMatch") f->getMatch(ctx);
  else if (name == "SetMatch") f->setMatch(ctx);
  else if (name == "PrePoint") f->prePoint(ctx);
  else if (name == "PreSpec") f->preSpec(ctx);
  else if (name == "PreRequest") f->preRequest(ctx);
  else if (name == "PreResponse") f->preResponse(ctx);
  else if (name == "PreResult") f->preResult(ctx);
  else if (name == "PreDone") f->preDone(ctx);
  else if (name == "PreUnexpected") f->preUnexpected(ctx);
}

inline void featureHook(CtxPtr ctx, const std::string& name) {
  SdkClient* client = ctx->client;
  if (client == nullptr) return;
  if (name.empty()) return;
  std::vector<FeaturePtr> snapshot = client->features;
  for (auto& f : snapshot) {
    dispatch_hook(f, name, ctx);
  }
}

// ---- fetcher ----------------------------------------------------------

inline Value fetcher(CtxPtr ctx, const std::string& fullurl, const Value& fetchdef) {
  if (ctx->client->mode != "live") {
    throw ctx->makeError("fetch_mode_block",
        "Request blocked by mode: \"" + ctx->client->mode + "\" (URL was: \"" + fullurl + "\")");
  }

  Value options = ctx->client->optionsMap();
  if (is_true(Struct::getpath(options, {"feature", "test", "active"}))) {
    throw ctx->makeError("fetch_test_block",
        "Request blocked as test feature is active (URL was: \"" + fullurl + "\")");
  }

  Value sysFetch = Struct::getpath(options, {"system", "fetch"});

  if (sysFetch.is_injector()) {
    vs::Injection inj(Value::undef(), Value::undef());
    Value args = vlist({Value(fullurl), fetchdef});
    return sysFetch.as_injector()(inj, args, std::string(""), Value::undef());
  }

  if (is_nullish(sysFetch)) {
    // No live HTTP transport is built into the generated C++ SDK; supply a
    // system.fetch callable for live requests.
    throw ctx->makeError("fetch_no_transport",
        "live HTTP transport not available; provide options.system.fetch");
  }

  throw ctx->makeError("fetch_invalid", "system.fetch is not a valid function");
}

// ---- makeFetchDef -----------------------------------------------------

inline Value makeFetchDef(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) {
    throw ctx->makeError("fetchdef_no_spec", "Expected context spec property to be defined.");
  }

  if (!ctx->result) ctx->result = std::make_shared<Result>();

  spec->step = "prepare";

  std::string url = ctx->utility->makeUrl(ctx);
  spec->url = url;

  Value fetchdef = vmap();
  map_put(fetchdef, "url", Value(url));
  map_put(fetchdef, "method", Value(spec->method));
  map_put(fetchdef, "headers", spec->headers);

  if (!is_nullish(spec->body)) {
    if (spec->body.is_map()) {
      map_put(fetchdef, "body", Value(Struct::jsonify(spec->body)));
    } else {
      map_put(fetchdef, "body", spec->body);
    }
  }

  return fetchdef;
}

// ---- makeUrl ----------------------------------------------------------

inline std::string makeUrl(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;
  if (!spec) throw ctx->makeError("url_no_spec", "Expected context spec property to be defined.");
  if (!result) throw ctx->makeError("url_no_result", "Expected context result property to be defined.");

  Value joinParts = vlist({Value(spec->base), Value(spec->prefix), Value(spec->path), Value(spec->suffix)});
  std::string url = Struct::join(joinParts, "/", true);

  Value resmatch = vmap();

  for (const auto& item : Struct::items(spec->params)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val)) {
      url = replace_all(url, "{" + key + "}", Struct::escurl(Value(Struct::stringify(val))));
      map_put(resmatch, key, val);
    }
  }

  std::string qsep = "?";
  for (const auto& item : Struct::items(spec->query)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val)) {
      url += qsep + Struct::escurl(Value(key)) + "=" + Struct::escurl(Value(Struct::stringify(val)));
      qsep = "&";
      map_put(resmatch, key, val);
    }
  }

  result->resmatch = resmatch;
  return url;
}

// ---- makePoint --------------------------------------------------------

inline Value makePoint(CtxPtr ctx) {
  // A PrePoint feature hook (e.g. rbac) may short-circuit by storing an
  // error; surface it before any endpoint resolution or network activity.
  if (ctx->out.pointError) {
    throw ctx->out.pointError;
  }
  if (ctx->out.has_point && ctx->out.point.is_map()) {
    ctx->point = ctx->out.point;
    return ctx->point;
  }

  OperationPtr op = ctx->op;
  Value options = ctx->options;

  std::string allowOp = as_str(Struct::getpath(options, {"allow", "op"}));
  if (allowOp.find(op->name) == std::string::npos) {
    throw ctx->makeError("point_op_allow",
        "Operation \"" + op->name + "\" not allowed by SDK option allow.op value: \"" + allowOp + "\"");
  }

  if (op->points.empty()) {
    throw ctx->makeError("point_no_points",
        "Operation \"" + op->name + "\" has no endpoint definitions.");
  }

  if (op->points.size() == 1) {
    ctx->point = op->points[0];
  } else {
    Value reqselector;
    Value selector;
    if (op->input == "data") {
      reqselector = ctx->reqdata;
      selector = ctx->data;
    } else {
      reqselector = ctx->reqmatch;
      selector = ctx->match;
    }

    Value point;
    bool matched = false;
    for (size_t i = 0; i < op->points.size(); i++) {
      Value cand = op->points[i];
      Value selectDef = Helpers::toMapAny(getp(cand, "select"));
      bool found = true;

      if (selector.is_map() && selectDef.is_map()) {
        Value exist = getp(selectDef, "exist");
        if (exist.is_list()) {
          for (const auto& ek : *exist.as_list()) {
            std::string existkey = ek.is_string() ? ek.as_string() : "";
            Value rv = getp(reqselector, existkey, Value(nullptr));
            Value sv = getp(selector, existkey, Value(nullptr));
            if (rv.is_null() && sv.is_null()) {
              found = false;
              break;
            }
          }
        }
      }

      if (found) {
        Value reqAction = getp(reqselector, "$action", Value(nullptr));
        Value selectAction = getp(selectDef, "$action", Value(nullptr));
        if (reqAction != selectAction) found = false;
      }

      if (found) {
        point = cand;
        matched = true;
        break;
      }
    }

    // select.exist can list more than the params needed to pick a point (for
    // /boards/{id} it is Trello's 17 optional query-includes), so a plain
    // {id} call matches NOTHING. Fall back to the entity's own route rather
    // than whichever point came last.
    if (!matched) {
      // A request naming an action reaches here only because that action's
      // own point failed its exist test, so it is unbuildable whatever we
      // pick. Refuse it BEFORE choosing a fallback: the guard below compares
      // the chosen point's $action and would wave the request through
      // whenever the fallback lands on the action point itself.
      Value unmatchedAction = getp(reqselector, "$action", Value(nullptr));
      if (!unmatchedAction.is_null()) {
        throw ctx->makeError("point_action_invalid",
            "Operation \"" + op->name + "\" action \"" +
            Struct::stringify(unmatchedAction) + "\" is not valid.");
      }

      // A terminal parameter marks a record route (/boards/{id}); a
      // cross-reference ends in the relationship's name (/posts/{id}/author).
      // Failing that, the shallower path wins. The same rule runs at
      // generation time, in helpers/opShape.ts — both sides must move
      // together.
      auto partsLen = [](const Value& p) -> size_t {
        Value parts = getp(p, "parts");
        return parts.is_list() ? parts.as_list()->size() : 0;
      };
      auto terminalParam = [](const Value& p) -> bool {
        Value parts = getp(p, "parts");
        if (!parts.is_list() || parts.as_list()->empty()) return false;
        const Value& last = parts.as_list()->back();
        return last.is_string() && 0 == last.as_string().rfind("{", 0);
      };

      point = op->points[0];
      for (size_t i = 0; i < op->points.size(); i++) {
        const Value& cand = op->points[i];
        bool candTerm = terminalParam(cand);
        bool bestTerm = terminalParam(point);
        if (candTerm != bestTerm) {
          if (candTerm) point = cand;
        }
        else if (partsLen(cand) < partsLen(point)) {
          point = cand;
        }
      }
    }

    if (reqselector.is_map()) {
      Value reqAction = getp(reqselector, "$action", Value(nullptr));
      if (!reqAction.is_null() && point.is_map()) {
        Value pointSelect = Helpers::toMapAny(getp(point, "select"));
        Value pointAction = getp(pointSelect, "$action", Value(nullptr));
        if (reqAction != pointAction) {
          throw ctx->makeError("point_action_invalid",
              "Operation \"" + op->name + "\" action \"" + Struct::stringify(reqAction) + "\" is not valid.");
        }
      }
    }

    ctx->point = point;
  }

  return ctx->point;
}

// ---- graphql ----------------------------------------------------------
//
// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this unchanged. The API-specific part — which operations
// exist and what each one's document is — is model data, computed once by
// apidef and emitted into Config.

// Content type every GraphQL-over-HTTP request uses.
inline const char* graphqlContentType() { return "application/json"; }

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
inline std::string graphqlErrorCode(const Value& gqlerr) {
  Value ext = getp(gqlerr, "extensions");

  std::string raw = as_str(getp(ext, "code"));
  if (raw.empty()) raw = as_str(getp(ext, "type"));
  for (auto& ch : raw) ch = (char)std::toupper((unsigned char)ch);

  if (raw.find("AUTH") != std::string::npos ||
      raw.find("FORBIDDEN") != std::string::npos ||
      raw.find("UNAUTHENTICATED") != std::string::npos) {
    return "request_auth";
  }
  if (raw.find("RATELIMIT") != std::string::npos ||
      raw.find("RATE_LIMIT") != std::string::npos ||
      raw.find("TOO_MANY") != std::string::npos) {
    return "request_ratelimit";
  }
  if (raw.find("BAD_USER_INPUT") != std::string::npos ||
      raw.find("VALIDATION") != std::string::npos ||
      raw.find("INVALID") != std::string::npos) {
    return "request_invalid";
  }

  return "request_graphql";
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty
// `from`) takes the request data as a whole — which is what makes a
// generated create/update call look exactly like its REST equivalent.
inline Value graphqlBody(CtxPtr ctx) {
  Value gql = getp(ctx->point, "graphql");
  if (!gql.is_map()) return Value::undef();

  // reqmatch/reqdata hold the caller's arguments for this operation; which
  // one depends on whether the op takes match or data input.
  Value reqsrc = ctx->reqmatch;
  Value datasrc = ctx->match;
  if (ctx->op && ctx->op->input == "data") {
    reqsrc = ctx->reqdata;
    datasrc = ctx->data;
  }
  if (!reqsrc.is_map()) reqsrc = vmap();
  if (!datasrc.is_map()) datasrc = vmap();

  Value variables = vmap();

  Value varlist = getp(gql, "vars");
  if (varlist.is_list()) {
    for (const auto& spec : *varlist.as_list()) {
      if (!spec.is_map()) continue;

      std::string name = as_str(getp(spec, "name"));
      std::string from = as_str(getp(spec, "from"));

      if (from.empty()) {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        Value body = vmap();
        for (const auto& item : Struct::items(reqsrc)) {
          std::string key = as_str(pair_key(item));
          if ("$action" != key) map_put(body, key, pair_val(item));
        }
        map_put(variables, name, body);
        continue;
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      Value val = getp(reqsrc, from);
      if (is_nullish(val)) val = getp(datasrc, from);
      if (!is_nullish(val)) map_put(variables, name, val);
    }
  }

  Value out = vmap();
  map_put(out, "query", getp(gql, "doc"));
  map_put(out, "variables", variables);

  return out;
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing.
inline bool graphqlErrors(CtxPtr ctx) {
  if (!ctx->result) return false;
  if ("graphql" != as_str(getp(ctx->point, "kind"))) return false;

  Value errors = getp(ctx->result->body, "errors");
  if (!errors.is_list()) return false;

  const auto& el = *errors.as_list();
  if (el.empty()) return false;

  Value first = el[0];
  std::string msg = as_str(getp(first, "message"));
  if (msg.empty()) msg = "graphql error";
  if (1 < el.size()) {
    msg = msg + " (+" + std::to_string(el.size() - 1) + " more)";
  }

  ctx->result->err = ctx->makeError(graphqlErrorCode(first), "graphql: " + msg);
  ctx->result->ok = false;

  return true;
}

// ---- makeSpec ---------------------------------------------------------

inline SpecPtr makeSpec(CtxPtr ctx) {
  if (ctx->out.spec) {
    ctx->spec = ctx->out.spec;
    return ctx->spec;
  }

  Value point = ctx->point;
  Value options = ctx->options;
  UtilityPtr utility = ctx->utility;

  Value base = getp(options, "base");
  Value prefix = getp(options, "prefix");
  Value suffix = getp(options, "suffix");
  Value parts = getp(point, "parts");

  Value specmap = vmap();
  map_put(specmap, "base", base.is_string() ? base : Value(""));
  map_put(specmap, "prefix", prefix.is_string() ? prefix : Value(""));
  if (parts.is_list()) map_put(specmap, "parts", parts);
  map_put(specmap, "suffix", suffix.is_string() ? suffix : Value(""));
  map_put(specmap, "step", Value("start"));
  ctx->spec = std::make_shared<Spec>(specmap);

  ctx->spec->method = utility->prepareMethod(ctx);

  std::string allowMethod = as_str(Struct::getpath(options, {"allow", "method"}));
  if (allowMethod.find(ctx->spec->method) == std::string::npos) {
    throw ctx->makeError("spec_method_allow",
        "Method \"" + ctx->spec->method + "\" not allowed by SDK option allow.method value: \"" + allowMethod + "\"");
  }

  ctx->spec->params = utility->prepareParams(ctx);
  ctx->spec->query = utility->prepareQuery(ctx);
  ctx->spec->headers = utility->prepareHeaders(ctx);

  if ("graphql" == as_str(getp(ctx->point, "kind"))) {
    // GraphQL addresses one endpoint: no path parts, no query string, and
    // the body carries the operation. prepareBody is skipped deliberately
    // — it only emits a body for data-input ops, whereas every GraphQL op
    // posts one, including load/list/remove.
    ctx->spec->body = graphqlBody(ctx);
    ctx->spec->path = "";
    // prepareQuery already copied the op's match arguments into the query
    // string. Those same values are bound as operation variables, so
    // leaving them would send /graphql?id=i1.
    ctx->spec->query = vmap();
    map_put(ctx->spec->headers, "content-type", Value(graphqlContentType()));
  } else {
    ctx->spec->body = utility->prepareBody(ctx);
    ctx->spec->path = utility->preparePath(ctx);
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "spec", ctx->spec->toValue());
  }

  SpecPtr spec = utility->prepareAuth(ctx);
  ctx->spec = spec;
  return spec;
}

// ---- makeRequest ------------------------------------------------------

inline ResponsePtr makeRequest(CtxPtr ctx) {
  if (ctx->out.request) {
    return ctx->out.request;
  }

  SpecPtr spec = ctx->spec;
  UtilityPtr utility = ctx->utility;

  auto response = std::make_shared<Response>();
  auto result = std::make_shared<Result>();
  ctx->result = result;

  if (!spec) throw ctx->makeError("request_no_spec", "Expected context spec property to be defined.");

  Value fetchdef;
  try {
    fetchdef = utility->makeFetchDef(ctx);
  } catch (const SdkErrorPtr& err) {
    response->err = err;
    ctx->response = response;
    spec->step = "postrequest";
    return response;
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "fetchdef", fetchdef);
  }

  spec->step = "prerequest";

  Value url = getp(fetchdef, "url");
  Value fetched;
  SdkErrorPtr fetchErr;
  try {
    fetched = utility->fetcher(ctx, url.is_string() ? url.as_string() : "", fetchdef);
  } catch (const SdkErrorPtr& err) {
    fetchErr = err;
  }

  if (fetchErr) {
    response->err = fetchErr;
  } else if (is_nullish(fetched)) {
    Value resmap = vmap();
    ctx->response = response; // placeholder
    auto e = ctx->makeError("request_no_response", "response: undefined");
    response = std::make_shared<Response>();
    response->err = e;
  } else if (fetched.is_map()) {
    response = std::make_shared<Response>(fetched);
  } else {
    response->err = ctx->makeError("request_invalid_response", "response: invalid type");
  }

  spec->step = "postrequest";
  ctx->response = response;
  return response;
}

// ---- resultBasic ------------------------------------------------------

inline ResultPtr resultBasic(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result && response) {
    result->status = response->status;
    result->statusText = response->statusText;

    if (result->status >= 400) {
      std::string msg = "request: " + std::to_string(result->status) + ": " + result->statusText;
      if (result->err) {
        std::string prevmsg = result->err->getMessage();
        result->err = ctx->makeError("request_status", prevmsg + ": " + msg);
      } else {
        result->err = ctx->makeError("request_status", msg);
      }
    } else if (response->err) {
      result->err = response->err;
    }
  }

  return result;
}

// ---- resultHeaders ----------------------------------------------------

inline ResultPtr resultHeaders(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result) {
    if (response && response->headers.is_map()) {
      result->headers = response->headers;
    } else {
      result->headers = vmap();
    }
  }
  return result;
}

// ---- resultBody -------------------------------------------------------

inline ResultPtr resultBody(CtxPtr ctx) {
  ResponsePtr response = ctx->response;
  ResultPtr result = ctx->result;

  if (result) {
    if (response && response->jsonFunc && !is_nullish(response->body)) {
      result->body = response->jsonFunc();
    }
  }
  return result;
}

// ---- transformResponse ------------------------------------------------

inline Value transformResponse(CtxPtr ctx) {
  ResultPtr result = ctx->result;

  if (ctx->spec) ctx->spec->step = "resform";

  if (!result || !result->ok) return Value::undef();

  Value transform = Helpers::toMapAny(getp(ctx->point, "transform"));
  if (!transform.is_map()) return Value::undef();

  Value resform = getp(transform, "res");
  if (is_nullish(resform)) return Value::undef();

  Value data = vmap();
  map_put(data, "ok", Value(result->ok));
  map_put(data, "status", Value(result->status));
  map_put(data, "statusText", Value(result->statusText));
  map_put(data, "headers", result->headers);
  map_put(data, "body", result->body);
  if (result->err) map_put(data, "err", vmap({{"message", Value(result->err->msg)}}));
  map_put(data, "resdata", result->resdata);
  map_put(data, "resmatch", result->resmatch);

  Value resdata = Struct::transform(data, resform);
  result->resdata = resdata;
  return resdata;
}

// ---- makeResponse -----------------------------------------------------

inline ResponsePtr makeResponse(CtxPtr ctx) {
  if (ctx->out.response) {
    return ctx->out.response;
  }

  UtilityPtr utility = ctx->utility;
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;
  ResponsePtr response = ctx->response;

  if (!spec) throw ctx->makeError("response_no_spec", "Expected context spec property to be defined.");
  if (!response) throw ctx->makeError("response_no_response", "Expected context response property to be defined.");
  if (!result) throw ctx->makeError("response_no_result", "Expected context result property to be defined.");

  spec->step = "response";

  utility->resultBasic(ctx);
  utility->resultHeaders(ctx);
  utility->resultBody(ctx);

  // GraphQL reports failures as a top-level `errors` array under HTTP 200,
  // so resultBasic's status check never sees them. Lift them here, before
  // the response transform tries to unwrap data that is not there.
  graphqlErrors(ctx);

  utility->transformResponse(ctx);

  if (!result->err) result->ok = true;

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "result", result->toValue());
  }

  return response;
}

// ---- makeResult -------------------------------------------------------

inline ResultPtr makeResult(CtxPtr ctx) {
  if (ctx->out.result) {
    return ctx->out.result;
  }

  UtilityPtr utility = ctx->utility;
  OperationPtr op = ctx->op;
  Entity* entity = ctx->entity;
  SpecPtr spec = ctx->spec;
  ResultPtr result = ctx->result;

  if (!spec) throw ctx->makeError("result_no_spec", "Expected context spec property to be defined.");
  if (!result) throw ctx->makeError("result_no_result", "Expected context result property to be defined.");

  spec->step = "result";

  utility->transformResponse(ctx);

  if (op->name == "list") {
    Value resdata = result->resdata;
    result->resdata = vlist();

    if (resdata.is_list() && !resdata.as_list()->empty() && entity != nullptr) {
      // The java donor wraps each item into an Entity object; C++ Value
      // cannot hold entity instances, so the list result carries the item
      // data maps (entityListToData treats a map item as its own data).
      // Entities are still constructed + data()-loaded so hooks fire and
      // per-item side effects match the donor.
      Value entities = vlist();
      for (const auto& entry : *resdata.as_list()) {
        EntityPtr ent = entity->make();
        if (entry.is_map()) ent->data(entry);
        entities.as_list()->push_back(entry);
        (void)ent;
      }
      result->resdata = entities;
    }
  }

  if (ctx->ctrl->explain.is_map()) {
    map_put(ctx->ctrl->explain, "result", result->toValue());
  }

  return result;
}

// ---- prepareMethod ----------------------------------------------------

inline std::string prepareMethod(CtxPtr ctx) {
  const std::string& opname = ctx->op->name;

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  Value pm = getp(ctx->point, "method");
  if (pm.is_string()) {
    std::string m = as_str(pm);
    if (!m.empty()) {
      for (auto& c : m) c = (char)std::toupper((unsigned char)c);
      return m;
    }
  }

  if (opname == "create") return "POST";
  if (opname == "update") return "PUT";
  if (opname == "load") return "GET";
  if (opname == "list") return "GET";
  if (opname == "remove") return "DELETE";
  if (opname == "patch") return "PATCH";

  // An op the API does not define resolves NO method — ts answers undefined
  // here (`methodMap[key]`), and "" is C++'s spelling of the same "no
  // value", as it is go's. The stray "GET" that used to sit here was hidden
  // by the retired silent-pass engine; the shared corpus pins it now
  // (primary.prepareMethod, opname "bad" -> no output).
  return "";
}

// ---- prepareBody ------------------------------------------------------

inline Value prepareBody(CtxPtr ctx) {
  if (ctx->op->input == "data") {
    return ctx->utility->transformRequest(ctx);
  }
  return Value::undef();
}

// ---- prepareHeaders ---------------------------------------------------

inline Value prepareHeaders(CtxPtr ctx) {
  Value options = ctx->client->optionsMap();
  Value headers = getp(options, "headers");
  if (is_nullish(headers)) return vmap();
  Value out = Helpers::toMapAny(Struct::clone(headers));
  return out.is_map() ? out : vmap();
}

// ---- param ------------------------------------------------------------

inline Value param(CtxPtr ctx, const Value& paramdef) {
  Value point = ctx->point;
  SpecPtr spec = ctx->spec;
  Value match = ctx->match;
  Value reqmatch = ctx->reqmatch;
  Value data = ctx->data;
  Value reqdata = ctx->reqdata;

  int pt = Struct::typify(paramdef);

  std::string key;
  if (0 < (Struct::T_string & pt)) {
    key = paramdef.is_string() ? paramdef.as_string() : "";
  } else {
    Value k = getp(paramdef, "name");
    key = k.is_string() ? k.as_string() : "";
  }

  std::string akey = "";
  if (point.is_map()) {
    Value alias = Helpers::toMapAny(getp(point, "alias"));
    if (alias.is_map()) {
      Value ak = getp(alias, key);
      if (ak.is_string()) akey = ak.as_string();
    }
  }

  Value val = getp(reqmatch, key, Value(nullptr));
  if (val.is_null()) val = getp(match, key, Value(nullptr));
  if (val.is_null() && !akey.empty()) {
    if (spec) map_put(spec->alias, akey, Value(key));
    val = getp(reqmatch, akey, Value(nullptr));
  }
  if (val.is_null()) val = getp(reqdata, key, Value(nullptr));
  if (val.is_null()) val = getp(data, key, Value(nullptr));
  if (val.is_null() && !akey.empty()) {
    val = getp(reqdata, akey, Value(nullptr));
    if (val.is_null()) val = getp(data, akey, Value(nullptr));
  }

  return val;
}

// ---- prepareParams ----------------------------------------------------

inline Value prepareParams(CtxPtr ctx) {
  UtilityPtr utility = ctx->utility;
  Value point = ctx->point;

  Value params = Value::undef();
  Value argsMap = Helpers::toMapAny(getp(point, "args"));
  if (argsMap.is_map()) {
    Value p = getp(argsMap, "params");
    if (p.is_list()) params = p;
  }
  if (!params.is_list()) params = vlist();

  Value out = vmap();
  for (const auto& pd : *params.as_list()) {
    Value val = utility->param(ctx, pd);
    if (!is_nullish(val)) {
      Value pdm = Helpers::toMapAny(pd);
      if (pdm.is_map()) {
        Value name = getp(pdm, "name");
        if (name.is_string() && !name.as_string().empty()) {
          map_put(out, name.as_string(), val);
        }
      }
    }
  }
  return out;
}

// ---- prepareQuery -----------------------------------------------------

inline Value prepareQuery(CtxPtr ctx) {
  Value point = ctx->point;
  Value reqmatch = ctx->reqmatch;
  if (!reqmatch.is_map()) reqmatch = vmap();

  Value params = Value::undef();
  if (point.is_map()) {
    Value p = getp(point, "params");
    if (p.is_list()) params = p;
  }
  if (!params.is_list()) params = vlist();

  auto contains_str = [&](const Value& list, const std::string& s) {
    for (const auto& v : *list.as_list()) {
      if (v.is_string() && v.as_string() == s) return true;
    }
    return false;
  };

  Value out = vmap();
  for (const auto& item : Struct::items(reqmatch)) {
    std::string key = as_str(pair_key(item));
    Value val = pair_val(item);
    if (!is_nullish(val) && !contains_str(params, key)) {
      map_put(out, key, val);
    }
  }
  return out;
}

// ---- preparePath ------------------------------------------------------

inline std::string preparePath(CtxPtr ctx) {
  Value parts = getp(ctx->point, "parts");
  if (!parts.is_list()) parts = vlist();
  return Struct::join(parts, "/", true);
}

// ---- prepareAuth ------------------------------------------------------

inline SpecPtr prepareAuth(CtxPtr ctx) {
  SpecPtr spec = ctx->spec;
  if (!spec) throw ctx->makeError("auth_no_spec", "Expected context spec property to be defined.");

  static const std::string HEADER_AUTH = "authorization";
  static const std::string NOT_FOUND = "__NOTFOUND__";

  Value headers = spec->headers;
  Value options = ctx->client->optionsMap();

  if (is_nullish(getp(options, "auth"))) {
    map_remove(headers, HEADER_AUTH);
    return spec;
  }

  Value apikey = getp(options, "apikey", Value(NOT_FOUND));

  bool skip = false;
  if (is_nullish(apikey)) {
    skip = true;
  } else if (apikey.is_string() && (apikey.as_string() == NOT_FOUND || apikey.as_string().empty())) {
    skip = true;
  }

  if (skip) {
    map_remove(headers, HEADER_AUTH);
  } else {
    std::string authPrefix = as_str(Struct::getpath(options, {"auth", "prefix"}));
    std::string apikeyVal = apikey.is_string() ? apikey.as_string() : "";
    if (authPrefix.empty()) {
      map_put(headers, HEADER_AUTH, Value(apikeyVal));
    } else {
      map_put(headers, HEADER_AUTH, Value(authPrefix + " " + apikeyVal));
    }
  }

  return spec;
}

// ---- transformRequest -------------------------------------------------

inline Value transformRequest(CtxPtr ctx) {
  if (ctx->spec) ctx->spec->step = "reqform";

  Value transform = Helpers::toMapAny(getp(ctx->point, "transform"));
  if (!transform.is_map()) return ctx->reqdata;

  Value reqform = getp(transform, "req");
  if (is_nullish(reqform)) return ctx->reqdata;

  Value data = vmap();
  map_put(data, "reqdata", ctx->reqdata);
  return Struct::transform(data, reqform);
}

// ---- makeOptions ------------------------------------------------------

inline const char* OPTSPEC_JSON() {
  return "{"
    "\"apikey\": \"\","
    "\"base\": \"http://localhost:8000\","
    "\"prefix\": \"\","
    "\"suffix\": \"\","
    "\"auth\": { \"prefix\": \"\" },"
    "\"headers\": { \"`$CHILD`\": \"`$STRING`\" },"
    "\"allow\": {"
    "  \"method\": \"GET,PUT,POST,PATCH,DELETE,OPTIONS\","
    "  \"op\": \"create,update,load,list,remove,command,direct,graphql\""
    "},"
    "\"entity\": { \"`$CHILD`\": {"
    "  \"`$OPEN`\": true, \"active\": false, \"alias\": {} } },"
    "\"feature\": { \"`$CHILD`\": {"
    "  \"`$OPEN`\": true, \"active\": false } },"
    "\"utility\": {},"
    "\"system\": {},"
    "\"test\": { \"active\": false, \"entity\": { \"`$OPEN`\": true } },"
    "\"clean\": { \"keys\": \"key,token,id\" }"
    "}";
}

inline Value makeOptions(CtxPtr ctx) {
  Value options = ctx->options;
  if (!options.is_map()) options = vmap();

  // Merge custom utility overrides onto the utility object BEFORE clone —
  // struct clone preserves function Values, but we read from the original
  // to match the donors and keep the (function) values intact.
  Value customUtils = Helpers::toMapAny(getp(options, "utility"));
  if (customUtils.is_map() && ctx->utility) {
    for (const auto& item : Struct::items(customUtils)) {
      map_put(ctx->utility->custom, as_str(pair_key(item)), pair_val(item));
    }
  }

  // `auth: null` is the documented way to disable auth outright, and
  // prepareAuth honours it before it ever reads the apikey. It cannot survive
  // validate: this port follows the Group A rule, so a stored null reads as
  // "no value" and the optspec's `auth` default fires instead - transmitting
  // the credential the caller withheld. Withhold the key for validate, then
  // put the null back. Same fix as ts/js/go makeOptions.
  //
  // mapget rather than getp: getp applies Group A and collapses a stored null
  // to undef, so it cannot tell an ABSENT auth from a suppressed one. And the
  // test is is_null, NOT is_nullish - a present-but-UNDEF auth is a missing
  // value, which the ts/js reference lets the optspec default fill in. Only an
  // explicit null is a suppression.
  bool authSuppressed = mapget(options, "auth").is_null();

  Value opts = Struct::clone(options);

  if (authSuppressed) {
    map_remove(opts, "auth");
  }

  // Feature add-order. options.feature may be an ordered list of
  // { name, active, ...opts } entries (the list position IS the order in which
  // features are added), or a { name: {opts} } map. Normalize a list to a map
  // (so merge/validate are unchanged) and remember the explicit order; a map
  // defaults to test-first so the `test` mock transport is installed as the
  // base of the transport wrapper chain.
  std::vector<std::string> featureOrder;
  {
    Value rawFeature = getp(opts, "feature");
    if (rawFeature.is_list()) {
      Value fmap = vmap();
      for (const auto& entry : *rawFeature.as_list()) {
        if (entry.is_map()) {
          Value nameV = getp(entry, "name");
          if (nameV.is_string()) {
            std::string nm = nameV.as_string();
            Value fopts = Struct::clone(entry);
            map_remove(fopts, "name");
            map_put(fmap, nm, fopts);
            featureOrder.push_back(nm);
          }
        }
      }
      map_put(opts, "feature", fmap);
    }
  }

  Value config = ctx->config;
  if (!config.is_map()) config = vmap();
  Value cfgopts = Helpers::toMapAny(getp(config, "options"));
  if (!cfgopts.is_map()) cfgopts = vmap();

  Value optspec = vs::parse_json(OPTSPEC_JSON());

  // Preserve system.fetch before merge/validate (a function Value may be
  // dropped by validate).
  Value sysFetch = Struct::getpath(opts, {"system", "fetch"});

  // CLONE the config side: `config` is a process-wide singleton (sharedConfig)
  // and merge uses its nested maps as merge TARGETS, so without this one
  // client's options (headers, server, ...) are written into the shared config
  // and inherited by every client constructed afterwards.
  Value mergeList = vlist({vmap(), Struct::clone(cfgopts), opts});
  Value merged = Struct::merge(mergeList);

  Value vopts = vmap();
  map_put(vopts, "errs", vlist());
  Value validated = Struct::validate(merged, optspec, vopts);
  opts = validated;

  // Restore the suppression the optspec default would otherwise erase.
  if (authSuppressed) {
    map_put(opts, "auth", Value(nullptr));
  }

  if (!is_nullish(sysFetch)) {
    Value sys = Helpers::toMapAny(getp(opts, "system"));
    if (sys.is_map()) {
      map_put(sys, "fetch", sysFetch);
    } else {
      Value sm = vmap();
      map_put(sm, "fetch", sysFetch);
      map_put(opts, "system", sm);
    }
  }

  // Derived clean config.
  std::string cleanKeys = "key,token,id";
  Value ck = Struct::getpath(opts, {"clean", "keys"});
  if (ck.is_string()) cleanKeys = ck.as_string();

  std::vector<std::string> parts;
  {
    size_t start = 0;
    while (start <= cleanKeys.size()) {
      size_t comma = cleanKeys.find(',', start);
      std::string tok = comma == std::string::npos ? cleanKeys.substr(start)
                                                    : cleanKeys.substr(start, comma - start);
      // trim
      size_t a = tok.find_first_not_of(" \t");
      size_t b = tok.find_last_not_of(" \t");
      if (a != std::string::npos) tok = tok.substr(a, b - a + 1);
      else tok = "";
      if (!tok.empty()) parts.push_back(vs::escre(Value(tok)));
      if (comma == std::string::npos) break;
      start = comma + 1;
    }
  }
  std::string keyre;
  for (size_t i = 0; i < parts.size(); i++) {
    if (i > 0) keyre += "|";
    keyre += parts[i];
  }

  // Resolve the feature add-order: an explicit list order (above) wins;
  // otherwise order the map test-first, then the remaining names sorted, so
  // the outcome is deterministic and `test` is always the base transport.
  if (featureOrder.empty()) {
    Value featureMap = Helpers::toMapAny(getp(opts, "feature"));
    if (featureMap.is_map()) {
      std::vector<std::string> names;
      for (const auto& item : Struct::items(featureMap)) {
        names.push_back(as_str(pair_key(item)));
      }
      std::sort(names.begin(), names.end());
      bool hasTest = std::find(names.begin(), names.end(), "test") != names.end();
      if (hasTest) featureOrder.push_back("test");
      // Station special case, mirroring test's: its transport wrap must
      // sit immediately outside the base transport (inside retry/cache/
      // netsim), so map-form activation hoists it to just after test -
      // or first, when no test entry exists. Without this the sorted
      // default would init station last and wrap OUTSIDE the recording
      // features, turning its wire-truth events into fiction.
      bool hasStation = std::find(names.begin(), names.end(), "station") != names.end();
      if (hasStation) featureOrder.push_back("station");
      for (const auto& n : names) {
        if (n != "test" && n != "station") featureOrder.push_back(n);
      }
    }
  }
  Value orderList = vlist();
  for (const auto& n : featureOrder) orderList.as_list()->push_back(Value(n));

  Value derived = vmap();
  Value derivedClean = vmap();
  if (!keyre.empty()) map_put(derivedClean, "keyre", Value(keyre));
  map_put(derived, "clean", derivedClean);
  map_put(derived, "featureorder", orderList);
  map_put(opts, "__derived__", derived);

  return opts;
}

// =======================================================================
// register_all — wire the Utility function fields (mirrors java Register).
// =======================================================================

} // namespace util

inline void register_all(Utility& u) {
  u.clean = util::clean;
  u.done = util::done;
  u.makeError = util::makeError;
  u.featureAdd = util::featureAdd;
  u.featureHook = util::featureHook;
  u.featureInit = util::featureInit;
  u.fetcher = util::fetcher;
  u.makeFetchDef = util::makeFetchDef;
  u.makeContext = util::makeContext;
  u.makeOptions = util::makeOptions;
  u.makeRequest = util::makeRequest;
  u.makeResponse = util::makeResponse;
  u.makeResult = util::makeResult;
  u.makePoint = util::makePoint;
  u.makeSpec = util::makeSpec;
  u.makeUrl = util::makeUrl;
  u.param = util::param;
  u.prepareAuth = util::prepareAuth;
  u.prepareBody = util::prepareBody;
  u.prepareHeaders = util::prepareHeaders;
  u.prepareMethod = util::prepareMethod;
  u.prepareParams = util::prepareParams;
  u.preparePath = util::preparePath;
  u.prepareQuery = util::prepareQuery;
  u.resultBasic = util::resultBasic;
  u.resultBody = util::resultBody;
  u.resultHeaders = util::resultHeaders;
  u.transformRequest = util::transformRequest;
  u.transformResponse = util::transformResponse;
}

} // namespace sdk

#endif // SDK_UTILITY_PIPELINE_HPP
