// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Azuresecrets.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Azure Key Vault, as a voxgig/plugin definition.
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
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.first;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.headers;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.renewtime;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;

import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * Azure Key Vault.
 *
 * <p>`api.token` reads secret `api-token` (dots flattened to `-`; Key
 * Vault names allow nothing else), current version. The token comes from
 * config, then a client-credentials login when tenant/clientid/
 * clientsecret are given, then the IMDS managed-identity endpoint - so on
 * Azure's own platform no credential configuration is needed.
 *
 * <p>As with GCP, the IMDS call is plain http to a link-local host by
 * platform design and carries no credential; the login and vault
 * addresses are `checkaddr`-guarded.
 */
public final class Azuresecrets implements Provider {

  /** The `azuresecrets` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("azuresecrets", spec ->
      new Azuresecrets(
          Support.text(spec.get("vault")), Support.text(spec.get("token")),
          Support.text(spec.get("tenant")), Support.text(spec.get("clientid")),
          Support.text(spec.get("clientsecret")), Support.text(spec.get("loginaddr")),
          Support.text(spec.get("imdsaddr")), Support.text(spec.get("apiversion"))));
  private static final String RESOURCE = "https://vault.azure.net";

  private final String vault;
  private final String token;
  private final String tenant;
  private final String clientid;
  private final String clientsecret;
  private final String loginaddr;
  private final String imdsaddr;
  private final String apiversion;

  // A configured token is kept forever; logged-in and IMDS tokens carry
  // expires_in and are renewed shortly before they run out.
  private String livetoken;
  private long renewat = Long.MAX_VALUE;

  public Azuresecrets(String vault, String token, String tenant, String clientid,
      String clientsecret, String loginaddr, String imdsaddr, String apiversion) {
    this.vault = vault;
    this.token = token;
    this.tenant = tenant;
    this.clientid = clientid;
    this.clientsecret = clientsecret;
    this.loginaddr = loginaddr;
    this.imdsaddr = imdsaddr;
    this.apiversion = apiversion;
  }

  private String login() {
    if (null != token && !token.isEmpty()) {
      return token;
    }

    if (null != tenant && !tenant.isEmpty()
        && null != clientid && !clientid.isEmpty()
        && null != clientsecret && !clientsecret.isEmpty()) {
      String useloginaddr = first(loginaddr, "https://login.microsoftonline.com");
      checkaddr(useloginaddr);

      String url = trimslash(useloginaddr) + "/" + tenant + "/oauth2/v2.0/token";
      String form = "grant_type=client_credentials&client_id=" + Sigv4.uriescape(clientid)
          + "&client_secret=" + Sigv4.uriescape(clientsecret)
          + "&scope=" + Sigv4.uriescape(RESOURCE + "/.default");

      Answer res = fetchjson(
          "POST", url, headers("content-type", "application/x-www-form-urlencoded"), form);

      Object got = dig(res.body, "access_token");
      if (200 != res.status || null == got || String.valueOf(got).isEmpty()) {
        throw new SekretoError("sekreto: azure login failed: " + res.status);
      }

      renewat = renewtime(dig(res.body, "expires_in"));
      return String.valueOf(got);
    }

    String imds = trimslash(first(imdsaddr, "http://169.254.169.254"))
        + "/metadata/identity/oauth2/token?api-version=2018-02-01&resource="
        + Sigv4.uriescape(RESOURCE);

    Answer res = fetchjson("GET", imds, headers("Metadata", "true"), null);

    Object got = dig(res.body, "access_token");
    if (200 != res.status || null == got || String.valueOf(got).isEmpty()) {
      throw new SekretoError(
          "sekreto: azure: no token, no client credentials, and IMDS did not answer");
    }

    renewat = renewtime(dig(res.body, "expires_in"));
    return String.valueOf(got);
  }

  @Override
  public String lookup(String name) {
    String usevault = null == vault ? "" : vault;
    if (usevault.isEmpty()) {
      throw new SekretoError("sekreto: azure: no vault");
    }

    // Only an explicit scheme is a URL; a vault NAMED httpvault must
    // still become https://httpvault.vault.azure.net.
    String vaulturl =
        usevault.startsWith("http://") || usevault.startsWith("https://")
            ? usevault
            : "https://" + usevault + ".vault.azure.net";
    checkaddr(vaulturl);

    if (null == livetoken || System.currentTimeMillis() >= renewat) {
      livetoken = login();
    }

    String url = trimslash(vaulturl) + "/secrets/" + Sekreto.flatname(name, "-")
        + "?api-version=" + first(apiversion, "7.4");

    Answer res = fetchjson("GET", url, headers("authorization", "Bearer " + livetoken), null);

    if (404 == res.status) {
      return null;
    }

    if (200 != res.status) {
      throw new SekretoError(
          "sekreto: azure error: " + res.status + ": " + url.split("\\?")[0]);
    }

    Object value = dig(res.body, "value");
    return null == value ? null : String.valueOf(value);
  }

  @Override
  public String describe() {
    return "azuresecrets:" + (null == vault ? "" : vault);
  }
}
