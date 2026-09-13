// Univec SDK — smoke tests for the VENDORED omni runner itself
// (test/vendor/omni), driven through test/omni_resolver.hpp.
//
// A runner that cannot FAIL a bad entry would turn every corpus suite
// vacuously green, so this pins the FAILURE paths, not just the happy one.
// It also pins the three places the cpp bridge could silently stop
// asserting: the zero-argument convention, the argument refill that
// `match: {args: ...}` depends on, and the `match: {ctx: ...}` rewrite.
// (The cpp peer of tm/ts/test/omni.test.ts, tm/go/test/omnismoke_test.go
// and tm/java/test/OmniSmokeTest.java.)

#include <string>
#include <vector>

#include "omni_resolver.hpp"
#include "testlib.hpp"

using namespace sdk;
namespace res = sdk::resolver;

// A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
// like the shared corpus).
static Value smokeSpec() {
  Value smoke = vmap();

  map_put(smoke, "basic",
          vmap({{"set", vlist({vmap({{"in", Value(1)}, {"out", Value(2)}}),
                               vmap({{"in", Value(41)}, {"out", Value(42)}})})}}));

  map_put(smoke, "bad",
          vmap({{"set", vlist({vmap({{"in", Value(1)}, {"out", Value(999)}})})}}));

  map_put(smoke, "err",
          vmap({{"set", vlist({vmap({{"in", Value(0)}, {"err", Value("zero refused")}})})}}));

  // No in / args / ctx at all: "call the subject with NO value".
  map_put(smoke, "noarg", vmap({{"set", vlist({vmap({{"out", Value("noargs")}})})}}));

  // The subject rewrites its argument in place; `match.args` asserts it.
  map_put(smoke, "mutate",
          vmap({{"set", vlist({vmap({
                    {"in", vmap({{"store", vmap()}})},
                    {"match", vmap({{"args", vmap({{"0", vmap({{"store", vmap({{"x", Value(1)}})}})}})}})},
                    {"out", Value("ok")}})})}}));

  // A ctx entry whose assertion reads state written back AFTER the call —
  // the rewrite in omni_resolver.hpp (decision 4) is what makes it visible.
  map_put(smoke, "ctx",
          vmap({{"set", vlist({vmap({
                    {"ctx", vmap({{"opname", Value("load")}})},
                    {"match", vmap({{"ctx", vmap({{"spec", vmap({{"step", Value("smoked")}})}})}})}})})}}));

  Value primary = vmap({{"smoke", smoke}});
  return vmap({{"primary", primary}});
}

// The system under test: increment, refusing zero.
static Value smokeInc(std::vector<Value>& args) {
  Value in = args.empty() ? Value::undef() : args[0];
  long long n = in.is_number() ? in.as_int() : 0;
  if (0 == n) {
    throw std::runtime_error("smoke: zero refused");
  }
  return Value(n + 1);
}

static res::Run smokeRun() {
  res::NamedRunner runner = res::makeRunnerSpec(smokeSpec(), UnivecSDK::testSDK());
  res::Run run = runner.runner("smoke", Value::undef());
  ASSERT_TRUE(run.spec.is_map(), "smoke spec section did not resolve");
  return run;
}

// --- the happy path ---------------------------------------------------

static void runsetPassesACorrectSubject() {
  res::Run run = smokeRun();
  long long before = res::cases();
  run.runset("smoke-basic", run.set("basic"), smokeInc);
  ASSERT_EQ(res::cases() - before, 2LL, "expected 2 corpus entries to be driven");
}

// --- the failure paths (the point of this file) -----------------------

static void runsetFailsAWrongResult() {
  res::Run run = smokeRun();

  bool threw = false;
  std::string msg;
  try {
    run.runset("smoke-bad", run.set("bad"), smokeInc);
  } catch (const res::OmniError& e) {
    threw = true;
    msg = e.what();
  }

  ASSERT_TRUE(threw, "a wrong result went unreported - the corpus suites would be vacuously green");
  ASSERT_TRUE(msg.find("result mismatch") != std::string::npos,
              "expected a result mismatch failure, got: " + msg);
}

