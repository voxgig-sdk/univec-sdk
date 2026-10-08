#!perl
# Univec SDK server variables
#
# A templated base URL takes each {name} from the `server` option. A missing
# or empty value fails construction; test mode fills in test-<name>.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use UnivecSDK;

# A variable no API declares, so the API's own server defaults cannot fill it.
my $base = 'https://api.example.test/bot{zzvar}';

for my $server ({}, { 'zzvar' => '' }) {
  my $client = eval { UnivecSDK->new({ 'base' => $base, 'server' => $server }) };
  my $err = $@;
  ok(!defined $client, 'construction fails without a value for zzvar');
  is(ref $err ? $err->{code} : '', 'server_var_required', 'the error carries its code');
  like("$err", qr/the server variable 'zzvar' is required/, 'the error names the variable');
  like("$err", qr/\Q$base\E/, 'the error quotes the base URL');
}

my $filled = UnivecSDK->new({ 'base' => $base, 'server' => { 'zzvar' => 'T1' } });
is($filled->options_map()->{base}, 'https://api.example.test/botT1',
  'a server value fills the base');

my $testmode = UnivecSDK->new({ 'base' => $base, 'test' => { 'active' => 1 } });
is($testmode->options_map()->{base}, 'https://api.example.test/bottest-zzvar',
  'the test option fills test-<name>');

my $mock = UnivecSDK->test(undef, { 'base' => $base });
is($mock->options_map()->{base}, 'https://api.example.test/bottest-zzvar',
  'the test feature fills test-<name>');

done_testing();
