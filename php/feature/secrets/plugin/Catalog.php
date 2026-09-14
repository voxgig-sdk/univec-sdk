<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Catalog.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key - so a malformed shape fails once, and in the same place
 * everywhere (§9.4).
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

class Catalog
{
    /** @var array<string,array<string,mixed>> */
    private array $defs = [];

    /**
     * @param mixed $definition
     */
    public function add($definition): void
    {
        if (!is_array($definition) || !check_name($definition['name'] ?? null)) {
            $name = is_array($definition)
                ? ($definition['name'] ?? null) : $definition;
            fail_with('plugin_definition_name',
                      'invalid definition name: ' . Util::json($name));
        }
        // Validate the shape HERE. Deferring it to resolution time means a
        // malformed shape surfaces at a different moment in every host
        // that loads it, which is the divergence the stated domain exists
        // to prevent.
        if (Util::truthy($definition['shape'] ?? null)) {
            check_shape($definition['shape']);
        }
        $this->defs[$definition['name']] = $definition;
    }

    /**
     * @return array<string,mixed>|null
     */
    public function get(string $name): ?array
    {
        return $this->defs[$name] ?? null;
    }

    public function has(string $name): bool
    {
        return array_key_exists($name, $this->defs);
    }

    /** @return string[] */
    public function names(): array
    {
        return Util::sortedkeys($this->defs);
    }
}

/**
 * @param array<int,mixed>|null $definitions
 */
function make_catalog(?array $definitions = null): Catalog
{
    $catalog = new Catalog();
    foreach ($definitions ?? [] as $d) {
        $catalog->add($d);
    }
    return $catalog;
}
