<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Ref.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Identity: name+tag, written `name$tag` (§4).
 *
 * The four pure functions, and the whole of what `ref` pins. They are the
 * first thing a new port implements and the first corpus section it
 * passes.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
 *
 * \A and \z, NOT ^ and $. PCRE's `$` matches BEFORE A TRAILING NEWLINE and
 * its `^`/`$` become line anchors under `/m`, so a `^...$` spelling admits
 * `"stripe\n"` as a name - the same hole the ruby port surfaced in python,
 * and the reason four `#trailing-newline` entries exist.
 */
const NAME_RE = '/\A[a-zA-Z@][a-zA-Z0-9.~_\-\/]*\z/';

/**
 * §4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
 *
 * The asymmetry with a name is deliberate: a tag MAY start with a digit
 * because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
 * neither `@` nor `/` because a name is a package specifier and a tag is
 * not.
 */
const TAG_RE = '/\A[a-zA-Z0-9.~_-]+\z/';

const REF_MAX = 1024;

/**
 * @param mixed $name
 */
function check_name($name): bool
{
    if (!is_string($name)) {
        return false;
    }
    if ('' === $name || REF_MAX < strlen($name)) {
        return false;
    }
    return 1 === preg_match(NAME_RE, $name);
}

/**
 * @param mixed $tag
 */
function check_tag($tag): bool
{
    if (!is_string($tag)) {
        return false;
    }
    // The empty tag is an ordinary tag (§4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    if ('' === $tag) {
        return true;
    }
    if (REF_MAX < strlen($tag)) {
        return false;
    }
    return 1 === preg_match(TAG_RE, $tag);
}

/**
 * `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
 * tag ''.
 *
 * @param mixed $str
 * @return array{name:string,tag:string}
 */
function parse_ref($str): array
{
    if (!is_string($str)) {
        fail_with('plugin_bad_name', 'ref must be a string');
    }

    // Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
    // in neither character class - so the corpus is the arbiter (§4 rule
    // 5), and it picks the split that blames the part actually at fault:
    // `a$b$c` is a good name with a bad tag, not the reverse.
    $cut = strpos($str, '$');
    $name = false === $cut ? $str : substr($str, 0, $cut);
    $tag = false === $cut ? '' : substr($str, $cut + 1);

    if (!check_name($name)) {
        fail_with('plugin_bad_name', 'invalid plugin name: ' . $name,
                  ['name' => $name]);
    }
    if (!check_tag($tag)) {
        fail_with('plugin_bad_tag', 'invalid plugin tag: ' . $tag,
                  ['name' => $name, 'tag' => $tag]);
    }

    return ['name' => $name, 'tag' => $tag];
}

/**
 * The pair -> `name$tag`. An empty tag NEVER writes the separator, which
 * is the half of canonicalization format_ref owns: parse tolerates
 * `stripe$`, format never produces it, so a round trip is idempotent.
 *
 * @param mixed $name
 * @param mixed $tag
 */
function format_ref($name, $tag = null): string
{
    $tag = null === $tag ? '' : $tag;
    if (!check_name($name)) {
        fail_with('plugin_bad_name',
                  'invalid plugin name: ' . Util::json($name),
                  ['name' => $name]);
    }
    if (!check_tag($tag)) {
        fail_with('plugin_bad_tag', 'invalid plugin tag: ' . Util::json($tag),
                  ['name' => $name, 'tag' => $tag]);
    }
    return '' === $tag ? $name : $name . '$' . $tag;
}

/**
 * The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison.
 *
 * @param mixed $str
 */
function canon_ref($str): string
{
    $r = parse_ref($str);
    return format_ref($r['name'], $r['tag']);
}

/**
 * canon_ref for the internal callers that want the input back unchanged
 * when it is not well formed. NEVER use it where a bad ref must be
 * reported - the corpus pins plugin_bad_name at every public entry.
 *
 * @param mixed $str
 * @return mixed
 */
function canon($str)
{
    try {
        return canon_ref($str);
    } catch (PluginError $e) {
        return $str;
    }
}

/**
 * @param mixed $str
 * @return mixed
 */
function refname($str)
{
    try {
        return parse_ref($str)['name'];
    } catch (PluginError $e) {
        return $str;
    }
}
