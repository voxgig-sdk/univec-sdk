// Generated basic-flow test for the ephemeral_key entity (model-driven,
// unit mode; mirrors the rust/go TestEntity generator).

#include "runner_support.hpp"

using namespace sdk;
using namespace sdk::rs;

struct EphemeralKeySetup {
  std::shared_ptr<UnivecSDK> client;
  Value data;
  Value idmap;
  Value env;
  bool live = false;
  bool synthetic_only = false;
  long long now = 0;
};

static EphemeralKeySetup ephemeral_key_basic_setup(const Value& extra) {
  load_env_local();

  std::string entity_data_file = "../.sdk/test/entity/ephemeral_key/EphemeralKeyTestData.json";
  Value entity_data = vs::parse_json(read_file(entity_data_file));

  Value options = vmap({{"entity", getp(entity_data, "existing")}});
  auto client = UnivecSDK::testSDK(options, extra);

  // idmap via transform (upper-cased id name synthetics), matching the donors.
  Value idmap = Struct::transform(
      vlist({Value("ephemeral_key01"), Value("ephemeral_key02"), Value("ephemeral_key03")}),
      vmap({{"`$PACK`", vlist({
        Value(""),
        vmap({
          {"`$KEY`", Value("`$COPY`")},
          {"`$VAL`", vlist({Value("`$FORMAT`"), Value("upper"), Value("`$COPY`")})}
        })
      })}}));
  if (!idmap.is_map()) idmap = vmap();

  Value env = env_override(vmap({
    {"UNIVEC_TEST_EPHEMERAL_KEY_ENTID", idmap},
    {"UNIVEC_TEST_LIVE", Value("FALSE")},
    {"UNIVEC_TEST_EXPLAIN", Value("FALSE")}
  }));

  Value idmap_resolved = Helpers::toMapAny(getp(env, "UNIVEC_TEST_EPHEMERAL_KEY_ENTID"));
  if (!idmap_resolved.is_map()) idmap_resolved = idmap;

  bool live = getp(env, "UNIVEC_TEST_LIVE") == Value("TRUE");

  EphemeralKeySetup s;
  s.client = client;
  s.data = entity_data;
  s.idmap = idmap_resolved;
  s.env = env;
  s.live = live;
  s.synthetic_only = false;
  s.now = now_ms();
  return s;
}

static void ephemeral_key_entity_instance() {
  auto testsdk = UnivecSDK::testSDK();
  auto ent = testsdk->ephemeral_key();
  ASSERT_EQ(ent->getName(), std::string("ephemeral_key"), "entity name");
}


static void ephemeral_key_entity_basic() {
  auto setup = ephemeral_key_basic_setup(Value::undef());
  std::string mode = setup.live ? "live" : "unit";
  for (const std::string& op : std::vector<std::string>{"create"}) {
    auto sk = is_control_skipped("entityOp", std::string("ephemeral_key.") + op, mode);
    if (sk.first) { std::cerr << "skip: " << (sk.second.empty()? "sdk-test-control.json" : sk.second) << "\n"; return; }
  }
  auto client = setup.client;
  // CREATE
  auto ephemeral_key_ref01_ent = client->ephemeral_key();
  Value ephemeral_key_ref01_data = Helpers::toMapAny(getp(Struct::getpath(setup.data, {"new", "ephemeral_key"}), "ephemeral_key_ref01"));
  if (!ephemeral_key_ref01_data.is_map()) ephemeral_key_ref01_data = vmap();
  {
    Value ephemeral_key_ref01_data_result = ephemeral_key_ref01_ent->create(Struct::clone(ephemeral_key_ref01_data), Value::undef())->data();
    ephemeral_key_ref01_data = Helpers::toMapAny(ephemeral_key_ref01_data_result);
    if (!ephemeral_key_ref01_data.is_map()) ephemeral_key_ref01_data = vmap();
    ASSERT_TRUE(ephemeral_key_ref01_data.is_map(), "expected create result to be a map");
  }

}

int main() {
  T_RUN(ephemeral_key_entity_instance);
  T_RUN(ephemeral_key_entity_basic);
  return sdktest::summary("ephemeral_key_entity_test");
}
