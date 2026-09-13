# VENDORED: @voxgig/omni 0.1.0 (perl/lib/Voxgig/Omni.pm)
# Source: https://github.com/voxgig/omni @ 274708cc2d12b21707d975543953f845f8444be0  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Omni;

# voxgig omni - shared multi-language test runner.

use strict;
use warnings;

use Voxgig::Omni::Util;
use Voxgig::Omni::Runner;

use Exporter 'import';
our @EXPORT_OK = qw(makeRunner);

our $VERSION = '0.1.0';

sub makeRunner {
    my ( $specref, $provider ) = @_;
    return Voxgig::Omni::Runner::makeRunner( $specref, $provider );
}

1;