static void expectedErrorIsMatchedAndAMissingOneFails() {
  res::Run run = smokeRun();

  // The erroring subject satisfies the expected-error entry.
  run.runset("smoke-err", run.set("err"), smokeInc);

  // A subject that does NOT raise must fail that same entry.
  bool threw = false;
  std::string msg;
  try {
    run.runset("smoke-err", run.set("err"),
               [](std::vector<Value>& args) -> Value { return args.empty() ? Value::undef() : args[0]; });
  } catch (const res::OmniError& e) {
    threw = true;
    msg = e.what();
  }

  ASSERT_TRUE(threw, "a missing expected error went unreported");
  ASSERT_TRUE(msg.find("expected error did not occur") != std::string::npos,
              "expected an expected-error failure, got: " + msg);
}

// --- the three bridge invariants --------------------------------------

// An entry with no in/args/ctx must reach the subject as NO value, not as
// one null: Json::Absent <-> Value::undef() (resolver decision 2).
static void zeroArgumentEntryArrivesAsUndef() {
  res::Run run = smokeRun();

  bool sawundef = false;
  run.runset("smoke-noarg", run.set("noarg"), [&](std::vector<Value>& args) -> Value {
    ASSERT_EQ((int)args.size(), 1, "expected exactly one (absent) argument");
    sawundef = !args.empty() && args[0].is_undef();
    return Value("noargs");
  });
  ASSERT_TRUE(sawundef, "a zero-argument entry did not arrive as undef");

  // ...and a subject that mistakes it for null must FAIL the entry.
  bool threw = false;
  try {
    run.runset("smoke-noarg", run.set("noarg"),
               [](std::vector<Value>& args) -> Value { return Value("wrong"); });
  } catch (const res::OmniError&) {
    threw = true;
  }
  ASSERT_TRUE(threw, "a wrong zero-argument result went unreported");
}

// `match: {args: ...}` must see an in-place rewrite of the argument
// (resolver decision 3: runsetflags_args plus the refill).
static void mutatedArgumentIsVisibleToMatchArgs() {
  res::Run run = smokeRun();

  run.runset("smoke-mutate", run.set("mutate"), [](std::vector<Value>& args) -> Value {
    Value store = getp(args[0], Value("store"));
    map_put(store, "x", Value(1));
    return Value("ok");
  });

  // A subject that does NOT mutate must fail that same entry.
  bool threw = false;
  std::string msg;
  try {
    run.runset("smoke-mutate", run.set("mutate"),
               [](std::vector<Value>& args) -> Value { return Value("ok"); });
  } catch (const res::OmniError& e) {
    threw = true;
    msg = e.what();
  }
  ASSERT_TRUE(threw, "an unmutated argument satisfied match.args - the refill is dead");
  ASSERT_TRUE(msg.find("match failed at args") != std::string::npos,
              "expected a match.args failure, got: " + msg);
}

// `match: {ctx: ...}` must see state the subject wrote back AFTER the
// call (resolver decision 4: the ctx -> args[0] rewrite). Without it every
// ctx assertion in the primary corpus reads "absent".
static void ctxMatchSeesPostCallState() {
  res::Run run = smokeRun();

  run.runset("smoke-ctx", run.set("ctx"), [&](std::vector<Value>& args) -> Value {
    CtxPtr ctx = res::omni_ctx(args[0], run.client, run.client->getUtility());
    ctx->spec = std::make_shared<Spec>(vmap({{"step", Value("smoked")}}));
    res::omni_sync_ctx(args[0], ctx);
    return Value::undef();
  });

  // A subject that never writes back must fail that same entry.
  bool threw = false;
  try {
    run.runset("smoke-ctx", run.set("ctx"),
               [](std::vector<Value>& args) -> Value { return Value::undef(); });
  } catch (const res::OmniError&) {
    threw = true;
  }
  ASSERT_TRUE(threw, "an unwritten ctx satisfied match.ctx - the rewrite is dead");
}

int main() {
  T_RUN(runsetPassesACorrectSubject);
  T_RUN(runsetFailsAWrongResult);
  T_RUN(expectedErrorIsMatchedAndAMissingOneFails);
  T_RUN(zeroArgumentEntryArrivesAsUndef);
  T_RUN(mutatedArgumentIsVisibleToMatchArgs);
  T_RUN(ctxMatchSeesPostCallState);
  std::cout << "omni_smoke_test: " << res::cases() << " runner cases driven\n";
  return sdktest::summary("omni_smoke_test");
}
