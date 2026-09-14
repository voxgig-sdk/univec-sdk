// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Proc.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Running a child process to completion, shared by the two plugins that
// read a secret through somebody else's CLI - boru and secretspec.
//
// In the core of no port: a kind that spawns a process is a plugin.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public final class Proc {

  private Proc() {}

  /** What a finished child process left behind. */
  public static final class Ran {
    final String out;
    final String why;
    final int status;

    Ran(String out, String why, int status) {
      this.out = out;
      this.why = why;
      this.status = status;
    }
  }

  /**
   * Run a child to completion and collect both its streams.
   *
   * <p>The two streams are drained CONCURRENTLY. Reading stdout to EOF and
   * only then reading stderr deadlocks the moment the child writes more than
   * one pipe buffer (64 KiB on Linux) to stderr: the parent is blocked
   * waiting for stdout, the child is blocked waiting for room on stderr, and
   * neither can move. Nothing in this library sets a timeout, so that hang is
   * permanent - `get()` simply never returns. secretspec's diagnostics are
   * box-drawn and reach that size easily.
   *
   * <p>The child's stdin is closed rather than left open on a pipe nobody
   * writes to, so a CLI that reads it - one prompting for a passphrase when
   * its environment variable is absent - sees EOF and gives up instead of
   * waiting forever.
   */
  public static Ran runcmd(ProcessBuilder builder, String command) {
    try {
      Process process = builder.start();

      process.getOutputStream().close();

      ByteArrayOutputStream errbuf = new ByteArrayOutputStream();
      Thread drain =
          new Thread(
              () -> {
                try {
                  process.getErrorStream().transferTo(errbuf);
                } catch (IOException err) {
                  // The child went away mid-write; waitFor reports how.
                }
              });
      drain.setDaemon(true);
      drain.start();

      String out = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
      int status = process.waitFor();
      drain.join();

      return new Ran(out, new String(errbuf.toByteArray(), StandardCharsets.UTF_8).trim(), status);
    } catch (IOException err) {
      throw new SekretoError("sekreto: cannot run " + command + ": " + err.getMessage());
    } catch (InterruptedException err) {
      Thread.currentThread().interrupt();
      throw new SekretoError("sekreto: interrupted running " + command);
    }
  }
}
