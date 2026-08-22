#!perl
# Univec SDK netsim test
#
# Network-behaviour simulation over the offline mock transport. The test
# feature accepts an optional "net" config so unit tests can exercise slow,
# failing and offline conditions without a live server. These checks drive
# the transport through direct(), which needs no entity, so they run for
# every generated SDK regardless of its API shape.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Time::HiRes ();

use UnivecSDK;

{
  my $sdk = UnivecSDK->test({ 'net' => { 'offline' => 1 } }, undef);
  my $res = $sdk->direct({ 'path' => '/ping' });
  ok(!$res->{ok}, 'offline network must fail the call');
  ok(defined $res->{err}, 'offline network yields an error');
}

{
  my $sdk = UnivecSDK->test({ 'net' => { 'failTimes' => 1, 'failStatus' => 503 } }, undef);
  my $res = $sdk->direct({ 'path' => '/ping' });
  ok(!$res->{ok}, 'failStatus simulation fails the call');
  is($res->{status}, 503, 'simulated failure status is surfaced');
}

{
  my $sdk = UnivecSDK->test({ 'net' => { 'errorTimes' => 1 } }, undef);
  my $res = $sdk->direct({ 'path' => '/ping' });
  ok(!$res->{ok}, 'errorTimes simulation fails the call');
  like('' . $res->{err}, qr/connection error/i, 'errorTimes yields a connection error');
}

{
  my $delay = 60;
  my $sdk = UnivecSDK->test({ 'net' => { 'latency' => $delay } }, undef);
  my $start = Time::HiRes::time();
  $sdk->direct({ 'path' => '/ping' });
  my $elapsed = int((Time::HiRes::time() - $start) * 1000);
  # Generous lower bound to stay robust on slow CI.
  ok($elapsed >= $delay - 25, "expected >= @{[$delay - 25]}ms latency, got ${elapsed}ms");
}

{
  my $sdk = UnivecSDK->test(undef, undef);
  ok(defined $sdk, 'plain test SDK still works with no net simulation');
}

done_testing();
