// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Boru.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// A boru vault, as a voxgig/plugin definition.
//
// A PLUGIN, NOT PART OF THE CORE: it spawns a process, or opens a
// socket, and the core reads at most a local file. A chain that does not
// name this kind must not carry it, so the calling project imports this
// definition and hands it to Sekreto in the `plugins` option.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.Addr.checkaddr;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.dig;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.fetchjson;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.headers;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Proc.runcmd;

import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Proc.Ran;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * A boru vault (https://github.com/boru-lang/boru).
 *
 * <p>Two ways in, both boru's own.
 *
 * <p>With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
 * secret on stdout and nothing else. The passphrase is read by boru itself
 * from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
 * never puts it on a command line, where it would show up in the process
 * table.
 *
 * <p>With an `addr`, boru's wire protocol: `boru vault serve` publishes a
 * read-only, HashiCorp-shaped provision API (boru's
 * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
 * from `boru vault grant`. A sekreto name is already a valid boru alias,
 * and boru aliases keep their dots, so `api.token` is the single path
 * segment `api.token` - not the `api`/`token` split a HashiCorp KV gets.
 * The value is the `value` field. A 404 is a miss; anything else the
 * server refuses (a revoked capability, a sealed vault) is an error.
 *
 * <p>boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
 * credential *broker*, built precisely so the caller never receives the
 * credential. `vault serve` is the provision endpoint, built to hand the
 * value back - that is the one sekreto uses.
 */
public final class Boru implements Provider {

  /** The `boru` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("boru", spec ->
      new Boru(
          Support.text(spec.get("command")), Support.text(spec.get("namespace")),
          Support.text(spec.get("home")), Support.text(spec.get("addr")),
          Support.text(spec.get("token")), Support.text(spec.get("mount"))));
  private final String command;
  private final String namespace;
  private final String home;
  private final String addr;
  private final String token;
  private final String mount;

  public Boru(String command, String namespace, String home) {
    this(command, namespace, home, null, null, null);
  }

  public Boru(String command, String namespace, String home,
      String addr, String token, String mount) {
    this.command = null == command || command.isEmpty() ? "boru" : command;
    this.namespace = namespace;
    this.home = home;
    this.addr = null == addr ? "" : trimslash(addr);
    this.token = null == token ? "" : token;
    this.mount = null == mount || mount.isEmpty() ? "secret" : mount;
  }

  @Override
  public String lookup(String name) {
    Sekreto.checkname(name);

    if (!addr.isEmpty()) {
      return wirelookup(name);
    }

    String alias = null == namespace || namespace.isEmpty() ? name : namespace + ":" + name;

    ProcessBuilder builder =
        new ProcessBuilder(command, "vault", "get", "--reveal", alias);

    if (null != home && !home.isEmpty()) {
      builder.environment().put("BORU_HOME", home);
    }

    Ran ran = runcmd(builder, command);
    String out = ran.out;
    String why = ran.why;
    int status = ran.status;

    if (0 == status) {
      // boru prints the value and one newline, and nothing else.
      return out.endsWith("\n") ? out.substring(0, out.length() - 1) : out;
    }

    // "no alias named" is boru saying it does not hold this secret, which is
    // a miss: the chain carries on to the next provider. A locked vault or a
    // wrong passphrase is not a miss - treating it as one would fall through
    // to a weaker store without saying so.
    if (borumiss(why)) {
      return null;
    }

    throw new SekretoError(
        "sekreto: boru vault error: " + (why.isEmpty() ? "exit " + status : why));
  }

  @SuppressWarnings("unchecked")
  private String wirelookup(String name) {
    checkaddr(addr);

    // The dotted name stays one path segment: boru aliases keep their dots.
    String alias = null == namespace || namespace.isEmpty() ? name : namespace + "/" + name;
    String url = addr + "/v1/" + mount + "/data/" + alias;

    Answer res = fetchjson("GET", url, headers("X-Vault-Token", token), null);

    if (404 == res.status) {
      return null;
    }

    if (200 != res.status) {
      throw new SekretoError("sekreto: boru serve error: " + res.status + ": " + url);
    }

    Object data = dig(res.body, "data", "data");
    Object value = data instanceof Map ? ((Map<String, Object>) data).get("value") : null;
    return null == value ? null : String.valueOf(value);
  }

  @Override
  public String describe() {
    if (!addr.isEmpty()) {
      return "boru:" + addr;
    }
    return "boru" + (null == namespace || namespace.isEmpty() ? "" : ":" + namespace);
  }

  /**
   * Does this boru failure mean "no such secret" rather than "I could not
   * answer"? Matched on boru's own wording for a missing alias.
   */
  static boolean borumiss(String why) {
    return why.contains("no alias named");
  }
}
