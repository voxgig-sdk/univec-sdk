<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/plugin.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The canonical surface `make parity` checks (AGENTS.md §4). Small on
 * purpose (§19): everything else is methods on the host and instance
 * types, because a library that grows a second public entry point per
 * feature is a library twenty ports pay for twice.
 *
 * PLAIN REQUIRES, NO AUTOLOADER AND NO COMPOSER. §16's dependency rule is
 * that `voxgig/struct` is the only permitted runtime dependency; a
 * `vendor/` directory for six files of PSR-4 would be a build step every
 * host embedding this port inherits.
 *
 *   makehost  makecatalog
 *   parseref  formatref  checkname  checktag
 *   normalizeconfig  resolveoptions  resolveorder  resolvecandidates
 *   applyenv
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

require_once __DIR__ . '/Types.php';
require_once __DIR__ . '/Ref.php';
require_once __DIR__ . '/Version.php';
require_once __DIR__ . '/Capability.php';
require_once __DIR__ . '/Resolve.php';
require_once __DIR__ . '/Graph.php';
require_once __DIR__ . '/Order.php';
require_once __DIR__ . '/Config.php';
require_once __DIR__ . '/Env.php';
require_once __DIR__ . '/Export.php';
require_once __DIR__ . '/Point.php';
require_once __DIR__ . '/Catalog.php';
require_once __DIR__ . '/Depend.php';
require_once __DIR__ . '/Host.php';
