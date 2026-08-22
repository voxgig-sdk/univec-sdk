// Generated basic-flow test for the model entity (model-driven,
// unit mode; mirrors the rust/go TestEntity generator).

#include "runner_support.hpp"

using namespace sdk;
using namespace sdk::rs;

struct ModelSetup {
  std::shared_ptr<UnivecSDK> client;
  Value data;
  Value idmap;
  Value env;
  bool live = false;
  bool synthetic_only = false;
  long long now = 0;
};

static ModelSetup model_basic_setup(const Value& extra) {
  load_env_local();

  std::string entity_data_file = "../.sdk/test/entity/model/ModelTestData.json";
  Value entity_data = vs::parse_json(read_file(entity_data_file));

  Value options = vmap({{"entity", getp(entity_data, "existing")}});
  auto client = UnivecSDK::testSDK(options, extra);

  // idmap via transform (upper-cased id name synthetics), matching the donors.
  Value idmap = Struct::transform(
      vlist({Value("model01"), Value("model02"), Value("model03")}),
      vmap({{"`$PACK`", vlist({
        Value(""),
        vmap({
          {"`$KEY`", Value("`$COPY`")},
          {"`$VAL`", vlist({Value("`$FORMAT`"), Value("upper"), Value("`$COPY`")})}
        })
      })}}));
  if (!idmap.is_map()) idmap = vmap();

  Value env = env_override(vmap({
    {"UNIVEC_TEST_MODEL_ENTID", idmap},
    {"UNIVEC_TEST_LIVE", Value("FALSE")},
    {"UNIVEC_TEST_EXPLAIN", Value("FALSE")}
  }));

  Value idmap_resolved = Helpers::toMapAny(getp(env, "UNIVEC_TEST_MODEL_ENTID"));
  if (!idmap_resolved.is_map()) idmap_resolved = idmap;

  bool live = getp(env, "UNIVEC_TEST_LIVE") == Value("TRUE");

  ModelSetup s;
  s.client = client;
  s.data = entity_data;
  s.idmap = idmap_resolved;
  s.env = env;
  s.live = live;
  s.synthetic_only = false;
  s.now = now_ms();
  return s;
}

static void model_entity_instance() {
  auto testsdk = UnivecSDK::testSDK();
  auto ent = testsdk->model();
  ASSERT_EQ(ent->getName(), std::string("model"), "entity name");
}


static void model_entity_stream() {
  // stream() runs the list op through the full pipeline and returns the
  // result items. Seed two entities via test mode; with the streaming feature
  // active it yields the feature's incremental items, else it falls back to
  // the materialised items — either way every item is yielded.
  Value seed = vmap({{"entity", vmap({{"model", vmap({
      {"strm01", vmap({{"id", Value("strm01")}})},
      {"strm02", vmap({{"id", Value("strm02")}})}})}})}});
  Value sdkopts = vmap({{"feature",
      vmap({{"streaming", vmap({{"active", Value(true)}})}})}});

  auto strsdk = UnivecSDK::testSDK(seed, sdkopts);
  auto se = strsdk->model();
  std::vector<Value> items = se->stream("list", Value::undef(), Value::undef());
  ASSERT_EQ((int)items.size(), 2, "stream yields both seeded items");

  auto plainsdk = UnivecSDK::testSDK(seed, Value::undef());
  auto pe = plainsdk->model();
  std::vector<Value> pitems = pe->stream("list", Value::undef(), Value::undef());
  ASSERT_EQ((int)pitems.size(), 2, "fallback stream yields both items");
}

static void model_entity_basic() {
  auto setup = model_basic_setup(Value::undef());
  std::string mode = setup.live ? "live" : "unit";
  for (const std::string& op : std::vector<std::string>{"list"}) {
    auto sk = is_control_skipped("entityOp", std::string("model.") + op, mode);
    if (sk.first) { std::cerr << "skip: " << (sk.second.empty()? "sdk-test-control.json" : sk.second) << "\n"; return; }
  }
  auto client = setup.client;

  // Bootstrap entity data from existing test data (no create step in flow).
  // Declare _data at FUNCTION scope (later load/update steps reference it);
  // only _data_raw was declared, so the block-local assignment left _data
  // undeclared ("was not declared in this scope").
  Value model_ref01_data_raw = Helpers::toMapAny(Struct::getpath(setup.data, {"existing", "model"}));
  Value model_ref01_data = vmap();
  {
    std::vector<Value> its = Struct::items(model_ref01_data_raw);
    model_ref01_data = its.empty() ? vmap() : Helpers::toMapAny(pair_val(its[0]));
    if (!model_ref01_data.is_map()) model_ref01_data = vmap();
  }
  // LIST
  auto model_ref01_ent = client->model();
  Value model_ref01_match = vmap();
  auto model_ref01_list_ents = model_ref01_ent->list(Struct::clone(model_ref01_match), Value::undef());
  // list resolves to one ENTITY per record; the flow asserts on the records.
  Value model_ref01_list = vlist();
  for (const auto& e : model_ref01_list_ents) { model_ref01_list.as_list()->push_back(e->data()); }
  ASSERT_TRUE(model_ref01_list.is_list(), "expected list result to be an array");

}

int main() {
  T_RUN(model_entity_instance);
  T_RUN(model_entity_stream);
  T_RUN(model_entity_basic);
  return sdktest::summary("model_entity_test");
}
