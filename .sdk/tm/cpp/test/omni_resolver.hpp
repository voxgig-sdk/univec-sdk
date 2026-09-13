// Univec SDK — the corpus test runner: vendored @voxgig/omni driven
// through its NATIVE API (omni::makeRunner(spec, provider)), presented to
// the corpus tests in the runner shape they already use (run.spec,
// run.runset, run.runsetflags, run.client). No compat shim is vendored:
// the adapter below IS the whole bridge, per language, per the vendor-tag
// rollout (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes
// the engine half of runner_support.hpp (runset/match_deep/canon) and the
// whole of struct_runner.hpp; the SUPPORT half of runner_support.hpp
// (read_file, load_env_local, env_override, load_test_control,
// is_control_skipped, get_spec, make_ctx_from_map, fixctx,
// entity_list_to_data, now_ms) lives on, name unchanged, because the
// generated entity suites include it.
//
// C++-specific decisions, each load-bearing:
//
// 1. TWO VALUE MODELS. omni::Json (json.hpp: an enum tag plus BY-VALUE
//    vector members) vs sdk::Value (utility/voxgigstruct/value.hpp: a
//    variant over monostate/nullptr/bool/int64/double/string/
//    shared_ptr<List>/shared_ptr<Map>/Injector/Modify/Sentinel). to_sdk /
//    to_omni convert at the subject boundary. Integral JSON numbers cross
//    as int64_t, exactly as the SDK's own parser (value_io.hpp) feeds the
//    utilities — their arithmetic and string rendering are written
//    against that. An Injector/Modify/Sentinel has no JSON form, so it
//    becomes its own rendering rather than silently collapsing to null.
//
// 2. ZERO-ARGUMENT ENTRIES, NATIVELY. The corpus carries entries with no
//    `in`, `args` or `ctx`, meaning "call the subject with NO value".
//    This port distinguishes that case itself: omni::Json has a
//    first-class Type::Absent separate from Type::Null, resolveargs
//    pushes `entry.get("in")` (absent when the key is missing), and
//    fixjson never invents a NULLMARK for a key that is not there. So
//    cpp needs no novalargs spec rewrite (go) and no compat shim
//    (lua/php): the ONE conversion is the sentinel swap at the call
//    boundary, Json::Absent <-> Value::undef() (std::monostate), which is
//    the SDK's own no-value sentinel — the same shape as java
//    (Json.ABSENT <-> Struct.UNDEF) and kotlin.
//
// 3. MUTATED ARGUMENTS CANNOT CROSS BY IDENTITY, so every set is driven
//    through omni::RunPack::runsetflags_args and the wrapped subject
//    REFILLS omni's own argument vector after the call. to_sdk builds NEW
//    containers, so an in-place rewrite by a subject would otherwise be
//    invisible to the runner — and `match: {args: ...}` asserts exactly
//    that (struct minor/setpath, merge/integrity: 13 entries in the
//    shared corpus). runset/runsetflags cannot serve: their Subject is
//    taken by const reference and cannot write back.
//
// 4. `match: {ctx: ...}` IS REWRITTEN TO `match: {args: [...]}` before
//    the spec reaches omni (ctxmatch_to_args below). This is the one
//    place cpp diverges from the eleven targets already migrated, and it
//    is forced by the port's value semantics: resolveargs stores the
//    contextified argument as `entry.set("ctx", first)` (omni.hpp), which
//    for a by-value Json is a deep COPY taken BEFORE the subject runs,
//    and checkresult then builds the match base from that stale copy
//    while building `args` from the LIVE vector the subject mutated. java
//    and kotlin are immune because their map entries are references to
//    one container. All nine `match.ctx` entries in the shared corpus
//    assert POST-call state (spec.headers after prepareAuth, result.body
//    after resultBody, spec.step after transformRequest, ...), so without
//    the rewrite every one of them would read "absent". The rewrite is
//    safe: an entry never carries both `ctx` and `args` (omni.hpp
//    checkentry forbids it under spec version 1, and the corpus never
//    does it under v0), and omni's getpath walks list indices by string,
//    so `args.0.spec.step` resolves. The only cost is that a failure
//    message names the path `args.0....` rather than `ctx....`.
//
// 5. NO subject-by-name provider hook. The SDK's Utility fields are TYPED
//    (utility->prepareQuery(ctx) takes a CtxPtr), so a generic name
//    lookup cannot produce omni's std::function<Json(vector<Json>&)>
//    without a per-name adapter; every corpus call site passes its
//    subject explicitly, so the hook would be dead weight. DEF.client
//    entries still resolve through the `client` hook below — but note
//    this port stamps `ctx.client` with Json::boolean(true) (PRESENCE,
//    not identity), so a DEF-built client can never be read back out of
//    the ctx map: a section needing a specially-optioned client
//    constructs it at the call site (makeSpec, prepareAuth), exactly as
//    the retired engine did. omni_ctx therefore IGNORES `ctx.client`.
//
// 6. A cpp SDK failure is thrown as sdk::SdkErrorPtr — a shared_ptr, NOT
//    a std::exception — so omni's `catch (const std::exception&)` would
//    never see it and an expected-error entry would escape the runner
//    entirely. The wrapped subject catches it and rethrows the message as
//    a std::runtime_error, stashing the error so the errify hook can put
//    its `code` beside the message for a `match: {err: {code: ...}}`
//    assertion (this port's errify hook REPLACES the default and receives
//    only the message, which is why the stash exists; the binaries are
//    single-threaded).
//
// 7. OMNI#54 AT THIS TAG: util.hpp's jsonstr has no cycle guard, and the
//    errify half is already solved natively by the Provider::errify hook.
//    The cycle risk is structurally impossible on omni's side — a Json is
//    a by-value tree and literally cannot be cyclic — PROVIDED typed SDK
//    state (a CtxPtr, a live UnivecSDK, an Injector closure) never
//    enters the Json world, which decisions 1 and 5 guarantee. to_omni
//    still refuses to recurse past MAXCONVERTDEPTH, so a cyclic
//    sdk::Value fails loudly with the entry named instead of blowing the
//    stack.

