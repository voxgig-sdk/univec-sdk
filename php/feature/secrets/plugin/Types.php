<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Types.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else.
 *
 * PHP'S ONE STRUCTURAL HAZARD IS THAT ARRAYS ARE VALUES. `$b = $a` copies,
 * so an instance record held in an array cannot be mutated through a
 * second handle the way it can in ruby, python or javascript. Every record
 * the host mutates is therefore an OBJECT (`Entry`, `Host`, `Inst`), and
 * the arrays are only the immutable data that flows through the pure
 * functions.
 *
 * The second hazard is `sort()`, which compares NUMERIC-LOOKING STRINGS AS
 * NUMBERS - `["10","9"]` sorts to `["9","10"]`. Every sort of refs, keys
 * or names in this port passes SORT_STRING, and `Util::sortstrings` is the
 * one place that says so.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * §5.1's seven statuses, and no more. A port that adds an eighth is
 * diverging. `loading` and `closing` are observable only from inside a
 * callback or from another thread.
 */
const STATUSES = ['declared', 'loaded', 'pending', 'live', 'failed',
                  'loading', 'closing'];

/**
 * §12's detail fields, IN THIS FIXED ORDER.
 *
 * The order is part of the contract, not a formatting preference. An
 * earlier draft named six fields while other sections promised diagnostics
 * that had nowhere to go, which would have left each port inventing its
 * own order and breaking message parity.
 */
const DETAIL_ORDER = [
    'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
    'range', 'version', 'match', 'candidates', 'cycle', 'holders',
    'refs', 'path', 'cause',
];

/**
 * `plugin/<code>: <text> [<key>=<value> ...]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array. The
 * bracket is absent entirely when no field applies.
 */
function formaterror(string $code, string $text, ?array $details = null): string
{
    $details = $details ?? [];
    $parts = [];
    foreach (DETAIL_ORDER as $k) {
        if (!array_key_exists($k, $details)) {
            continue;
        }
        $parts[] = $k . '=' . Util::json($details[$k]);
    }
    $tail = empty($parts) ? '' : ' [' . implode(' ', $parts) . ']';
    return 'plugin/' . $code . ': ' . $text . $tail;
}

/**
 * Every error carries a §12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words would
 * make every translation a corpus change. The FORMAT, however, is pinned -
 * a parseable message is what makes a log searchable across twenty
 * languages.
 *
 * `$code` widens `Exception`'s own protected untyped property rather than
 * adding a second one, so `getCode()` and `->code` cannot disagree.
 */
class PluginError extends \Exception
{
    /** @var string */
    public $code;

    public string $text;

    /** @var array<string,mixed> */
    public array $details;

    public function __construct(string $code, string $text, ?array $details = null)
    {
        $this->code = $code;
        $this->text = $text;
        $this->details = $details ?? [];
        parent::__construct(formaterror($code, $text, $details));
    }
}

/**
 * @param array<string,mixed>|null $details
 * @return never
 */
function fail_with(string $code, string $text, ?array $details = null)
{
    throw new PluginError($code, $text, $details);
}

/**
 * The §12 code of an error, or '' for one this library did not raise. The
 * corpus compares by code, so the driver needs one place that knows how to
 * read it.
 *
 * A NON-PLUGIN EXCEPTION CARRYING A STRING CODE STILL COUNTS. §12
 * identifies an error by its code and not by its class, and PHP gives
 * every `Exception` a `$code` that is an integer 0 unless someone set it -
 * so the string test is what separates "a plugin raised its own coded
 * error" from "an ordinary exception".
 */
function codeof(\Throwable $err): string
{
    if ($err instanceof PluginError) {
        return $err->code;
    }
    $code = $err->getCode();
    return is_string($code) && '' !== $code ? $code : '';
}

/**
 * A mutable map with reference semantics.
 *
 * PHP'S ARRAYS ARE VALUES, so `$inst->state['count'] = 1` through a
 * property that holds an array writes to a copy the moment the array is
 * read out of anything but the owning object - and `$x['list'][] = 1`
 * through an ordinary `ArrayAccess` raises "indirect modification" and
 * silently does nothing.
 *
 * `offsetGet` therefore returns BY REFERENCE, which is what makes nested
 * mutation work and what an instance's `state` needs to behave the way it
 * does in every other port. The cost is that a bare read of an absent key
 * CREATES it as null (a reference has to point at something), so read a
 * possibly-absent key with `??`, which goes through `offsetExists` first.
 */
class Bag implements \ArrayAccess, \Countable, \IteratorAggregate, \JsonSerializable
{
    /** @var array<string,mixed> */
    public array $data = [];

    /** @param array<string,mixed> $data */
    public function __construct(array $data = [])
    {
        $this->data = $data;
    }

    public function &offsetGet(mixed $key): mixed
    {
        if (!array_key_exists($key, $this->data)) {
            $this->data[$key] = null;
        }
        return $this->data[$key];
    }

    public function offsetSet(mixed $key, mixed $value): void
    {
        if (null === $key) {
            $this->data[] = $value;
        } else {
            $this->data[$key] = $value;
        }
    }

