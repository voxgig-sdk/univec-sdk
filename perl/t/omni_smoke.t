#!perl
# Smoke tests for the vendored omni runner itself: a runner that cannot
# FAIL a bad entry would turn every corpus suite vacuously green, so pin
# the failure paths, not just the happy one. (Perl peer of ts's
# test/omni.test.ts and py's test_omni_smoke.py.)

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename ();
use Cwd ();

use UnivecSDK;

require(Cwd::abs_path("$FindBin::Bin/omni.pm"));

# A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
# like the shared corpus).
my $SPEC = {
  primary => {
    smoke => {
      basic => {
        set => [
          { in => 1, out => 2 },
          { in => 41, out => 42 },
        ],
      },
      bad => {
        set => [
          { in => 1, out => 999 },
        ],
      },
      err => {
        set => [
          { in => 0, err => 'zero refused' },
        ],
      },
    },
  },
};

my $inc = sub {
  my ($n) = @_;
  die "smoke: zero refused\n" if !ref($n) && defined($n) && '0' eq "$n";
  return $n + 1;
};

sub smoke_pack {
  my $runner = UnivecOmni::make_runner($SPEC, UnivecSDK->test(undef, undef));
  return $runner->('smoke');
}

# A correct subject passes.
{
  my $R = smoke_pack();
  my $ok = eval { $R->{runset}->($R->{spec}{basic}, $inc); 1 };
  ok($ok, 'runset passes a correct subject') or diag($@);
}

# A wrong result fails, with an OmniError naming the mismatch.
{
  my $R = smoke_pack();
  my $ok = eval { $R->{runset}->($R->{spec}{bad}, $inc); 1 };
  ok(!$ok, 'runset fails a wrong result');
  my $err = $@;
  ok(UnivecOmni::is_omni_error($err), 'the failure is an OmniError');
  like("$err", qr/result mismatch/, 'the failure names the result mismatch');
}

# The expected error occurs: passes. The expected error does NOT occur:
# must fail.
{
  my $R = smoke_pack();
  my $ok = eval { $R->{runset}->($R->{spec}{err}, $inc); 1 };
  ok($ok, 'an expected error that occurs passes') or diag($@);

  $ok = eval { $R->{runset}->($R->{spec}{err}, sub { my ($n) = @_; return $n }); 1 };
  ok(!$ok, 'a missing expected error fails');
  my $err = $@;
  ok(UnivecOmni::is_omni_error($err), 'the missing-error failure is an OmniError');
  like("$err", qr/expected error did not occur/,
    'the failure says the expected error did not occur');
}

done_testing();
