// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Onepassword.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// 1Password, through a Connect server, as a voxgig/plugin definition.
//
// A PLUGIN, NOT PART OF THE CORE: it opens a socket, and the core reads
// at most a local file. A chain that does not name this kind must not
// carry it, so the calling project imports this definition and hands it
// to Sekreto in the `plugins` option.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.Addr.checkaddr;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.dig;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.fetchjson;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.headers;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;

import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * 1Password, through a Connect server.
 *
 * <p>The item titled `api.token` (titles keep their dots), in the named
 * vault. The value is the field with purpose PASSWORD, or the field
 * labelled `value`. A vault that cannot be found is an error - config
 * names it, so its absence is a broken store, not a missing secret.
 */
public final class Onepassword implements Provider {

  /** The `onepassword` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("onepassword", spec ->
      new Onepassword(
          Support.text(spec.get("addr")), Support.text(spec.get("token")),
          Support.text(spec.get("vault"))));
  private final String addr;
  private final String token;
  private final String vault;

  private String vaultid;

  public Onepassword(String addr, String token, String vault) {
    this.addr = addr;
    this.token = token;
    this.vault = vault;
  }

  private Map<String, String> auth() {
    return headers("authorization", "Bearer " + (null == token ? "" : token));
  }

  private String resolvevault(String useaddr) {
    String want = null == vault ? "" : vault;
    if (want.isEmpty()) {
      throw new SekretoError("sekreto: onepassword: no vault");
    }

    Answer res = fetchjson("GET", useaddr + "/v1/vaults", auth(), null);

    if (200 != res.status || !(res.body instanceof List)) {
      throw new SekretoError("sekreto: onepassword error: " + res.status + ": listing vaults");
    }

    for (Object entry : (List<?>) res.body) {
      Object id = dig(entry, "id");
      if (want.equals(id) || want.equals(dig(entry, "name"))) {
        return String.valueOf(id);
      }
    }

    throw new SekretoError("sekreto: onepassword: no vault named " + want);
  }

  @Override
  public String lookup(String name) {
    Sekreto.checkname(name);

    String useaddr = trimslash(null == addr ? "" : addr);
    if (useaddr.isEmpty()) {
      throw new SekretoError("sekreto: onepassword: no addr");
    }
    checkaddr(useaddr);

    if (null == vaultid) {
      vaultid = resolvevault(useaddr);
    }

    String filter = Sigv4.uriescape("title eq \"" + name + "\"");
    Answer found = fetchjson(
        "GET", useaddr + "/v1/vaults/" + vaultid + "/items?filter=" + filter, auth(), null);

    if (200 != found.status || !(found.body instanceof List)) {
      throw new SekretoError(
          "sekreto: onepassword error: " + found.status + ": finding " + name);
    }

    List<?> items = (List<?>) found.body;
    if (items.isEmpty()) {
      return null;
    }

    Answer item = fetchjson(
        "GET", useaddr + "/v1/vaults/" + vaultid + "/items/" + dig(items.get(0), "id"),
        auth(), null);

    if (200 != item.status) {
      throw new SekretoError(
          "sekreto: onepassword error: " + item.status + ": reading " + name);
    }

    Object fields = dig(item.body, "fields");
    List<?> fieldlist = fields instanceof List ? (List<?>) fields : new ArrayList<>();

    for (Object field : fieldlist) {
      if ("PASSWORD".equals(dig(field, "purpose"))) {
        Object value = dig(field, "value");
        return null == value ? null : String.valueOf(value);
      }
    }
    for (Object field : fieldlist) {
      if ("value".equals(dig(field, "label"))) {
        Object value = dig(field, "value");
        return null == value ? null : String.valueOf(value);
      }
    }

    return null;
  }

  @Override
  public String describe() {
    return "onepassword:" + (null == vault ? "" : vault);
  }
}
