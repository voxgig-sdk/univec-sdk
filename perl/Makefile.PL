use strict;
use warnings;
use ExtUtils::MakeMaker;

# CPAN distribution metadata for the Univec SDK.
#
# NOTE: `perl Makefile.PL` (run by ExtUtils::MakeMaker) GENERATES a file
# named `Makefile`, which would clobber this port's hand-written
# `Makefile`. Never run it in place - the `publish` target in the
# hand-written Makefile copies the dist sources into a throwaway
# `.release/` directory and builds there instead.

WriteMakefile(
    NAME             => 'UnivecSDK',
    VERSION_FROM     => 'lib/UnivecSDK.pm',
    ABSTRACT         => 'Unofficial generated perl SDK for the UniVec public API. Not affiliated with or endorsed by the upstream API provider.',
    AUTHOR           => 'Voxgig',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '5.018',
);
