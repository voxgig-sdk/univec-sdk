<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Resolve.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Dynamic resolution (§10.2) - name to candidate module ids.
 *
 * PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in
 * every language including those with no dynamic loading at all, and it is
 * why §15.4 puts real module loading in per-port integration tests rather
 * than here.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

const DEFAULT_SOURCES = [
    ['kind' => 'module',
     'prefix' => ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', '']],
];

/**
 * @param mixed $sources
 * @return string[]
 */
function resolve_candidates(string $name, $sources = null): array
{
    $out = [];

    // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
    // already a package id; prefixing it produces
    // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if (str_starts_with($name, '@')) {
        return [$name];
    }

    $list = (null === $sources || [] === $sources) ? DEFAULT_SOURCES : $sources;

    foreach ($list as $src) {
        $kind = $src['kind'] ?? null;
        if ('module' === $kind) {
            $prefixes = $src['prefix'] ?? null;
            if (null === $prefixes || [] === $prefixes) {
                $prefixes = [''];
            }
            foreach ($prefixes as $p) {
                $id = $p . $name;
                if (!in_array($id, $out, true)) {
                    $out[] = $id;
                }
            }
        } elseif ('path' === $kind) {
            $id = preg_replace('/\/+\z/', '', (string)($src['dir'] ?? '')) . '/' . $name;
            if (!in_array($id, $out, true)) {
                $out[] = $id;
            }
        }
    }

    return $out;
}

/**
 * A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name with
 * a letter or `@`, so `./local/thing` is not a ref and never reaches
 * candidate generation - seneca allows a path where a plugin name goes,
 * and this design deliberately does not, because a ref is an ADDRESS
 * WITHIN A HOST and a path is a LOCATION ON A DISK.
 *
 * @param mixed $from
 * @return array<int,mixed>
 */
function resolve_from($from): array
{
    return [$from];
}
