# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin;

# The canonical surface `make parity` checks (AGENTS.md section 4). Small
# on purpose (section 19): everything else is methods on the host and
# instance types, because a library that grows a second public entry point
# per feature is a library twenty ports pay for twice.
#
#   make_host  make_catalog
#   parse_ref  format_ref  check_name  check_tag
#   normalize_config  resolve_options  resolve_order  resolve_candidates
#   apply_env
#
# One package per file, and this one ALIASES rather than re-implements: the
# alias block is the surface, in one place, and a name that stops existing
# stops existing here loudly.

use strict;
use warnings;

use Voxgig::Plugin::Types;
use Voxgig::Plugin::Ref;
use Voxgig::Plugin::Version;
use Voxgig::Plugin::Capability;
use Voxgig::Plugin::Resolve;
use Voxgig::Plugin::Graph;
use Voxgig::Plugin::Order;
use Voxgig::Plugin::Config;
use Voxgig::Plugin::Env;
use Voxgig::Plugin::Export;
use Voxgig::Plugin::Point;
use Voxgig::Plugin::Catalog;
use Voxgig::Plugin::Depend;
use Voxgig::Plugin::Host;

use Exporter 'import';
our @EXPORT_OK = qw(
    make_host make_catalog
    parse_ref format_ref check_name check_tag canon_ref
    normalize_config resolve_options resolve_order resolve_candidates
    resolve_from resolve_capability resolve_graph apply_env
    parse_range satisfies codeof
);

# A glob assignment is a single mention of the name, which `use warnings`
# reads as a probable typo. It is not: the alias IS the surface.
no warnings 'once';

*make_host          = \&Voxgig::Plugin::Host::make_host;
*make_catalog       = \&Voxgig::Plugin::Catalog::make_catalog;
*parse_ref          = \&Voxgig::Plugin::Ref::parse_ref;
*format_ref         = \&Voxgig::Plugin::Ref::format_ref;
*check_name         = \&Voxgig::Plugin::Ref::check_name;
*check_tag          = \&Voxgig::Plugin::Ref::check_tag;
*canon_ref          = \&Voxgig::Plugin::Ref::canon_ref;
*normalize_config   = \&Voxgig::Plugin::Config::normalize_config;
*resolve_options    = \&Voxgig::Plugin::Config::resolve_options;
*resolve_order      = \&Voxgig::Plugin::Order::resolve_order;
*resolve_candidates = \&Voxgig::Plugin::Resolve::resolve_candidates;
*resolve_from       = \&Voxgig::Plugin::Resolve::resolve_from;
*resolve_capability = \&Voxgig::Plugin::Capability::resolve_capability;
*resolve_graph      = \&Voxgig::Plugin::Graph::resolve_graph;
*apply_env          = \&Voxgig::Plugin::Env::apply_env;
*parse_range        = \&Voxgig::Plugin::Version::parse_range;
*satisfies          = \&Voxgig::Plugin::Version::satisfies;
*codeof             = \&Voxgig::Plugin::Types::codeof;

1;
