// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Hashicorp.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// HashiCorp Vault, as a voxgig/plugin definition.
//
// A PLUGIN, NOT PART OF THE CORE: it opens a socket, and the core reads
// at most a local file. A chain that does not name this kind must not
// carry it, so the calling project imports this definition and hands it
// to Sekreto in the `plugins` option.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.Addr.checkaddr;
import static JAVAPACKAGE.feature.secrets.sekreto.Support.text;
import static JAVAPACKAGE.feature.secrets.sekreto.Support.textor;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.dig;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.fetchjson;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.first;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.renewtime;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;

import JAVAPACKAGE.feature.secrets.sekreto.Json;
import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * HashiCorp Vault.
 *
 * <p>KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
 * and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
 * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
 * here" - a miss - so a vault can sit in a chain with fallbacks.
 *
 * <p>A Vault Enterprise namespace rides the X-Vault-Namespace header, on
 * logins as well as reads.
 *
 * <p>Instead of being handed a token, the provider can log in: Kubernetes
 * auth (the pod's service-account JWT, from its conventional path) or
 * AppRole. A failed login is an error, never a miss - it means this store
 * could not answer at all.
 */
public final class Hashicorp implements Provider {

  /** The `hashicorp` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("hashicorp", spec -> {
    Object kv = spec.get("kv");
    return new Hashicorp(
        Support.textor(spec.get("addr"), ""),
        Support.textor(spec.get("token"), ""),
        Support.text(spec.get("mount")),
        kv instanceof Number ? ((Number) kv).intValue() : 0,
        Support.text(spec.get("vaultnamespace")),
        Support.map(spec.get("auth")));
  });
  private final String addr;
  private final String mount;
  private final int kv;
  private final String vaultnamespace;
  private final Map<String, Object> auth;

  // The working token: a configured token is kept forever, a logged-in
  // token is renewed shortly before its lease runs out - a long-running
  // process must not keep presenting a token the vault already expired.
  private String livetoken;
  private long renewat = Long.MAX_VALUE;

  public Hashicorp(String addr, String token, String mount) {
    this(addr, token, mount, 0, null, null);
  }

  public Hashicorp(String addr, String token, String mount, int kv,
      String vaultnamespace, Map<String, Object> auth) {
    this.addr = null == addr ? "" : addr;
    this.mount = null == mount || mount.isEmpty() ? "secret" : mount;
    this.kv = 0 == kv ? 2 : kv;

    // A version typo like kv: 3 must not quietly behave as v2 and turn
    // its 404s into misses; there is nothing safe to assume it meant.
    if (1 != this.kv && 2 != this.kv) {
      throw new SekretoError("sekreto: hashicorp: unsupported kv version: " + this.kv);
    }

    this.vaultnamespace = vaultnamespace;
    this.auth = auth;
    this.livetoken = null == token || token.isEmpty() ? null : token;
  }

  private Map<String, String> baseheaders() {
    Map<String, String> out = new LinkedHashMap<>();
    if (null != vaultnamespace && !vaultnamespace.isEmpty()) {
      out.put("X-Vault-Namespace", vaultnamespace);
    }
    return out;
  }

  private String login() {
    if (null == auth) {
      throw new SekretoError("sekreto: hashicorp: no token and no auth method");
    }

    String method = text(auth.get("method"));
    String authmount = first(text(auth.get("mount")), null == method ? "" : method);
    String url = trimslash(addr) + "/v1/auth/" + authmount + "/login";

    Map<String, Object> body = new LinkedHashMap<>();
    if ("kubernetes".equals(method)) {
      String jwt = text(auth.get("jwt"));
      if (null == jwt) {
        String file = textor(
            auth.get("jwtfile"), "/var/run/secrets/kubernetes.io/serviceaccount/token");
        try {
          jwt = new String(Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8).trim();
        } catch (IOException err) {
          throw new SekretoError("sekreto: hashicorp: cannot read jwt file " + file);
        }
      }
      body.put("role", textor(auth.get("role"), ""));
      body.put("jwt", jwt);
    } else if ("approle".equals(method)) {
      body.put("role_id", textor(auth.get("roleid"), ""));
      body.put("secret_id", textor(auth.get("secretid"), ""));
    } else {
      throw new SekretoError(
          "sekreto: hashicorp: unknown auth method: " + (null == method ? "" : method));
    }

    Answer res = fetchjson("POST", url, baseheaders(), Json.stringify(body));

    Object got = dig(res.body, "auth", "client_token");
    if (200 != res.status || null == got || String.valueOf(got).isEmpty()) {
      throw new SekretoError("sekreto: hashicorp login failed: " + res.status + ": " + url);
    }

    renewat = renewtime(dig(res.body, "auth", "lease_duration"));

    return String.valueOf(got);
  }

  @Override
  @SuppressWarnings("unchecked")
  public String lookup(String name) {
    checkaddr(addr);

    if (null == livetoken || System.currentTimeMillis() >= renewat) {
      livetoken = login();
    }

    Map<String, Object> ref = Sekreto.vaultref(name);
    String base = trimslash(addr) + "/v1/" + mount;
    String url = 1 == kv ? base + "/" + ref.get("path") : base + "/data/" + ref.get("path");

    Map<String, String> requestheaders = baseheaders();
    requestheaders.put("X-Vault-Token", livetoken);

    Answer res = fetchjson("GET", url, requestheaders, null);

    if (404 == res.status) {
      return null;
    }

    if (200 != res.status) {
      throw new SekretoError("sekreto: hashicorp error: " + res.status + ": " + url);
    }

    Object data = 1 == kv ? dig(res.body, "data") : dig(res.body, "data", "data");

    Object value = data instanceof Map ? ((Map<String, Object>) data).get(ref.get("field")) : null;
    return null == value ? null : String.valueOf(value);
  }

  @Override
  public String describe() {
    return "hashicorp:" + addr + "/" + mount;
  }
}
