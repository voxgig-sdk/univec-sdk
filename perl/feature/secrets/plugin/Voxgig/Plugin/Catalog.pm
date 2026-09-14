# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Catalog.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Catalog;

# The definition catalog (section 10.1).
#
# A definition is registered once and may back many instances. Option
# shapes are validated AT REGISTRATION, not when a document happens to
# exercise a key - so a malformed shape fails once, and in the same place
# everywhere (section 9.4).

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with ismap truthy sortedkeys);
use Voxgig::Plugin::Ref qw(check_name);
use Voxgig::Plugin::Config qw(check_shape);

use Exporter 'import';
our @EXPORT_OK = qw(make_catalog);

sub new {
    my ($class) = @_;
    return bless { defs => {} }, $class;
}

sub add {
    my ($self, $definition) = @_;
    if (!ismap($definition) || !check_name($definition->{name})) {
        my $name = ismap($definition) ? $definition->{name} : $definition;
        $name = defined $name && !ref $name ? $name : '(not a name)';
        fail_with('plugin_definition_name', "invalid definition name: $name");
    }
    # Validate the shape HERE. Deferring it to resolution time means a
    # malformed shape surfaces at a different moment in every host that
    # loads it, which is the divergence the stated domain exists to
    # prevent.
    check_shape($definition->{shape}) if truthy($definition->{shape});
    $self->{defs}{ $definition->{name} } = $definition;
    return;
}

sub get {
    my ($self, $name) = @_;
    return $self->{defs}{$name};
}

sub has {
    my ($self, $name) = @_;
    return exists $self->{defs}{$name} ? 1 : 0;
}

sub names {
    my ($self) = @_;
    return [ sortedkeys($self->{defs}) ];
}

sub make_catalog {
    my ($definitions) = @_;
    my $catalog = Voxgig::Plugin::Catalog->new;
    $catalog->add($_) for @{ $definitions // [] };
    return $catalog;
}

1;