    public function offsetExists(mixed $key): bool
    {
        return isset($this->data[$key]);
    }

    public function offsetUnset(mixed $key): void
    {
        unset($this->data[$key]);
    }

    public function count(): int
    {
        return count($this->data);
    }

    public function getIterator(): \Iterator
    {
        return new \ArrayIterator($this->data);
    }

    public function jsonSerialize(): mixed
    {
        return $this->data;
    }
}

class Util
{
    /**
     * Byte-wise sort of strings. PHP's default comparison reads
     * numeric-looking strings as NUMBERS, so `sort(['10','9'])` yields
     * `['9','10']` - a ref list ordered by arithmetic. SORT_STRING is the
     * comparison every other port has by default.
     *
     * @param string[] $list
     * @return string[]
     */
    public static function sortstrings(array $list): array
    {
        $out = array_values($list);
        sort($out, SORT_STRING);
        return $out;
    }

    /**
     * A map's keys, byte-wise sorted.
     *
     * @param array<string,mixed> $map
     * @return string[]
     */
    public static function sortedkeys(array $map): array
    {
        return self::sortstrings(array_keys($map));
    }

    /**
     * STABLE sort by a computed key list. PHP 8's `usort` is stable, so
     * this does not decorate with an index the way ruby must - but the key
     * COMPARISON is still this port's own, because the canonical's
     * comparators fall through tiers of mixed numbers and strings and
     * PHP's `<=>` on arrays compares length first.
     *
     * @param array<int,mixed> $list
     * @param callable $keyof item -> list of comparable parts
     * @return array<int,mixed>
     */
    public static function stable_sort_by(array $list, callable $keyof): array
    {
        $out = array_values($list);
        usort($out, static function ($a, $b) use ($keyof) {
            return self::cmpkey($keyof($a), $keyof($b));
        });
        return $out;
    }

    /**
     * Compare two key lists part by part. Numbers compare numerically,
     * strings byte-wise, and a nested list recurses - which is what the
     * capability rank needs for its version triple.
     *
     * @param array<int,mixed> $a
     * @param array<int,mixed> $b
     */
    public static function cmpkey(array $a, array $b): int
    {
        $n = max(count($a), count($b));
        for ($i = 0; $i < $n; $i++) {
            $x = $a[$i] ?? 0;
            $y = $b[$i] ?? 0;
            if (is_array($x) && is_array($y)) {
                $c = self::cmpkey($x, $y);
            } elseif (is_string($x) || is_string($y)) {
                $c = strcmp((string)$x, (string)$y);
            } else {
                $c = $x < $y ? -1 : ($x > $y ? 1 : 0);
            }
            if (0 !== $c) {
                return $c;
            }
        }
        return 0;
    }

    /**
     * A map rather than a list. PHP has ONE array type, so "is this a
     * map?" is "is it not a list?" - and an EMPTY array is both, which is
     * the one place this port cannot see a distinction the corpus can draw
     * (php/AGENTS.md says so, and says why it is safe).
     */
    public static function ismap($value): bool
    {
        return is_array($value) && !array_is_list($value);
    }

    /**
     * MAP-LIKE: an array that is not a NON-EMPTY list. PHP cannot tell an
     * empty map from an empty list, so a merge has to decide which reading
     * to take for `[]`, and the map reading is the one that agrees with
     * every other port on the case that matters: deep-merging `{}` onto a
     * map leaves the map alone, exactly as a javascript spread does, while
     * treating it as a list would silently empty the key.
     *
     * A NON-empty list is unambiguous and always replaces.
     *
     * @param mixed $value
     */
    public static function maplike($value): bool
    {
        return is_array($value) && !(array_is_list($value) && count($value) > 0);
    }

    /**
     * RUBY'S TRUTHINESS, WHICH IS NOT PHP'S. `if x` is false in PHP for
     * `0`, `''`, `'0'` and `[]` - and every one of those is a value the
     * corpus deliberately distinguishes from absence. The empty `options`
     * map that must CLEAR rather than be ignored is exactly this bug:
     * `if ($spec['options'])` skips it, and the instance keeps options a
     * document just removed.
     *
     * So a transcribed truthiness test says what it means here: present,
     * and not false.
     *
     * @param mixed $value
     */
    public static function truthy($value): bool
    {
        return null !== $value && false !== $value;
    }

    /**
     * @param mixed $value
     * @return mixed
     */
    public static function clone_value($value)
    {
        if (is_array($value)) {
            $out = [];
            foreach ($value as $k => $v) {
                $out[$k] = self::clone_value($v);
            }
            return $out;
        }
        return $value;
    }

    /**
     * Compact JSON for an error detail. An empty PHP array renders as `[]`
     * either way; nothing in §12's detail fields distinguishes the two.
     *
     * @param mixed $value
     */
    public static function json($value): string
    {
        $out = json_encode($value, JSON_UNESCAPED_SLASHES);
        return false === $out ? '""' : $out;
    }
}
