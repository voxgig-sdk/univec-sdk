
import { cmp, each, File, Content } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


// Emits t/readme_examples.t — a Test::More COMPLETENESS GATE that guarantees
// every fenced `perl` code example across the package docs is unit-tested. It
// reads ALL THREE docs — the root (multi-language) ../README.md, the
// Perl-specific ../README.md, and ../REFERENCE.md — extracts every fenced perl
// block (tagged by source doc + index) and enforces:
//
//   1. SYNTAX  — `perl -c` on every block (with the SDK lib on @INC, so a
//      construction block's `use <Name>SDK` is actually compiled/loaded).
//   2. RUN     — every RUNNABLE block (one that constructs the SDK, drives
//      `$client`, or performs an entity op) is EXECUTED offline in seeded
//      test mode against the real SDK. The captured stdout+stderr is scanned
//      for FATAL perl-level programming-error markers REGARDLESS of exit code,
//      so a bug an example's own eval swallows and prints is still caught.
//      A domain not-found / 404 error never matches FATAL, so it is tolerated.
//   3. COMPLETENESS — every block is partitioned into exactly one of
//      {executed, syntaxchecked-nonrunnable, illustration}; the counts must
//      sum to the total. A runnable-looking block that was not executed lands
//      in neither bucket and FAILS the gate.
//
// A runnable block is rewritten so its client is a test-mode client
// (<Name>SDK->test) seeded with an in-memory fixture for every entity it
// references; any real ->new/->test constructor is rewritten. A block that
// only uses `$client` (constructed in an earlier fenced block) gets a test
// client prepended.
//
// The emitted Perl builds the ``` fence via chr(96) so this generator string
// contains no backticks of its own.
const ReadmeExamplesTest = cmp(function ReadmeExamplesTest(props: any) {
  const { target, ctx$: { model } } = props

  const Name = model.const.Name
  const sdkClass = Name + 'SDK'

  // Entity accessor ($client->Name) => lowercase fixture storage key.
  const entities = each(getModelPath(model, `main.${KIT}.entity`))
    .filter((e: any) => e && e.active !== false)
  const entityLines = entities
    .map((e: any) => `  '${nom(e, 'Name')}' => '${e.name}',`)
    .join('\n')

  // Perl test files use the `.t` extension (run by `prove`), not target.ext
  // (`pl`); this component is invoked inside the `t/` folder by Test_perl.
  File({ name: 'readme_examples.t' }, () => {

    Content(`#!perl
# ${Name} SDK - documentation example COMPLETENESS gate.
#
# Guarantees every fenced perl code example across ALL THREE package docs is
# unit-tested. Reads the root ../README.md, the Perl ../README.md, and
# ../REFERENCE.md, extracts every fenced perl block (tagged by source doc +
# index) and enforces:
#
#   1. SYNTAX - 'perl -c' on every block (SDK lib on \@INC).
#   2. RUN    - every RUNNABLE block (constructs the SDK, drives \$client, or
#      performs an entity op) is EXECUTED offline in seeded test mode
#      (${sdkClass}->test) against the real SDK. Captured output is scanned for
#      a real perl-level error (undefined subroutine, no such method, ...)
#      REGARDLESS of exit code, so a bug an example's own eval swallows and
#      prints cannot slip through. Expected not-found domain errors are
#      tolerated.
#   3. COMPLETENESS - every block is partitioned into exactly one of
#      {executed, syntaxchecked-nonrunnable, illustration}; the counts must sum
#      to the total. A runnable-looking block that was not executed belongs to
#      no bucket and FAILS the gate.
#
# Perl is dynamically typed, so syntax + actually running every example is the
# strongest check available without a live server.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use File::Basename ();
use File::Spec ();
use Cwd ();

my $TEST_DIR = File::Basename::dirname(Cwd::abs_path(__FILE__));
my $PKG_ROOT = Cwd::abs_path(File::Spec->catdir($TEST_DIR, '..'));
my $LIB = File::Spec->catdir($PKG_ROOT, 'lib');

# The three documentation sources this gate covers.
my %DOCS = (
  'root README'    => File::Spec->catfile($PKG_ROOT, '..', 'README.md'),
  'perl README'    => File::Spec->catfile($PKG_ROOT, 'README.md'),
  'perl REFERENCE' => File::Spec->catfile($PKG_ROOT, 'REFERENCE.md'),
);

my $SDK_CLASS = '${sdkClass}';

# Entity accessor (\$client->Name) => fixture storage key (lowercase name).
my %ENTITIES = (
${entityLines}
);

# Documented SDK method names - used only to recognise the NARROW
# signature/method-table "illustration" class.
my @METHODS = qw(options_map get_utility prepare direct data_get data_set match_get match_set make get_name);

# Perl-level errors that indicate a real bug in a documented example (as
# opposed to an expected not-found / domain error, which is tolerated).
my $FATAL = qr/Can't locate object method|Can't locate \\S+ in \\@INC|Undefined subroutine|Not a HASH reference|Not an ARRAY reference|Not a CODE reference|Not a SCALAR reference|Can't use string \\(.*?\\) as a? \\w+ ref|Can't use an undefined value as a? \\w+ reference|Can't call method .* on (?:an undefined value|unblessed reference)|Global symbol .* requires explicit package|Bareword .* not allowed|syntax error|Modification of a read-only value/;

my $FENCE = chr(96) x 3;

my @TMPFILES;
END { unlink @TMPFILES if @TMPFILES }


sub read_doc {
  my ($path) = @_;
  return undef unless -e $path;
  open my $fh, '<:encoding(UTF-8)', $path or return undef;
  local $/;
  my $c = <$fh>;
  close $fh;
  return $c;
}


# Extract every fenced perl block from a document. Split on the fence: odd
# segments are the inside of a fenced block (info string on the first line,
# then code). Only blocks whose info string is exactly "perl" are returned, so
# other-language and plain fences are skipped.
sub blocks_in {
  my ($text) = @_;
  my @blocks;
  my @parts = split /\\Q$FENCE\\E/, $text, -1;
  for (my $i = 1; $i < @parts; $i += 2) {
    my @lines = split /\\n/, $parts[$i], -1;
    my $info = defined $lines[0] ? $lines[0] : '';
    $info =~ s/^\\s+|\\s+$//g;
    if ('perl' eq $info) {
      shift @lines;
      push @blocks, join("\\n", @lines);
    }
  }
  return @blocks;
}


sub all_blocks {
  my @all;
  for my $label (sort keys %DOCS) {
    my $text = read_doc($DOCS{$label});
    next unless defined $text;
    my $i = 0;
    for my $code (blocks_in($text)) {
      push @all, { doc => $label, n => $i, code => $code };
      $i++;
    }
  }
  return @all;
}


# --- classification --------------------------------------------------------

# A block is RUNNABLE when it constructs the SDK, drives \$client, or performs
# an entity operation. Every runnable block MUST be executed.
sub runnable {
  my ($b) = @_;
  return 1 if $b =~ /\\Q$SDK_CLASS\\E->(?:new|test)\\b/;
  return 1 if $b =~ /\\\$client\\b/;
  return 1 if $b =~ /->(?:load|list|create|update|remove)\\b/;
  return 0;
}


# A block "mentions the SDK" when it references \$client, the SDK class, an
# entity accessor, or an entity operation.
sub looks_sdk {
  my ($b) = @_;
  return 1 if $b =~ /\\\$client\\b/;
  return 1 if $b =~ /\\b\\Q$SDK_CLASS\\E\\b/;
  return 1 if $b =~ /->(?:load|list|create|update|remove)\\b/;
  for my $name (keys %ENTITIES) {
    return 1 if $b =~ /->\\Q$name\\E\\b/;
  }
  return 0;
}


# NARROW illustration class: a non-runnable block that references the SDK class
# or a documented method NAME as a signature, and never uses \$client.
sub illustration {
  my ($b) = @_;
  return 0 if runnable($b);
  return 0 if $b =~ /\\\$client\\b/;
  return 1 if $b =~ /\\b\\Q$SDK_CLASS\\E\\b/;
  for my $m (@METHODS) {
    return 1 if $b =~ /\\b\\Q$m\\E\\s*\\(/;
  }
  return 0;
}


sub classify {
  my ($b) = @_;
  return 'executed' if runnable($b);
  return 'illustration' if illustration($b);
  return 'syntaxchecked_nonrunnable' unless looks_sdk($b);
  return 'unclassified';
}


# --- execution -------------------------------------------------------------

# Build the SDK 'entity' fixture option (as Perl source) for the entities a
# block references, falling back to seeding all entities when none are named.
sub fixtures_literal {
  my ($block) = @_;
  my %refs;
  for my $name (sort keys %ENTITIES) {
    $refs{$name} = $ENTITIES{$name} if $block =~ /->\\Q$name\\E\\b/;
  }
  %refs = %ENTITIES unless %refs;
  my @pairs;
  for my $name (sort keys %refs) {
    push @pairs, "'" . $refs{$name} . "' => { 'test01' => { 'id' => 'test01' } }";
  }
  return "{ 'entity' => { " . join(', ', @pairs) . " } }";
}


# Rewrite a runnable block into an executable offline test-mode program: the
# SDK lib is put on \@INC by absolute path; any real ->new/->test constructor
# becomes ${sdkClass}->test(<fixtures>); a block that only uses \$client gets
# such a constructor prepended. The constructor arg match is deliberately
# shallow (no nested parens) - runnable op blocks never build a client inline
# with a paren-bearing argument.
sub to_runner {
  my ($block) = @_;
  my $fixtures = fixtures_literal($block);
  my $body;
  if ($block =~ /\\Q$SDK_CLASS\\E->(?:new|test)\\b/) {
    ($body = $block) =~ s/\\Q$SDK_CLASS\\E->(?:new|test)(?:\\s*\\([^()]*\\))?/$SDK_CLASS->test($fixtures)/g;
  }
  else {
    $body = "my \\\$client = $SDK_CLASS->test($fixtures);\\n" . $block;
  }
  return "use lib '$LIB';\\nuse $SDK_CLASS;\\n" . $body;
}


sub write_temp {
  my ($source) = @_;
  my ($fh, $path) = File::Temp::tempfile(
    'readme_XXXXXX', SUFFIX => '.pl', DIR => File::Spec->tmpdir, UNLINK => 0);
  binmode($fh, ':encoding(UTF-8)');
  print $fh $source;
  close $fh;
  push @TMPFILES, $path;
  return $path;
}


# --- tests -----------------------------------------------------------------

my @BLOCKS = all_blocks();

ok(scalar(@BLOCKS) > 0, 'docs contain perl examples');


# 1. SYNTAX gate: every documented perl block must compile.
{
  my @failures;
  for my $blk (@BLOCKS) {
    my $path = write_temp($blk->{code});
    my $out = qx{"$^X" -I"$LIB" -c "$path" 2>&1};
    if (0 != $?) {
      push @failures, "$blk->{doc} #$blk->{n}:\\n$out\\n$blk->{code}";
    }
  }
  is(scalar(@failures), 0, 'all perl doc blocks have valid syntax')
    or diag(join("\\n\\n", @failures));
}


# 2. RUN gate: every runnable perl block executes offline without a FATAL
# perl-level error (even one an example's eval swallows and prints).
{
  my $ran = 0;
  my @failures;
  for my $blk (@BLOCKS) {
    next unless runnable($blk->{code});
    $ran++;
    my $path = write_temp(to_runner($blk->{code}));
    my $out = qx{"$^X" -I"$LIB" "$path" 2>&1};
    if ($out =~ $FATAL) {
      push @failures, "$blk->{doc} #$blk->{n} (exit @{[ $? >> 8 ]}):\\n$out\\n$blk->{code}";
    }
  }
  ok($ran > 0, 'at least one runnable perl example executed');
  is(scalar(@failures), 0, 'perl doc examples run offline without programming errors')
    or diag(join("\\n\\n", @failures));
}


# 3. COMPLETENESS gate: every block is executed, syntaxchecked-nonrunnable, or
# a narrow illustration - nothing is silently dropped.
{
  my %buckets = (
    executed => [], syntaxchecked_nonrunnable => [], illustration => [], unclassified => []);
  my %per_doc;
  for my $blk (@BLOCKS) {
    my $cls = classify($blk->{code});
    push @{ $buckets{$cls} }, $blk;
    $per_doc{$blk->{doc}} ||= { total => 0, executed => 0, syntaxchecked_nonrunnable => 0, illustration => 0, unclassified => 0 };
    $per_doc{$blk->{doc}}{total}++;
    $per_doc{$blk->{doc}}{$cls}++;
  }

  for my $doc (sort keys %per_doc) {
    my $c = $per_doc{$doc};
    note(sprintf('%-16s total=%d executed=%d syntaxchecked=%d illustration=%d%s',
      $doc, $c->{total}, $c->{executed}, $c->{syntaxchecked_nonrunnable}, $c->{illustration},
      $c->{unclassified} ? ' UNCLASSIFIED=' . $c->{unclassified} : ''));
  }

  my @unclassified = map { "$_->{doc} #$_->{n}:\\n$_->{code}" } @{ $buckets{unclassified} };
  is(scalar(@unclassified), 0,
    'no runnable-looking perl block was left unexecuted')
    or diag(join("\\n\\n", @unclassified));

  my $total = scalar(@BLOCKS);
  my $sum = scalar(@{ $buckets{executed} })
    + scalar(@{ $buckets{syntaxchecked_nonrunnable} })
    + scalar(@{ $buckets{illustration} });
  is($sum, $total,
    'every perl block is executed, syntaxchecked-nonrunnable, or illustration');

  ok(scalar(@{ $buckets{executed} }) > 0, 'at least one executed perl example');
}


done_testing();
`)
  })
})


export {
  ReadmeExamplesTest
}
