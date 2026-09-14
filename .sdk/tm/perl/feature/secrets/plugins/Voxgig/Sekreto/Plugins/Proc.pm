# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Proc.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Proc;

# The child-process half of the two plugins that read a store through its
# own CLI - boru and secretspec - in one place and OUTSIDE the core: a
# chain of built-ins never loads IPC::Open3.
#
# The canonical port has no module of this shape because node's
# `spawnSync` needs no wrapper; perl's open3 does, and duplicating seventy
# lines of it in two plugins would be two places for a deadlock to hide.

use strict;
use warnings;

use Exporter 'import';

use IO::Select ();
use IPC::Open3 ();
use Symbol     ();

our @EXPORT_OK = qw(runcmd);

# Voxgig::Sekreto is loaded by every consumer of this module, and the
# failure path is called by name rather than imported so that nothing here
# has to care which of the two was loaded first.
sub fail { return Voxgig::Sekreto::fail(@_) }

# Run a command, returning (stdout, stderr, exit status).
#
# open3 rather than backticks: the argument list is passed through without a
# shell, so an alias never gets word-split or interpreted, and stderr is
# captured separately from the secret on stdout.
sub runcmd {
    my (@argv) = @_;

    my ( $in, $out );
    my $err = Symbol::gensym();

    my $pid = eval { IPC::Open3::open3( $in, $out, $err, @argv ) };

    fail( 'sekreto: cannot run ' . $argv[0] . ': ' . $@ ) if !$pid;

    # The child's stdin is closed rather than left open on a pipe nobody
    # writes to, so a CLI that reads it - one prompting for a passphrase when
    # its environment variable is absent - sees EOF and gives up instead of
    # waiting forever.
    close($in);

    # Both streams are drained TOGETHER. Reading stdout to EOF and only then
    # reading stderr deadlocks the moment the child writes more than one pipe
    # buffer (64 KiB on Linux) to stderr: this process is blocked waiting for
    # stdout, the child is blocked waiting for room on stderr, and neither can
    # move. Nothing in this library sets a timeout, so that hang is permanent.
    # secretspec's diagnostics are box-drawn and reach that size easily.
    my $sel = IO::Select->new( $out, $err );
    my %text = ( fileno($out) => '', fileno($err) => '' );

    while ( my @ready = $sel->can_read ) {
        for my $handle (@ready) {
            my $chunk = '';
            my $got = sysread( $handle, $chunk, 65536 );
            if ( !defined $got || 0 == $got ) {
                $sel->remove($handle);
                next;
            }
            $text{ fileno($handle) } .= $chunk;
        }
    }

    my $outtext = $text{ fileno($out) };
    my $errtext = $text{ fileno($err) };

    close($out);
    close($err);

    waitpid( $pid, 0 );

    # $? packs the exit code in the HIGH byte and the killing signal in the
    # low one, so `$? >> 8` alone reads a signal-killed child as exit 0 - and
    # the caller then returns its empty stdout as the secret, discarding
    # whatever the child managed to say on stderr. A boru that printed
    # "vault sealed" and was then OOM-killed handed the application '' as a
    # live credential.
    #
    # A child that died from a signal did not answer. Reported as the shells
    # do, 128 + the signal, so it is non-zero and distinguishable. waitpid
    # failure leaves $? at -1, whose low bits are 127, which is also non-zero
    # - the safe direction.
    my $raw    = $?;
    my $status = ( $raw & 127 ) ? 128 + ( $raw & 127 ) : ( $raw >> 8 );

    return (
        defined $outtext ? $outtext : '',
        defined $errtext ? $errtext : '',
        $status,
    );
}


1;
