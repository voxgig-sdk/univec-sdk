// Univec SDK: generated schemas. Do not edit.
//
// Built from the model: `main.kit.optspec` and each feature's
// `config.options` for the option spec; entity `fields{}.type` for the
// entity specs.

const h = @import("helpers.zig");
const jsonparse = @import("../utility/jsonparse.zig");
const Value = h.Value;

const OPTSPEC_DATA: []const u8 = "{\"allow\":{\"method\":\"GET,PUT,POST,PATCH,DELETE,OPTIONS\",\"op\":\"create,update,patch,load,list,remove,command,direct,graphql\"},\"apikey\":\"\",\"auth\":{\"basic\":false,\"in\":\"\",\"name\":\"\",\"prefix\":\"\"},\"base\":\"http://localhost:8000\",\"clean\":{\"active\":true,\"hint\":\"0\",\"keys\":\"key,secret,token,password,passwd,authorization,cookie,credential,signature\",\"mask\":\"[redacted]\",\"min\":\"4\",\"values\":\"\"},\"entity\":{\"`$CHILD`\":{\"`$OPEN`\":true,\"active\":false,\"alias\":{}}},\"extend\":\"`$ANY`\",\"headers\":{\"`$CHILD`\":\"`$STRING`\"},\"prefix\":\"\",\"secret\":\"\",\"server\":{\"`$CHILD`\":\"\"},\"suffix\":\"\",\"system\":{\"fetch\":\"`$ANY`\"},\"test\":{\"active\":false,\"entity\":{\"`$OPEN`\":true}},\"utility\":{},\"feature\":{\"`$CHILD`\":{\"`$OPEN`\":true,\"active\":false},\"audit\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"actor\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"max\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"sink\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"cache\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"max\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"methods\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"ttl\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"clienttrack\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"clientVersion\":[\"`$ONE`\",\"`$STRING`\",\"`$NIL`\"],\"clientName\":[\"`$ONE`\",\"`$STRING`\",\"`$NIL`\"],\"headers\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"],\"idgen\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"sessionId\":[\"`$ONE`\",\"`$STRING`\",\"`$NIL`\"]},\"`$NIL`\"],\"cost\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"budget\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"currency\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"header\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"onBudget\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"path\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"perUnit\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"rates\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"],\"unit\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"actor\":[\"`$ONE`\",\"`$STRING`\",\"`$NIL`\"],\"sink\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"debug\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"max\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"redact\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"onEntry\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"idempotency\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"header\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"methods\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"ops\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"keygen\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"log\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"level\":[\"`$ONE`\",\"`$STRING`\",\"`$NIL`\"],\"logger\":\"`$ANY`\"},\"`$NIL`\"],\"metrics\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"netsim\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"errorTimes\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"failEvery\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"failRate\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"failStatus\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"failTimes\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"latency\":[\"`$ONE`\",\"`$NUMBER`\",\"`$MAP`\",\"`$NIL`\"],\"offline\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"rateLimitTimes\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"retryAfter\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"seed\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"sleep\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"paging\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"afterVar\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"cursorParam\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"firstVar\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"limitParam\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"pageParam\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"startPage\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"limit\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"ops\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"]},\"`$NIL`\"],\"proxy\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"fromEnv\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"noProxy\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"url\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"agent\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"ratelimit\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"burst\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"rate\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"sleep\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"rbac\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"deny\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"permissions\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"rules\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"]},\"`$NIL`\"],\"retry\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"factor\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"maxDelay\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"minDelay\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"retries\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"statuses\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"jitter\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"sleep\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"secrets\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"cache\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"exchange\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"],\"name\":[\"`$ONE`\",\"`$STRING`\",[\"`$EXACT`\",\"\"],\"`$NIL`\"],\"providers\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"]},\"`$NIL`\"],\"streaming\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"chunkDelay\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"chunkSize\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"ops\":[\"`$ONE`\",\"`$LIST`\",\"`$NIL`\"],\"sleep\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"telemetry\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"exporter\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"headers\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"],\"idgen\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"],\"test\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"entity\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"],\"net\":[\"`$ONE`\",\"`$MAP`\",\"`$NIL`\"]},\"`$NIL`\"],\"timeout\":[\"`$ONE`\",{\"`$OPEN`\":true,\"active\":[\"`$ONE`\",\"`$BOOLEAN`\",\"`$NIL`\"],\"ms\":[\"`$ONE`\",\"`$NUMBER`\",\"`$NIL`\"],\"clearTimer\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"now\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"],\"setTimer\":[\"`$ONE`\",\"`$FUNCTION`\",\"`$NIL`\"]},\"`$NIL`\"]}}";

const ENTITYSPEC_DATA: []const u8 = "{}";

/// The option spec make_options validates client options against.
///
/// Unreachable on error: the constant is generated by a JSON serialiser and
/// never edited by hand. Panicking beats returning an empty spec, which would
/// validate everything and fail far from the cause.
pub fn make_optspec() Value {
    return jsonparse.json_parse(OPTSPEC_DATA) catch
        @panic("Univec: embedded option spec is not valid JSON");
}

/// Per-entity data and request specs, keyed by entity name.
pub fn make_entityspec() Value {
    return jsonparse.json_parse(ENTITYSPEC_DATA) catch
        @panic("Univec: embedded entity spec is not valid JSON");
}

// SHARED SPECS, the shape config.shared_config uses and for the same reasons:
// the spec is read on every client construction and never mutated, so a
// per-call parse would be pure waste. Value nodes are arena-allocated and
// reference-stable, so the shared value is genuinely one structure.
//
// The returned Values SHARE their nodes: treat them as read-only.
// make_options validates AGAINST the spec and writes into the options, never
// into the spec.
var shared_optspec_val: ?Value = null;
var shared_entityspec_val: ?Value = null;

/// The process-wide option spec, built once on first use.
pub fn shared_optspec() Value {
    if (shared_optspec_val) |s| return s;
    const s = make_optspec();
    shared_optspec_val = s;
    return s;
}

/// The process-wide entity specs, built once on first use.
pub fn shared_entityspec() Value {
    if (shared_entityspec_val) |s| return s;
    const s = make_entityspec();
    shared_entityspec_val = s;
    return s;
}
