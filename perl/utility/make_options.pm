# Univec SDK utility: make_options

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_options} = sub {
  my ($ctx) = @_;
  my $options = $ctx->{options} || {};

  # Merge custom utility overrides.
  #
  # A key naming a real utility member REPLACES it; anything else is attached
  # as a custom extra. This mirrors ts, where the utility is an open object
  # and one setprop does both.
  #
  # Without the replace half this was a no-op: every entry went to
  # `{utility}{custom}`, which nothing reads, so a caller passing
  # `utility => { fetcher => $my_transport }` - the documented way to script
  # the transport, and the seam the shared feature corpus runs on - was
  # silently ignored while ts and js honoured it.
  #
  # Option keys are camelCase, as ts spells them; members here are
  # snake_case. Converting rather than listing keeps the mapping to one rule,
  # so a utility added later is overridable without touching this. The
  # registrar has already populated every member, so `exists` is the test for
  # "is this a real one" - once the key is known to be a PUBLIC name.
  my $custom_utils = UnivecHelpers::gp($options, 'utility');
  if (Voxgig::Struct::ismap($custom_utils) && $ctx->{utility}) {
    my $utility = $ctx->{utility};
    for my $k (keys %$custom_utils) {
      # Public utility names are camelCase and carry no underscore, so an
      # underscore means the caller named something of their own - possibly
      # the INTERNAL spelling of a real member. `make_error` must stay an
      # extension in `custom`; replacing the pipeline function with it (ts,
      # js and go all keep it) would break the error path on the next
      # request, silently.
      my $public_name = ($k !~ /_/);
      my $member = $k;
      $member =~ s/([A-Z])/'_' . lc($1)/ge;
      if ($public_name && 'custom' ne $member && exists $utility->{$member}) {
        $utility->{$member} = $custom_utils->{$k};
      }
      else {
        $utility->{custom}{$k} = $custom_utils->{$k};
      }
    }
  }

  # Feature INSTANCES supplied at construction (the station adopt path):
  # consumed by the constructor's extend loop, so they are blessed class
  # instances, not data. This is the perl form of the ts/rb targets'
  # `extend => $ANY` optspec entry: this port deep-clones its options, and
  # Voxgig::Struct::clone would flatten a blessed feature to a plain
  # unblessed hash (and validate rejects the key outright), so the RAW
  # list is captured here and re-attached after validation - the
  # system.fetch idiom. Without this the seam is dead: the constructor
  # reads options.extend, but clone/validate dropped the instances.
  my $extend_raw = UnivecHelpers::gp($options, 'extend');

  my $opts = Voxgig::Struct::clone($options);
  $opts = {} unless Voxgig::Struct::ismap($opts);
  delete $opts->{extend};

  # Feature add-order. options.feature may be given as an ordered ARRAY of
  # { name, active, ...opts } entries (the array position IS the order in
  # which features are added), or as a { name => {opts} } map. Normalize an
  # array to a map (so merge/validate/init are unchanged) and remember the
  # explicit order; a map defaults to test-first so the `test` mock transport
  # is installed as the base of the transport wrapper chain.
  my @featureorder;
  my $feature_raw = UnivecHelpers::gp($opts, 'feature');
  if (Voxgig::Struct::islist($feature_raw)) {
    my %fmap;
    for my $entry (@$feature_raw) {
      next unless Voxgig::Struct::ismap($entry);
      my $name = UnivecHelpers::gp($entry, 'name');
      next unless defined $name && !ref $name;
      my %fopts = %$entry;
      delete $fopts{name};
      $fmap{$name} = \%fopts;
      push @featureorder, $name;
    }
    $opts->{feature} = \%fmap;
  }

  # Normalize plain-scalar booleans at the known boolean slots so
  # validation sees proper JSON booleans.
  UnivecHelpers::coerce_bools($opts);

  my $config = $ctx->{config} || {};
  my $cfgopts = Voxgig::Struct::ismap($config->{options}) ? $config->{options} : {};

  my $JT = Voxgig::Struct::JTRUE();
  my $JF = Voxgig::Struct::JFALSE();

  my $optspec = {
    'apikey' => '',
    'base' => 'http://localhost:8000',
    'prefix' => '',
    'suffix' => '',
    'auth' => { 'prefix' => '' },
    'headers' => { '`$CHILD`' => '`$STRING`' },
    'allow' => {
      'method' => 'GET,PUT,POST,PATCH,DELETE,OPTIONS',
      'op' => 'create,update,load,list,remove,command,direct,graphql',
    },
    'entity' => { '`$CHILD`' => { '`$OPEN`' => $JT, 'active' => $JF, 'alias' => {} } },
    'feature' => { '`$CHILD`' => { '`$OPEN`' => $JT, 'active' => $JF } },
    'utility' => {},
    'system' => {},
    'test' => { 'active' => $JF, 'entity' => { '`$OPEN`' => $JT } },
    'clean' => { 'keys' => 'key,token,id' },
    # Server-variable values for a templated base URL (OpenAPI server
    # variables). The embedded config (configDefinition) carries the
    # spec defaults; user values override them. This port does not yet
    # substitute {name} placeholders into base - the entry keeps the
    # config's server block valid under this optspec.
    'server' => { '`$CHILD`' => '' },
  };

  my $sys_fetch = UnivecHelpers::gpath($opts, 'system.fetch');

  # CLONE the config side: `config` is a process-wide singleton
  # (UnivecConfig::shared_config) and merge uses its nested hashes as merge
  # TARGETS, so without this one client's options (headers, server, ...) are
  # written into the shared config and inherited by every client after it.
  my $merged = Voxgig::Struct::merge([{}, Voxgig::Struct::clone($cfgopts), $opts]);
  my $validated = Voxgig::Struct::validate($merged, $optspec);
  $opts = Voxgig::Struct::ismap($validated) ? $validated : {};

  if ($sys_fetch) {
    $opts->{system} = {} unless Voxgig::Struct::ismap($opts->{system});
    $opts->{system}{fetch} = $sys_fetch;
  }

  # Re-attach the raw extend instances captured above.
  if (Voxgig::Struct::islist($extend_raw)) {
    $opts->{extend} = $extend_raw;
  }

  my $clean_keys = UnivecHelpers::gpath($opts, 'clean.keys');
  $clean_keys = 'key,token,id' unless defined $clean_keys && !ref $clean_keys;
  my @parts;
  for my $p (split /,/, $clean_keys) {
    $p =~ s/^\s+|\s+$//g;
    push @parts, Voxgig::Struct::escre($p) if '' ne $p;
  }
  my $keyre = join('|', @parts);

  # Resolve the feature add-order: an explicit array order (above) wins;
  # otherwise order the map test-first, then the remaining names sorted, so
  # the outcome is deterministic and `test` is always the base transport.
  if (!@featureorder) {
    my $fmap = UnivecHelpers::to_map(
      UnivecHelpers::gp($opts, 'feature')) || {};
    my @names = sort keys %$fmap;
    @featureorder = (grep { 'test' eq $_ } @names)
      ? ('test', grep { 'test' ne $_ } @names)
      : @names;

    # Station special case, mirroring test's: its transport wrap must
    # sit immediately outside the base transport (inside retry/cache/
    # netsim), so map-form activation hoists it to just after test -
    # or first, when no test entry exists. Without this the sorted
    # default would init station last and wrap OUTSIDE the recording
    # features, turning its wire-truth events into fiction.
    my ($si) = grep { 'station' eq $featureorder[$_] } 0 .. $#featureorder;
    if (defined $si) {
      splice @featureorder, $si, 1;
      my ($ti) = grep { 'test' eq $featureorder[$_] } 0 .. $#featureorder;
      splice @featureorder, (defined $ti ? $ti + 1 : 0), 0, 'station';
    }
  }

  $opts->{__derived__} = {
    'clean' => ('' eq $keyre ? {} : { 'keyre' => $keyre }),
    'featureorder' => \@featureorder,
  };

  return $opts;
};

1;
