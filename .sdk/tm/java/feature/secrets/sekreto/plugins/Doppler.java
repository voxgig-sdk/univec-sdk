// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Doppler.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Doppler, as a voxgig/plugin definition.
//
// A PLUGIN, NOT PART OF THE CORE: it opens a socket, and the core reads
// at most a local file. A chain that does not name this kind must not
// carry it, so the calling project imports this definition and hands it
// to Sekreto in the `plugins` option.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.Addr.checkaddr;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.fetchjson;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.first;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.headers;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;

import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import java.util.LinkedHashMap;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * Doppler.
 *
 * <p>The whole config is downloaded once - Doppler's own bulk endpoint -
 * and answered from memory, like a remote .env: `api.token` is the
 * `API_TOKEN` entry. A service token is config-scoped, so project and
 * config are only needed with broader tokens.
 */
public final class Doppler implements Provider {

  /** The `doppler` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("doppler", spec ->
      new Doppler(
          Support.text(spec.get("token")), Support.text(spec.get("project")),
          Support.text(spec.get("config")), Support.text(spec.get("addr"))));
  private final String token;
  private final String project;
  private final String config;
  private final String addr;

  private Map<String, String> values;

  public Doppler(String token, String project, String config, String addr) {
    this.token = token;
    this.project = project;
    this.config = config;
    this.addr = addr;
  }

  @SuppressWarnings("unchecked")
  private Map<String, String> load() {
    if (null != values) {
      return values;
    }

    String useaddr = trimslash(first(addr, "https://api.doppler.com"));
    checkaddr(useaddr);

    String url = useaddr + "/v3/configs/config/secrets/download?format=json";
    if (null != project && !project.isEmpty()) {
      url += "&project=" + Sigv4.uriescape(project);
    }
    if (null != config && !config.isEmpty()) {
      url += "&config=" + Sigv4.uriescape(config);
    }

    Answer res = fetchjson(
        "GET", url, headers("authorization", "Bearer " + (null == token ? "" : token)), null);

    if (200 != res.status || !(res.body instanceof Map)) {
      throw new SekretoError("sekreto: doppler error: " + res.status);
    }

    values = new LinkedHashMap<>();
    for (Map.Entry<String, Object> entry : ((Map<String, Object>) res.body).entrySet()) {
      if (null != entry.getValue()) {
        values.put(entry.getKey(), String.valueOf(entry.getValue()));
      }
    }

    return values;
  }

  @Override
  public String lookup(String name) {
    return load().get(Sekreto.envkey(name, null));
  }

  @Override
  public String describe() {
    return "doppler"
        + (null == project || project.isEmpty()
            ? "" : ":" + project + "/" + (null == config ? "" : config));
  }
}
