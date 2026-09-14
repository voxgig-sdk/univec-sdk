// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Secretspec.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// SecretSpec, as a voxgig/plugin definition.
//
// A PLUGIN, NOT PART OF THE CORE: it spawns a process, and the core
// reads at most a local file. A chain that does not name this kind must
// not carry it, so the calling project imports this definition and hands
// it to Sekreto in the `plugins` option.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Proc.runcmd;

import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Proc.Ran;
import java.util.ArrayList;
import java.util.List;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

/**
 * SecretSpec (https://secretspec.dev).
 *
 * <p>SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
 * project needs - plus a chain of its own backends to satisfy them from.
 * That makes it the same shape as sekreto one level down, and the reason to
 * support it is the same reason sekreto exists: a project that has already
 * declared its secrets there should not have to declare them again here.
 *
 * <p>Read through its CLI, as boru is, because that is the interface it
 * offers a program in another language: `secretspec get API_TOKEN` prints
 * the value on stdout and nothing else. A sekreto name maps to a SecretSpec
 * key exactly as it maps to an environment variable - `api.token` is
 * `API_TOKEN` - which is the convention SecretSpec's own examples use.
 *
 * <p>`backend` selects one of SecretSpec's backends (`--provider`, e.g.
 * `keyring` or `dotenv://.env`) and is called `backend` here only because
 * `provider` already means something else in this library.
 *
 * <p>A reason is required, not optional: SecretSpec records every read in
 * an audit log and refuses to read at all without one. sekreto sends
 * `sekreto` unless told otherwise, so the audit trail says which tool
 * asked.
 */
public final class Secretspec implements Provider {

  /** The `secretspec` kind: what `plugins` hands to Sekreto. */
  public static final Definition PLUGIN = Support.providerplugin("secretspec", spec ->
      new Secretspec(
          Support.text(spec.get("command")), Support.text(spec.get("file")),
          Support.text(spec.get("profile")), Support.text(spec.get("backend")),
          Support.text(spec.get("reason")), Support.text(spec.get("prefix"))));
  private final String command;
  private final String file;
  private final String profile;
  private final String backend;
  private final String reason;
  private final String prefix;

  public Secretspec(String command, String file, String profile,
      String backend, String reason, String prefix) {
    this.command = null == command || command.isEmpty() ? "secretspec" : command;
    this.file = file;
    this.profile = profile;
    this.backend = backend;
    this.reason = reason;
    this.prefix = prefix;
  }

  @Override
  public String lookup(String name) {
    String key = Sekreto.envkey(name, prefix);

    List<String> args = new ArrayList<>();
    args.add(command);
    if (null != file && !file.isEmpty()) {
      args.add("--file");
      args.add(file);
    }
    args.add("get");
    args.add(key);
    if (null != backend && !backend.isEmpty()) {
      args.add("--provider");
      args.add(backend);
    }
    if (null != profile && !profile.isEmpty()) {
      args.add("--profile");
      args.add(profile);
    }
    args.add("--reason");
    args.add(null == reason || reason.isEmpty() ? "sekreto" : reason);

    Ran ran = runcmd(new ProcessBuilder(args), command);
    String out = ran.out;
    String why = ran.why;
    int status = ran.status;

    if (0 == status) {
      // The value and one newline, and nothing else.
      return out.endsWith("\n") ? out.substring(0, out.length() - 1) : out;
    }

    if (secretspecmiss(why, key)) {
      return null;
    }

    throw new SekretoError(
        "sekreto: secretspec error: " + (why.isEmpty() ? "exit " + status : why));
  }

  @Override
  public String describe() {
    return "secretspec" + (null == backend || backend.isEmpty() ? "" : ":" + backend);
  }

  /**
   * Does this SecretSpec failure mean "no such secret" rather than "I could
   * not answer"?
   *
   * <p>SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
   * not declare and one declared with no value, and both are misses: this
   * store does not hold it, so the chain carries on.
   *
   * <p>MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
   * `Provider backend 'keyring' not found`, which is a store that could not
   * answer at all - and reading that as a miss is the worst failure this
   * library has, because the chain then falls through to a weaker store
   * without saying so. The key is required to appear, so the two cannot be
   * confused.
   */
  static boolean secretspecmiss(String why, String key) {
    return why.contains("Secret '" + key + "' not found");
  }
}
