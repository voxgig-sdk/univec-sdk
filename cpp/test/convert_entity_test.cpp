// Generated basic-flow test for the convert entity (model-driven,
// unit mode; mirrors the rust/go TestEntity generator).

#include "runner_support.hpp"

using namespace sdk;
using namespace sdk::rs;

struct ConvertSetup {
  std::shared_ptr<UnivecSDK> client;
  Value data;
  Value idmap;
  Value env;
  bool live = false;
  bool synthetic_only = false;
  long long now = 0;
};

static ConvertSetup convert_basic_setup(const Value& extra) {
  load_env_local();

  std::string entity_data_file = "../.sdk/test/entity/convert/ConvertTestData.json";
  Value entity_data = vs::parse_json(read_file(entity_data_file));

  Value options = vmap({{"entity", getp(entity_data, "existing")}});
  auto client = UnivecSDK::testSDK(options, extra);

  // idmap via transform (upper-cased id name synthetics), matching the donors.
  Value idmap = Struct::transform(
      vlist({Value("convert01"), Value("convert02"), Value("convert03")}),
      vmap({{"`$PACK`", vlist({
        Value(""),
        vmap({
          {"`$KEY`", Value("`$COPY`")},
          {"`$VAL`", vlist({Value("`$FORMAT`"), Value("upper"), Value("`$COPY`")})}
        })
      })}}));
  if (!idmap.is_map()) idmap = vmap();

  Value env = env_override(vmap({
    {"UNIVEC_TEST_CONVERT_ENTID", idmap},
    {"UNIVEC_TEST_LIVE", Value("FALSE")},
    {"UNIVEC_TEST_EXPLAIN", Value("FALSE")}
  }));

  Value idmap_resolved = Helpers::toMapAny(getp(env, "UNIVEC_TEST_CONVERT_ENTID"));
  if (!idmap_resolved.is_map()) idmap_resolved = idmap;

  bool live = getp(env, "UNIVEC_TEST_LIVE") == Value("TRUE");

  ConvertSetup s;
  s.client = client;
  s.data = entity_data;
  s.idmap = idmap_resolved;
  s.env = env;
  s.live = live;
  s.synthetic_only = false;
  s.now = now_ms();
  return s;
}

static void convert_entity_instance() {
  auto testsdk = UnivecSDK::testSDK();
  auto ent = testsdk->convert();
  ASSERT_EQ(ent->getName(), std::string("convert"), "entity name");
}


static void convert_entity_basic() {
  auto setup = convert_basic_setup(Value::undef());
  std::string mode = setup.live ? "live" : "unit";
  for (const std::string& op : std::vector<std::string>{"create"}) {
    auto sk = is_control_skipped("entityOp", std::string("convert.") + op, mode);
    if (sk.first) { std::cerr << "skip: " << (sk.second.empty()? "sdk-test-control.json" : sk.second) << "\n"; return; }
  }
  auto client = setup.client;
  // CREATE
  auto convert_ref01_ent = client->convert();
  Value convert_ref01_data = Helpers::toMapAny(getp(Struct::getpath(setup.data, {"new", "convert"}), "convert_ref01"));
  if (!convert_ref01_data.is_map()) convert_ref01_data = vmap();
  {
    Value convert_ref01_data_result = convert_ref01_ent->create(Struct::clone(convert_ref01_data), Value::undef())->data();
    convert_ref01_data = Helpers::toMapAny(convert_ref01_data_result);
    if (!convert_ref01_data.is_map()) convert_ref01_data = vmap();
    ASSERT_TRUE(convert_ref01_data.is_map(), "expected create result to be a map");
  }

}

int main() {
  T_RUN(convert_entity_instance);
  T_RUN(convert_entity_basic);
  return sdktest::summary("convert_entity_test");
}
