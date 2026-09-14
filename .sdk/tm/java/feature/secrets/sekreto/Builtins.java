// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/src/com/voxgig/sekreto/Builtins.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// THE BUILT-IN PROVIDER KINDS - the same four in every port.
//
// What makes a kind built in is that it needs nothing of the platform
// beyond reading a local file: no socket, no TLS, no crypto, no child
// process. These four are the floor every chain stands on, and a chain
// that reads secrets from options, the environment, a plaintext `.env`
// and a mounted secret directory works with no plugin loaded at all.
// Everything else - the vault clients, the cloud stores, the CLIs - is a
// plugin, and lives under plugins/ (docs/design/plugin-providers.md).
//
// A port of typescript/src/provider/builtin.ts, which is canonical.

package JAVAPACKAGE.feature.secrets.sekreto;

import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

public final class Builtins {

  private Builtins() {}

  /** The four kinds every Sekreto can build, whatever it was handed. */
  public static final List<Definition> BUILTINS = List.of(
      Support.providerplugin("env", spec -> new Env(Support.text(spec.get("prefix")))),
      Support.providerplugin("memory", spec ->
          new Memory(Support.map(spec.get("values")), Support.text(spec.get("prefix")))),
      Support.providerplugin("dotenv", spec ->
          new Dotenv(Support.textor(spec.get("file"), ".env"), Support.text(spec.get("prefix")))),
      Support.providerplugin("file", spec ->
          new File(Support.textor(spec.get("dir"), ""), Support.text(spec.get("prefix")))));

  /** The four names above, in the order the design document lists them. */
  public static final List<String> BUILTIN_KINDS = List.of("env", "memory", "dotenv", "file");

  /**
   * Every kind this library ships as a PLUGIN, so that a kind nobody
   * ships can be told from one the caller simply did not pass in.
   *
   * <p>A list of names and nothing more: naming a plugin here does not
   * reach it, which is the point - the core must not.
   */
  public static final List<String> PLUGIN_KINDS = List.of(
      "hashicorp", "boru", "awssecrets", "awsparams", "gcpsecrets",
      "azuresecrets", "onepassword", "doppler", "infisical", "secretspec");

  /**
   * Does this read failure mean "no secrets here", rather than "I could not
   * answer"?
   *
   * <p>Absence is a MISS and the chain carries on; anything else - permission
   * denied, an unreadable mount, a failing disk - is an ERROR, because
   * returning a miss there falls silently through to a weaker store.
   *
   * <p>Asked of the directory, not of the file. The obvious spelling,
   * {@code !Files.exists(file)}, is wrong in exactly the case the rule exists
   * for: {@code Files.exists} is "did checkAccess throw", so it answers
   * <em>false</em> for an {@code AccessDeniedException} and turned a locked
   * directory - the canonical "unreadable mount" - into a miss. A path whose
   * parent is a plain file (ENOTDIR) really is "no secrets here", and that is
   * what this asks. The reason string is not consulted: it comes from the C
   * library's strerror and follows the machine's locale.
   */
  static boolean absent(Path file) {
    Path dir = file.getParent();
    return null != dir && !Files.isDirectory(dir);
  }

  /** Environment variables: `api.token` from `API_TOKEN`. */
  public static final class Env implements Provider {
    private final String prefix;
    private final Map<String, Object> source;

    public Env(String prefix) {
      this(prefix, null);
    }

    public Env(String prefix, Map<String, Object> source) {
      this.prefix = prefix;
      this.source = source;
    }

    @Override
    public String lookup(String name) {
      String key = Sekreto.envkey(name, prefix);
      Object value = null == source ? System.getenv(key) : source.get(key);
      return null == value ? null : String.valueOf(value);
    }

    @Override
    public String describe() {
      return "env" + (null == prefix || prefix.isEmpty() ? "" : ":" + prefix);
    }
  }

  /** A `.env` file, read once, keyed exactly like the environment. */
  public static final class Dotenv implements Provider {
    private final String file;
    private final String prefix;
    private Map<String, Object> values;

    public Dotenv(String file, String prefix) {
      this.file = file;
      this.prefix = prefix;
    }

    private Map<String, Object> load() {
      if (null == values) {
        Path path = Paths.get(file);
        try {
          values = Sekreto.parsedotenv(
              new String(Files.readAllBytes(path), StandardCharsets.UTF_8));
        } catch (NoSuchFileException err) {
          // An absent file - or an absent directory - means "no secrets
          // here", exactly like the file provider.
          values = new LinkedHashMap<>();
        } catch (IOException err) {
          if (absent(path)) {
            values = new LinkedHashMap<>();
          } else {
            throw new SekretoError(
                "sekreto: dotenv provider cannot read " + file + ": " + err.getMessage());
          }
        }
      }
      return values;
    }

    @Override
    public String lookup(String name) {
      Object value = load().get(Sekreto.envkey(name, prefix));
      return null == value ? null : String.valueOf(value);
    }

    @Override
    public String describe() {
      return "dotenv:" + file;
    }
  }

  /**
   * Literal values, keyed like environment variables. The spec uses this to
   * test chain behaviour without touching the outside world.
   */
  public static final class Memory implements Provider {
    private final Map<String, Object> values;
    private final String prefix;

    public Memory(Map<String, Object> values, String prefix) {
      this.values = null == values ? new LinkedHashMap<>() : values;
      this.prefix = prefix;
    }

    @Override
    public String lookup(String name) {
      Object value = values.get(Sekreto.envkey(name, prefix));
      return null == value ? null : String.valueOf(value);
    }

    @Override
    public String describe() {
      return "memory" + (null == prefix || prefix.isEmpty() ? "" : ":" + prefix);
    }
  }

  /**
   * A directory of one-secret-per-file entries, keyed like the environment:
   * `api.token` reads `<dir>/API_TOKEN`.
   *
   * <p>This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
   * secret, and a systemd credentials directory, so those all work with no
   * further configuration. One trailing newline is stripped - tools that
   * write these files disagree about it, and a newline is never part of a
   * secret on purpose.
   */
  public static final class File implements Provider {
    private final String dir;
    private final String prefix;

    public File(String dir, String prefix) {
      this.dir = null == dir ? "" : dir;
      this.prefix = prefix;
    }

    @Override
    public String lookup(String name) {
      Path file = Paths.get(dir, Sekreto.envkey(name, prefix));

      String text;
      try {
        text = new String(Files.readAllBytes(file), StandardCharsets.UTF_8);
      } catch (NoSuchFileException err) {
        // An absent file - or an absent directory - means "no secrets
        // here", exactly like a missing .env.
        return null;
      } catch (IOException err) {
        if (absent(file)) {
          return null;
        }
        throw new SekretoError(
            "sekreto: file provider cannot read " + file + ": " + err.getMessage());
      }

      if (text.endsWith("\r\n")) {
        return text.substring(0, text.length() - 2);
      }
      if (text.endsWith("\n")) {
        return text.substring(0, text.length() - 1);
      }
      return text;
    }

    @Override
    public String describe() {
      return "file:" + dir;
    }
  }
}
