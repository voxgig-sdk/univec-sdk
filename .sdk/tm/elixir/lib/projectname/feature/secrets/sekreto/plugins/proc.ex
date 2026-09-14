# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (elixir/plugins/proc.ex)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The child-process half of the two plugins that read a store through its
# own CLI - boru and secretspec - in one place and OUTSIDE THE CORE.
#
# A chain of the four built-in kinds never spawns anything, so this module
# is one of the three things that make a kind a plugin: a socket, a
# signature, a child. It is its own module rather than part of `httpjson`
# because secretspec opens no socket at all, and reaching an HTTP helper
# for a shared string function would load a TLS stack into a process that
# only ever runs a program.
#
# The canonical port has no module of this shape, because node's
# `spawnSync` needs no wrapper. The BEAM's ports do.

defmodule Sekreto.Plugins.Proc do
  @moduledoc """
  Run a child to completion and collect both its streams.

  A plugin module: nothing under `src/` names it. See
  docs/design/plugin-providers.md.
  """

  alias Sekreto.Error

  @doc """
  Run a child to completion and collect both its streams.

  The BEAM's ports cannot give a parent the child's stderr on a channel of
  its own - and boru's and SecretSpec's miss detection is a phrase they
  print THERE, so merging it into stdout would put a diagnostic where a
  secret is supposed to be. The child is therefore started through `sh`
  with its stderr redirected to a file and its stdin taken from
  `/dev/null`, which also delivers the other two obligations: a CLI that
  prompts for a passphrase sees EOF rather than hanging, and a child that
  writes more than one 64 KiB pipe buffer to stderr cannot deadlock,
  because nothing is draining a pipe.

  The arguments go through `$0` and `$@`, so nothing is ever parsed by the
  shell, and the redirect target arrives in the environment rather than
  spliced into the script text.
  """
  def runcmd(command, args, env \\ []) do
    exe = System.find_executable(command)

    if nil == exe do
      raise Error, message: "sekreto: cannot run " <> command <> ": no such file or directory"
    end

    errfile =
      Path.join(
        System.tmp_dir() || "/tmp",
        "sekreto-stderr-#{:erlang.unique_integer([:positive])}"
      )

    script = ~s|exec "$0" "$@" </dev/null 2>"$SEKRETO_STDERR_FILE"|

    try do
      {out, status} =
        System.cmd("/bin/sh", ["-c", script, exe | args],
          env: [{"SEKRETO_STDERR_FILE", errfile} | env],
          stderr_to_stdout: false
        )

      why =
        case File.read(errfile) do
          {:ok, text} -> String.trim(text)
          {:error, _why} -> ""
        end

      %{out: out, why: why, status: status}
    rescue
      err in [ErlangError, ArgumentError] ->
        raise Error, message: "sekreto: cannot run " <> command <> ": " <> Exception.message(err)
    after
      File.rm(errfile)
    end
  end
end
