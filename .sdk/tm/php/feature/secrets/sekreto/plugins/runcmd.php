<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/runcmd.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The child-process half of the two plugins that shell out - `boru` and
 * `secretspec` - in one place and OUTSIDE the core: a chain of built-ins
 * never requires this file, and so never reaches `proc_open`.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Sekreto.php';

use Voxgig\Sekreto\SekretoError;

/**
 * Run a child to completion and collect both its streams.
 *
 * Given an ARGV ARRAY, not a command string. `proc_open` with a string runs
 * `/bin/sh -c`, which put every value - the command, the alias, the key -
 * one escaping function away from being interpreted. `escapeshellarg` was
 * doing that job correctly, but it made this the only port whose safety
 * rested on quoting rather than on `execve`, and it broke two things
 * besides: the "cannot run" branch was unreachable, because `sh` always
 * starts and absorbs the exec failure into its own message, and the
 * `BORU_HOME=...` prefix is POSIX-sh syntax that does nothing on Windows,
 * where `proc_open` goes through `cmd.exe`. The array form (PHP 7.4+) makes
 * this port behave like the other eleven.
 *
 * Both pipes are drained TOGETHER. `stream_get_contents` on stdout to EOF
 * and only then on stderr deadlocks the moment the child writes more than
 * one pipe buffer (64 KiB on Linux) to stderr: this process is blocked
 * waiting for stdout, the child is blocked waiting for room on stderr, and
 * neither can move. Nothing in this library sets a timeout, so that hang is
 * permanent. secretspec's diagnostics are box-drawn and reach that size
 * easily.
 *
 * The child's stdin is closed rather than inherited, so a CLI that reads it
 * - one prompting for a passphrase when its environment variable is absent -
 * sees EOF and gives up instead of waiting forever.
 *
 * @param list<string>          $argv
 * @param array<string, string> $env  extra variables for the child only
 *
 * @return array{0: string, 1: string, 2: int} stdout, trimmed stderr, status
 */
function runcmd(array $argv, array $env = []): array
{
    $descriptors = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];

    // null inherits the parent environment; a non-empty $env has to be the
    // whole set, so it is merged rather than replacing it.
    $childenv = [] === $env ? null : array_merge(getenv(), $env);

    $process = @proc_open($argv, $descriptors, $pipes, null, $childenv);

    if (!is_resource($process)) {
        throw new SekretoError('sekreto: cannot run ' . $argv[0]);
    }

    fclose($pipes[0]);

    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $text = [1 => '', 2 => ''];
    $open = [1 => $pipes[1], 2 => $pipes[2]];

    while ([] !== $open) {
        $read = array_values($open);
        $write = null;
        $except = null;

        if (false === @stream_select($read, $write, $except, 30)) {
            break;
        }

        foreach ($read as $handle) {
            $chunk = fread($handle, 65536);
            $key = $handle === $pipes[1] ? 1 : 2;

            if (false === $chunk || ('' === $chunk && feof($handle))) {
                unset($open[$key]);
                continue;
            }

            $text[$key] .= $chunk;
        }
    }

    fclose($pipes[1]);
    fclose($pipes[2]);

    $status = proc_close($process);

    return [$text[1], trim($text[2]), $status];
}
