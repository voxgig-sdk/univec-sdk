// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (csharp/plugins/Child.cs)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// Running a child process, for the two provider kinds that shell out.
//
// PLUGIN CODE. This file is in the VoxgigSekretoPlugins assembly, which
// the core does not reference - so the core links no
// System.Diagnostics.Process. See docs/design/plugin-providers.md.

using System;
using System.Diagnostics;
using System.Threading.Tasks;

using Voxgig.Sekreto;

namespace Voxgig.Sekreto.Plugins
{
    /// <summary>What a finished child process left behind.</summary>
    internal readonly struct Ran
    {
        internal Ran(string outtext, string why, int status)
        {
            Out = outtext;
            Why = why;
            Status = status;
        }

        internal string Out { get; }

        internal string Why { get; }

        internal int Status { get; }
    }
    internal static class Child
    {
        /// <summary>
        /// Run a child to completion and collect both its streams.
        ///
        /// <para>The two streams are drained CONCURRENTLY. Reading stdout to
        /// EOF and only then reading stderr deadlocks the moment the child
        /// writes more than one pipe buffer (64 KiB on Linux) to stderr: the
        /// parent is blocked waiting for stdout, the child is blocked waiting
        /// for room on stderr, and neither can move. Nothing in this library
        /// sets a timeout, so that hang is permanent. secretspec's
        /// diagnostics are box-drawn and reach that size easily.</para>
        ///
        /// <para>The child's stdin is closed rather than inherited, so a CLI
        /// that reads it - one prompting for a passphrase when its
        /// environment variable is absent - sees EOF and gives up instead of
        /// waiting forever on the parent's own console.</para>
        /// </summary>
        internal static Ran Run(ProcessStartInfo start, string command)
        {
            try
            {
                using Process process = Process.Start(start);

                process.StandardInput.Close();

                // Started before stdout is read, so the child always has a
                // reader on both pipes.
                Task<string> errtask = process.StandardError.ReadToEndAsync();
                string outtext = process.StandardOutput.ReadToEnd();
                string why = errtask.GetAwaiter().GetResult();

                process.WaitForExit();

                return new Ran(outtext, why.Trim(), process.ExitCode);
            }
            catch (Exception err)
            {
                throw new SekretoError("sekreto: cannot run " + command + ": " + err.Message);
            }
        }
    }}