#ifndef SDK_TEST_OMNI_RESOLVER_HPP
#define SDK_TEST_OMNI_RESOLVER_HPP

#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "../core/sdk.hpp"
#include "runner_support.hpp"
#include "vendor/omni/omni.hpp"

namespace sdk {
namespace resolver {

// The sentinels, under the names the corpus tests already use.
inline const std::string NULLMARK = ::omni::NULLMARK;
inline const std::string UNDEFMARK = ::omni::UNDEFMARK;
inline const std::string EXISTSMARK = ::omni::EXISTSMARK;

using OmniError = ::omni::OmniError;
using Json = ::omni::Json;

// A depth no corpus value comes close to; see decision 7.
inline constexpr int MAXCONVERTDEPTH = 128;

// The function under test, in omni's native argument shape. The vector is
// MUTABLE on purpose: a subject that rewrites its argument in place (the
// struct setpath / merge-integrity groups) is what `match: {args: ...}`
// asserts on, and the wrapper refills omni's own arguments from it.
using Subject = std::function<Value(std::vector<Value>&)>;

// How many corpus entries this binary has actually driven. Counted in the
// wrapped subject, i.e. once per entry that reached the system under test.
// A suite whose count collapses has stopped running the corpus, which is
// the failure this whole migration exists to make visible.
inline long long& cases() {
  static long long n = 0;
  return n;
}

// ---- value models (decision 1) ----------------------------------------

/** omni's value model -> this port's. */
inline Value to_sdk(const Json& val) {
  switch (val.type) {
    case Json::Type::Absent:
      return Value::undef();
    case Json::Type::Null:
      return Value(nullptr);
    case Json::Type::Bool:
      return Value(val.boolval);
    case Json::Type::Num: {
      double d = val.numval;
      // Integral JSON numbers become int64_t, exactly as the SDK's own
      // zero-dep parser produces them.
      if (std::isfinite(d) && std::floor(d) == d && std::fabs(d) < 9007199254740992.0) {
        return Value(static_cast<int64_t>(d));
      }
      return Value(d);
    }
    case Json::Type::Str:
      return Value(val.strval);
    case Json::Type::List: {
      auto out = std::make_shared<List>();
      out->reserve(val.listval.size());
      for (const auto& entry : val.listval) out->push_back(to_sdk(entry));
      return Value(std::move(out));
    }
    case Json::Type::Map: {
      auto out = std::shared_ptr<Map>(new Map());
      for (const auto& entry : val.mapval) out->set(entry.first, to_sdk(entry.second));
      return Value(std::move(out));
    }
  }
  return Value::undef();
}

/** This port's value model -> omni's. */
inline Json to_omni(const Value& val, int depth = 0) {
  if (MAXCONVERTDEPTH < depth) {
    throw std::runtime_error("omni resolver: value nested deeper than " +
                             std::to_string(MAXCONVERTDEPTH) + " (cyclic?)");
  }
  if (val.is_undef()) return Json::absent();
  if (val.is_null()) return Json::null();
  if (val.is_bool()) return Json::boolean(val.as_bool());
  if (val.is_int()) return Json::num(static_cast<double>(val.as_int()));
  if (val.is_double()) return Json::num(val.as_double());
  if (val.is_string()) return Json::str(val.as_string());
  if (val.is_list()) {
    Json out = Json::list();
    for (const auto& entry : *val.as_list()) out.push(to_omni(entry, depth + 1));
    return out;
  }
  if (val.is_map()) {
    Json out = Json::map();
    for (const auto& entry : *val.as_map()) out.set(entry.first, to_omni(entry.second, depth + 1));
    return out;
  }
  // Injector / Modify / SKIP / DELETE: no JSON form, and omni only ever
  // stringifies one.
  return Json::str(vs::stringify(val));
}

// ---- match.ctx -> match.args[0] (decision 4) --------------------------

// Rewrite a group's `match: {ctx: X}` assertions into `match: {args: [X]}`,
// which is the only match base this port builds from the LIVE (post-call)
// arguments. Everything else in the group is left untouched, and a group
// with no ctx assertion comes back unchanged.
inline Json ctxmatch_to_args(const Json& testspec) {
  if (!testspec.ismap()) return testspec;

  Json testset = testspec.get("set");
  if (!testset.islist()) return testspec;

  Json out = testspec;
  Json newset = Json::list();

  for (const auto& original : testset.listval) {
    Json entry = original;
    Json check = entry.ismap() ? entry.get("match") : Json::absent();

    if (check.ismap() && check.has("ctx") && !check.has("args")) {
      Json rebuilt = Json::map();
      for (const auto& field : check.mapval) {
        if ("ctx" == field.first) {
          Json wrap = Json::list();
          wrap.push(field.second);
          rebuilt.set("args", wrap);
        } else {
          rebuilt.set(field.first, field.second);
        }
      }
      entry.set("match", rebuilt);
    }

    newset.push(entry);
  }

  out.set("set", newset);
  return out;
}

// ---- errors (decision 6) ---------------------------------------------

// The last SdkError a subject raised, so the errify hook can recover its
// code from the message omni hands back. Single-threaded by construction:
// each cpp test is its own binary and runs its sets in sequence.
inline SdkErrorPtr& lasterror() {
  static SdkErrorPtr err;
  return err;
}

// ---- runner ----------------------------------------------------------

class NamedRunner;

inline std::shared_ptr<::omni::Provider> sdk_provider(std::shared_ptr<UnivecSDK> client);

/**
 * What the runner returns for one named spec section — the shape the
 * corpus call sites consume. A failing entry throws omni::OmniError,
 * which testlib's T_RUN records with the entry named.
 */
class Run {
public:
  // The resolved spec section, in this port's value model.
  Value spec;
  std::shared_ptr<UnivecSDK> client;

