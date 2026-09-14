// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (cpp/src/Provider.cpp)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
#include "Provider.hpp"

#include <map>

#include "../plugin/ref.hpp"
#include "../plugin/types.hpp"

namespace sekreto {

// ---------------------------------------------------------- the ordered map

bool Ordered::has(const std::string& key) const {
  for (const auto& entry : pairs) {
    if (key == entry.first) return true;
  }
  return false;
}

std::optional<std::string> Ordered::get(const std::string& key) const {
  for (const auto& entry : pairs) {
    if (key == entry.first) return entry.second;
  }
  return std::nullopt;
}

void Ordered::set(const std::string& key, const std::string& value) {
  for (auto& entry : pairs) {
    if (key == entry.first) {
      entry.second = value;
      return;
    }
  }
  pairs.emplace_back(key, value);
}

// ------------------------------------------------------------- the specs

namespace {

/// What a credential field reports about itself.
std::string setornot(const std::string& value) {
  return value.empty() ? "[unset]" : "[set]";
}

}  // namespace

std::string AuthSpec::str() const {
  return "AuthSpec(method=" + method + ", mount=" + mount + ", role=" + role +
         ", jwtfile=" + jwtfile + ", roleid=" + roleid + ", jwt=" + setornot(jwt) +
         ", secretid=" + setornot(secretid) + ")";
}

std::string ProviderSpec::str() const {
  return "ProviderSpec(kind=" + kind + ", name=" + name + ", addr=" + addr +
         ", token=" + setornot(token) + ", secret=" + setornot(secret) +
         ", clientsecret=" + setornot(clientsecret) +
         ", auth=" + (auth.has_value() ? auth.value().str() : "none") + ")";
}

// ------------------------------------------------ the spec as plugin options

namespace {

/// A string field, written only when it is set. "Not configured" and
/// "configured empty" are the same thing here, so an empty string is an
/// absent key and the options map reads like the configuration.
void setstr(const plugin::V& out, const std::string& key, const std::string& text) {
  if (!text.empty()) plugin::set(out, key, plugin::vstr(text));
}

std::string strof(const plugin::V& options, const std::string& key) {
  plugin::V given = plugin::get(options, key);
  return plugin::isstr(given) ? plugin::asstr(given) : "";
}

}  // namespace

plugin::V optionsof(const ProviderSpec& spec) {
  plugin::V out = plugin::vmap();

  setstr(out, "kind", spec.kind);
  setstr(out, "name", spec.name);
  setstr(out, "prefix", spec.prefix);
  setstr(out, "file", spec.file);
  setstr(out, "dir", spec.dir);
  setstr(out, "addr", spec.addr);
  setstr(out, "token", spec.token);
  setstr(out, "mount", spec.mount);
  setstr(out, "vaultnamespace", spec.vaultnamespace);
  setstr(out, "command", spec.command);
  setstr(out, "profile", spec.profile);
  setstr(out, "backend", spec.backend);
  setstr(out, "reason", spec.reason);
  setstr(out, "namespace", spec.namespace_);
  setstr(out, "home", spec.home);
  setstr(out, "region", spec.region);
  setstr(out, "keyid", spec.keyid);
  setstr(out, "secret", spec.secret);
  setstr(out, "session", spec.session);
  setstr(out, "project", spec.project);
  setstr(out, "vault", spec.vault);
  setstr(out, "tenant", spec.tenant);
  setstr(out, "clientid", spec.clientid);
  setstr(out, "clientsecret", spec.clientsecret);
  setstr(out, "loginaddr", spec.loginaddr);
  setstr(out, "imdsaddr", spec.imdsaddr);
  setstr(out, "metadataaddr", spec.metadataaddr);
  setstr(out, "apiversion", spec.apiversion);
  setstr(out, "config", spec.config);
  setstr(out, "environment", spec.environment);
  setstr(out, "path", spec.path);

  if (spec.kv.has_value()) {
    plugin::set(out, "kv", plugin::vnum(spec.kv.value()));
  }

  if (!spec.values.empty()) {
    plugin::V values = plugin::vmap();
    // A plugin map keeps insertion order, so the literal values arrive in
    // the order they were written - which the spec compares.
    for (const auto& entry : spec.values.pairs) {
      plugin::set(values, entry.first, plugin::vstr(entry.second));
    }
    plugin::set(out, "values", values);
  }

  if (spec.auth.has_value()) {
    const AuthSpec& auth = spec.auth.value();
    plugin::V m = plugin::vmap();
    setstr(m, "method", auth.method);
    setstr(m, "mount", auth.mount);
    setstr(m, "role", auth.role);
    setstr(m, "jwt", auth.jwt);
    setstr(m, "jwtfile", auth.jwtfile);
    setstr(m, "roleid", auth.roleid);
    setstr(m, "secretid", auth.secretid);
    plugin::set(out, "auth", m);
  }

  return out;
}

ProviderSpec specof(const plugin::V& options) {
  ProviderSpec spec;

  spec.kind = strof(options, "kind");
  spec.name = strof(options, "name");
  spec.prefix = strof(options, "prefix");
  spec.file = strof(options, "file");
  spec.dir = strof(options, "dir");
  spec.addr = strof(options, "addr");
  spec.token = strof(options, "token");
  spec.mount = strof(options, "mount");
  spec.vaultnamespace = strof(options, "vaultnamespace");
  spec.command = strof(options, "command");
  spec.profile = strof(options, "profile");
  spec.backend = strof(options, "backend");
  spec.reason = strof(options, "reason");
  spec.namespace_ = strof(options, "namespace");
  spec.home = strof(options, "home");
  spec.region = strof(options, "region");
  spec.keyid = strof(options, "keyid");
  spec.secret = strof(options, "secret");
  spec.session = strof(options, "session");
  spec.project = strof(options, "project");
  spec.vault = strof(options, "vault");
  spec.tenant = strof(options, "tenant");
  spec.clientid = strof(options, "clientid");
  spec.clientsecret = strof(options, "clientsecret");
  spec.loginaddr = strof(options, "loginaddr");
  spec.imdsaddr = strof(options, "imdsaddr");
  spec.metadataaddr = strof(options, "metadataaddr");
  spec.apiversion = strof(options, "apiversion");
  spec.config = strof(options, "config");
  spec.environment = strof(options, "environment");
  spec.path = strof(options, "path");

  plugin::V kv = plugin::get(options, "kv");
  if (plugin::isnum(kv)) spec.kv = static_cast<int>(plugin::asnum(kv));

  plugin::V values = plugin::get(options, "values");
  if (plugin::ismap(values)) {
    for (const std::string& key : plugin::keys(values)) {
      spec.values.set(key, plugin::asstr(plugin::get(values, key)));
    }
  }

  plugin::V auth = plugin::get(options, "auth");
  if (plugin::ismap(auth)) {
    AuthSpec use;
    use.method = strof(auth, "method");
    use.mount = strof(auth, "mount");
    use.role = strof(auth, "role");
    use.jwt = strof(auth, "jwt");
    use.jwtfile = strof(auth, "jwtfile");
    use.roleid = strof(auth, "roleid");
    use.secretid = strof(auth, "secretid");
    spec.auth = use;
  }

  return spec;
}

// ------------------------------------------------------- the provider slots

namespace {

struct Slots {
  std::map<double, std::shared_ptr<Provider>> held;
  double next = 1;
};

Slots& slots() {
  // thread_local, NOT a process-global. A provider is parked by `define`
  // and claimed by `Sekreto::declare` in the same synchronous call on the
  // same thread, so per-thread is the same table for every purpose this
  // has - and it removes the sharing entirely. As a process-global it was
  // shared mutable state on the construction path: four threads building
  // 500 chains each aborted every run with
  //
  //   malloc(): unaligned tcache chunk detected
  //
  // three of them inside providerslot -> _Rb_tree_insert_and_rebalance.
  // The port documents that it claims no thread safety across concurrent
  // constructions, but heap corruption is not what a disclaimer buys you,
  // and the pre-refactor port had no shared construction state at all.
  static thread_local Slots one;
  return one;
}

}  // namespace

double providerslot(const std::shared_ptr<Provider>& provider) {
  Slots& one = slots();
  double ticket = one.next;
  one.next = ticket + 1;
  one.held[ticket] = provider;
  return ticket;
}

std::shared_ptr<Provider> takeprovider(double ticket) {
  Slots& one = slots();
  auto at = one.held.find(ticket);
  if (one.held.end() == at) return nullptr;

  std::shared_ptr<Provider> provider = at->second;
  one.held.erase(at);
  return provider;
}

double providermark() { return slots().next; }

void providerdiscard(double mark) {
  Slots& one = slots();
  for (auto at = one.held.begin(); one.held.end() != at;) {
    at = (mark <= at->first) ? one.held.erase(at) : std::next(at);
  }
}

size_t providerslots() { return slots().held.size(); }

// --------------------------------------------------------------- the bridge

const char* const PROVIDER_EXPORT = "provider";
const char* const ERROR_CODE = "sekreto_error";

Definition providerplugin(const std::string& kind, Make make) {
  auto def = std::make_shared<plugin::Definition>();

  def->name = kind;
  def->define = [make](plugin::Inst& inst) {
    std::shared_ptr<Provider> provider;

    try {
      provider = make(specof(inst.options()));
    } catch (const SekretoError& err) {
      // The spec pins this message byte for byte, so it travels under a
      // code the host will not rewrite and `Sekreto` takes the code back
      // off on the far side.
      plugin::fail(ERROR_CODE, err.what(),
                   plugin::details2("ref", plugin::vstr(inst.ref()), "cause",
                                    plugin::vstr(err.what())));
    } catch (const plugin::PluginError&) {
      // Already the host's own currency: it names the instance itself.
      throw;
    } catch (const std::exception& err) {
      // ANYTHING ELSE IS THE HOST'S TO REPORT, and it can only report what
      // reaches it as a PluginError: `Host::run` catches nothing else, so
      // an escaping std::exception would leave the instance neither
      // `loaded` nor `failed`. `plugin_bare` is this port's spelling of
      // "an error with no code", which the host wraps as
      // `plugin_define_failed` naming the instance and the cause.
      plugin::fail("plugin_bare", err.what());
    }

    if (nullptr == provider) {
      const std::string why = "sekreto: " + inst.name() + " built no provider";
      plugin::fail(ERROR_CODE, why,
                   plugin::details2("ref", plugin::vstr(inst.ref()), "cause",
                                    plugin::vstr(why)));
    }

    inst.exportvalue(PROVIDER_EXPORT, plugin::vnum(providerslot(provider)));
  };

  return def;
}

}  // namespace sekreto