  Run(const ::omni::RunPack& pack, std::shared_ptr<UnivecSDK> client_)
      : spec(to_sdk(pack.spec)), client(std::move(client_)), pack_(pack) {}

  /** A named group of the resolved spec. */
  Value set(const std::string& name) const { return getp(spec, Value(name)); }

  /** Run one set of test entries with omni's default flags. */
  void runset(const std::string& label, const Value& testspec, const Subject& subject) const {
    runsetflags(label, testspec, true, subject);
  }

  /**
   * Run one set of test entries. `nullflag` is omni's `null` flag: true
   * rewrites every JSON null (and absent) to NULLMARK on both sides, false
   * keeps them apart.
   */
  void runsetflags(const std::string& label, const Value& testspec, bool nullflag,
                   const Subject& subject) const {
    ::omni::Flags flags;
    flags.null = nullflag;
    flags.name = label;

    ::omni::SubjectArgs wrapped = [&subject](std::vector<Json>& args) -> Json {
      std::vector<Value> pargs;
      pargs.reserve(args.size());
      for (const auto& arg : args) pargs.push_back(to_sdk(arg));

      cases()++;
      lasterror() = nullptr;

      Value got;
      try {
        got = subject(pargs);
      } catch (const SdkErrorPtr& err) {
        // decision 6: a shared_ptr throw is invisible to omni's catch.
        lasterror() = err;
        throw std::runtime_error(err->getMessage());
      }

      // decision 3: refill omni's own arguments so `match.args` (and the
      // rewritten `match.ctx`) see the in-place rewrite.
      for (size_t index = 0; index < args.size(); index++) {
        args[index] = to_omni(pargs[index]);
      }

      return to_omni(got);
    };

    pack_.runsetflags_args(ctxmatch_to_args(to_omni(testspec)), flags, wrapped);
  }

private:
  ::omni::RunPack pack_;
};

/** A loaded spec: resolves one named section at a time. */
class NamedRunner {
public:
  NamedRunner(const ::omni::Runner& runner, std::shared_ptr<UnivecSDK> client)
      : runner_(runner), client_(std::move(client)) {}

  Run runner(const std::string& name, const Value& store = Value::undef()) const {
    return Run(runner_.runner(name, to_omni(store)), client_);
  }

private:
  ::omni::Runner runner_;
  std::shared_ptr<UnivecSDK> client_;
};

/** Wrap a live client as an omni provider (decisions 5 and 6). */
inline std::shared_ptr<::omni::Provider> sdk_provider(std::shared_ptr<UnivecSDK> client) {
  auto provider = std::make_shared<::omni::Provider>();

  // A DEF.client entry becomes another live test SDK, wrapped the same
  // way. (This port cannot hand the provider back through the ctx map —
  // see decision 5 — so a section needing that client also constructs it
  // at the call site.)
  provider->client = [](const Json& options) -> std::shared_ptr<::omni::Provider> {
    Value opts = to_sdk(options);
    if (!opts.is_map()) opts = vmap();
    return sdk_provider(UnivecSDK::testSDK(Value::undef(), opts));
  };

  // Client options may reference the runner store.
  provider->inject = [](const Json& options, const Json& store) -> Json {
    return to_omni(vs::inject(to_sdk(options), to_sdk(store)));
  };

  // Keep the SDK error's code beside its message, so a corpus
  // `match: {err: {code: ...}}` can assert on it — this port's errify hook
  // REPLACES the default and is handed the message alone, hence the stash
  // (decision 6).
  provider->errify = [](const std::string& message) -> Json {
    Json out = Json::map();
    SdkErrorPtr err = lasterror();
    if (err && err->getMessage() == message) {
      out.set("name", Json::str("SdkError"));
      out.set("message", Json::str(message));
      if (!err->code.empty()) {
        out.set("code", Json::str(err->code));
      }
      return out;
    }
    out.set("name", Json::str("Error"));
    out.set("message", Json::str(message));
    return out;
  };

  (void)client;
  return provider;
}

/**
 * Make a runner for a spec FILE. The path is resolved by omni against the
 * process working directory; cpp test binaries run from the SDK root as
 * `./test/x.out`, so the "../.sdk/test/test.json" constant the suites
 * already use carries over unchanged.
 */
inline NamedRunner makeRunner(const std::string& path, std::shared_ptr<UnivecSDK> client) {
  return NamedRunner(::omni::makeRunner(path, sdk_provider(client)), client);
}

/**
 * Make a runner for an IN-MEMORY spec — omni's own capability, which keeps
 * the smoke test free of a fixture file. Named apart from makeRunner
 * because `const char*` converts to both std::string and Value.
 */
inline NamedRunner makeRunnerSpec(const Value& spec, std::shared_ptr<UnivecSDK> client) {
  return NamedRunner(::omni::makeRunner(to_omni(spec), sdk_provider(client)), client);
}

// ---- ctx bridge -------------------------------------------------------

/**
 * Build the typed Context a generated utility takes from the ctx MAP omni
 * handed the subject (args[0]). The map's `client` entry is omni's
 * presence marker (Json::boolean(true)) and is deliberately ignored — see
 * decision 5. (The engine half of the retired runset call sites did this
 * as make_ctx_from_map + fixctx, per section, by hand.)
 */
inline CtxPtr omni_ctx(const Value& arg, std::shared_ptr<UnivecSDK> client,
                       UtilityPtr utility) {
  Value ctxmap = Helpers::toMapAny(arg);
  if (!ctxmap.is_map()) ctxmap = vmap();
  CtxPtr ctx = rs::make_ctx_from_map(ctxmap, client, utility);
  rs::fixctx(ctx, client);
  return ctx;
}

/**
 * Write the OBSERVABLE state of a typed context back into the ctx map the
 * entry holds, which is where a `match: {ctx: ...}` assertion reads
 * (through the wrapped subject's refill — decision 3 — and the rewrite of
 * decision 4). The subject mutated the typed context; the map is what the
 * runner can walk. (The retired engine call sites did this per section, by
 * hand, as "update entry ctx for match".)
 */
inline void omni_sync_ctx(const Value& arg, CtxPtr ctx) {
  Value ctxmap = Helpers::toMapAny(arg);
  if (!ctxmap.is_map() || !ctx) return;

  if (ctx->spec) {
    Value spec = vmap();
    map_put(spec, "base", Value(ctx->spec->base));
    map_put(spec, "prefix", Value(ctx->spec->prefix));
    map_put(spec, "suffix", Value(ctx->spec->suffix));
    map_put(spec, "path", Value(ctx->spec->path));
    map_put(spec, "method", Value(ctx->spec->method));
    map_put(spec, "params", ctx->spec->params);
    map_put(spec, "query", ctx->spec->query);
    map_put(spec, "headers", ctx->spec->headers);
    map_put(spec, "step", Value(ctx->spec->step));
    map_put(spec, "alias", ctx->spec->alias);
    if (!ctx->spec->body.is_undef()) map_put(spec, "body", ctx->spec->body);
    if (!ctx->spec->url.empty()) map_put(spec, "url", Value(ctx->spec->url));
    map_put(ctxmap, "spec", spec);
  }

  if (ctx->result) {
    Value result = vmap();
    map_put(result, "ok", Value(ctx->result->ok));
    map_put(result, "status", Value(ctx->result->status));
    map_put(result, "statusText", Value(ctx->result->statusText));
    map_put(result, "headers", ctx->result->headers);
    if (!ctx->result->body.is_undef()) map_put(result, "body", ctx->result->body);
    if (ctx->result->err) {
      map_put(result, "err", vmap({{"message", Value(ctx->result->err->getMessage())}}));
    }
    if (!ctx->result->resdata.is_undef()) map_put(result, "resdata", ctx->result->resdata);
    if (!ctx->result->resmatch.is_undef()) map_put(result, "resmatch", ctx->result->resmatch);
    map_put(ctxmap, "result", result);
  }

  if (ctx->response) map_put(ctxmap, "response", Value("exists"));
}

} // namespace resolver
} // namespace sdk

#endif // SDK_TEST_OMNI_RESOLVER_HPP
