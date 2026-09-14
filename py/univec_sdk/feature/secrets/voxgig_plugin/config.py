# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/config.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""The declarative document (section 9): normalization, and the ten-level
precedence ladder.

TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.

`normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not merge
options, and cannot: section 9.4 makes merge behaviour a property of the
definition's option SHAPE, which normalization has never seen. A
normalizer that flattened the option layers would make `$MERGE: append`
unimplementable at load time, because the layers it must concatenate would
already be collapsed.

`resolve_options` applies the ladder, and it is the only place that knows
the shape.
"""

from .types import fail
from .ref import canon_ref, parse_ref


# ---------------------------------------------------------------------
# normalize_config
# ---------------------------------------------------------------------

def normalize_config(spec):
    doc = (spec or {}).get('doc') or {}
    keys = (spec or {}).get('keys') or {}
    ikey = keys.get('instance') or 'instance'
    dkey = keys.get('default') or 'default'
    reserved = (spec or {}).get('reserved') or []
    profile = (spec or {}).get('profile')

    # The rename is applied at TWO PLACES AND NO OTHERS: the document
    # root, and every profile.<name> overlay root (section 9.1). A rename
    # applied only at the root would leave `profile.prod.sdk` untranslated
    # and silently drop every environment override the host depends on.
    # Recursing further would be worse: option data is the definition's.
    baseinst = doc.get(ikey)
    basedef = doc.get(dkey) or {}

    overlay = None
    if profile and isinstance(doc.get('profile'), dict):
        overlay = doc['profile'].get(profile)
    overinst = overlay.get(ikey) if isinstance(overlay, dict) else None
    overdef = (overlay.get(dkey) if isinstance(overlay, dict) else None) or {}

    # Entry layers, base then overlay, each as {ref -> entry} plus the
    # order the form implies.
    base = entries(baseinst)
    over = entries(overinst)

    for group in (base['map'], over['map'], basedef, overdef):
        for ref in group:
            checkreserved(ref, reserved)

    # A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
    # the hard way: deriving order from a partial array silently dropped
    # config-activated features. Refs in the base but absent from the
    # overlay still load, in sorted position AFTER the listed ones. A
    # profile may also INTRODUCE a ref the base never declared.
    order = []
    for ref in over['order']:
        if ref not in order:
            order.append(ref)
    # The remainder keeps the BASE's own order - array position for the
    # array form, sorted refs for the map form. Re-sorting here would
    # discard an array document's positional order entirely, which is the
    # one thing the array form exists to express.
    for ref in base['order']:
        if ref not in order:
            order.append(ref)

    instance = {}
    for i, ref in enumerate(order):
        b = base['map'].get(ref)
        o = over['map'].get(ref)

        # MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
        # (section 9.3). A safety rule, not a tidiness one: if the overlay
        # had its defaults filled in before merging it would carry a
        # synthesized active:true and overwrite a base's false - silently
        # re-enabling a deliberately disabled integration in production.
        active = pick(o, 'active', pick(b, 'active', True))
        start = pick(o, 'start', pick(b, 'start', 'eager'))
        block = pick(o, 'order', pick(b, 'order', None))

        # Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        layers = []
        name = parse_ref(ref)['name']
        for src in (basedef.get(name), b, overdef.get(name), o):
            if isinstance(src, dict) and 'options' in src:
                layers.append(src['options'])

        entry = {'pos': i, 'active': active, 'start': start,
                 'optionlayers': layers}
        if None is not block:
            entry['order'] = block
        instance[ref] = entry

    # `default` DECLARES NOTHING (section 9.3). It is a base for every
    # instance of that definition; it does not create one, and an entry
    # for a name with no instances is inert rather than an error - which
    # is what makes a shared library of defaults shippable.
    defout = {}
    for name in basedef:
        defout[name] = basedef[name]
    for name in overdef:
        defout[name] = overdef[name]

    return {'instance': instance, 'order': order, 'default': defout}


def entries(src):
    """Both document forms reduce to {ref -> entry} plus the order the
    form implies: array POSITION for the array form, sorted refs for the
    map form."""
    out = {'map': {}, 'order': []}
    if None is src:
        return out

    if isinstance(src, list):
        for item in src:
            ref = canon_ref(item.get('ref'))
            out['map'][ref] = item
            out['order'].append(ref)
        return out

    # Map-form refs arrive as KEYS, through a different path than an array
    # element's `ref` field - and must canonicalize the same way.
    for key in src:
        out['map'][canon_ref(key)] = src[key]
    # Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    # sort identically under all three, so only mixed input discriminates:
    # '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Python's
    # `sorted` on str is code-point order, which is exactly that.
    out['order'] = sorted(out['map'])
    return out


def checkreserved(ref, reserved):
    """Section 9.1: reservation is all-or-nothing per NAME, so the tagged
    forms go too. A configuration surface that can disable the thing
    reading it is not a surface, it is a trap."""
    if 0 == len(reserved):
        return
    if parse_ref(ref)['name'] in reserved:
        fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref,
             {'ref': ref})


def pick(src, key, default):
    """PRESENCE decides, not truthiness and not None. A JSON `null` is a
    present value in JavaScript (`undefined !== null`), so it must be one
    here."""
    if isinstance(src, dict) and key in src:
        return src[key]
    return default


# ---------------------------------------------------------------------
# resolve_options - section 9.3's ten levels, and 9.4's merge directives
# ---------------------------------------------------------------------

def resolve_options(spec):
    shape = spec.get('shape') or {}
    check_shape(shape)

    ref = canon_ref(spec['ref'])
    name = parse_ref(ref)['name']
    doc = spec.get('doc') or {}
    profile = spec.get('profile')

    overlay = None
    if profile and isinstance(doc.get('profile'), dict):
        overlay = doc['profile'].get(profile)
    overlay = overlay if isinstance(overlay, dict) else {}

    # ONE ordered merge, lowest to highest. Levels 3-6 are not two
    # namespaces collapsed separately and composed afterwards: that
    # inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    # SPECIFICITY, so a prod per-definition default would lose to a base
    # instance value.
    layers = [
        defaultsof(shape),                          # 1
        spec.get('hostdefaults'),                   # 2
        optsof(doc.get('default'), name),           # 3
        optsof(doc.get('instance'), ref),           # 4
        optsof(overlay.get('default'), name),       # 5
        optsof(overlay.get('instance'), ref),       # 6
        spec.get('env'),                            # 7
        spec.get('hostoptions'),                    # 8
        spec.get('loadoptions'),                    # 9
        spec.get('patch'),                          # 10
    ]

    out = {}
    for layer in layers:
        if None is layer:
            continue
        out = mergeone(out, layer, shape)
    return out


def defaultsof(shape):
    """The shape's non-directive values are the level-1 defaults."""
    out = {}
    for key in shape:
        value = shape[key]
        if isinstance(value, dict) and '$MERGE' in value:
            continue
        out[key] = value
    return out


def optsof(src, key):
    if None is src:
        return None
    # The array form is equivalent to the map form (section 9.1).
    if isinstance(src, list):
        for item in src:
            if canon_ref(item.get('ref')) == key:
                return item.get('options')
        return None
    for name in src:
        if canon_ref(name) == key:
            entry = src[name]
            return entry.get('options') if isinstance(entry, dict) else None
    return None


def mergeone(base, over, shape):
    """Merge ONE layer onto the accumulator, honouring the shape's
    directives. The directive holds at EVERY precedence level, not only
    between document levels - section 9.4 makes it a property of the
    shape, which does not know which layer a value arrived from."""
    if None is over:
        return base
    if not ismap(base) or not ismap(over):
        return clone(over)

    out = dict(base)

    for key in over:
        directive = None
        if isinstance(shape, dict) and isinstance(shape.get(key), dict):
            directive = shape[key].get('$MERGE')
        b = out.get(key)
        o = over[key]

        if 'replace' == directive:
            out[key] = clone(o)
        elif 'append' == directive:
            bl = b if isinstance(b, list) else []
            ol = o if isinstance(o, list) else [o]
            out[key] = bl + ol
        elif isinstance(directive, dict) and 'deep' in directive:
            out[key] = deepto(b, o, directive['deep'])
        else:
            # Library default: deep for maps, REPLACE for lists.
            # struct.merge is element-wise by index, which for option maps
            # is nearly always wrong - ["a"] over ["x","y","z"] yielding
            # ["a","y","z"] is the defect station hit on
            # secrets.providers.
            out[key] = mergeone(b, o, None) if ismap(b) and ismap(o) else clone(o)
    return out


def deepto(base, over, n):
    """Merge N levels below this key, replace below that."""
    if 0 >= n:
        return clone(over)
    if not ismap(base) or not ismap(over):
        return clone(over)
    out = dict(base)
    for key in over:
        out[key] = deepto(out.get(key), over[key], n - 1)
    return out


# Section 9.4: N is an integer of at least 1, and everything else is an
# error.
#
# `{"deep": 0}` is rejected DESPITE having an obvious reading, because
# "replace at this key" already has a spelling and two spellings for one
# behaviour is the defect class this repo exists to avoid. Without the
# stated domain each port picks its own reading - reject, replace,
# unlimited merge, or clamp to 1 - and the same document resolves
# differently per language.
MERGE_WORDS = ['replace', 'append']


def check_shape(shape):
    if not ismap(shape):
        return
    for key in shape:
        value = shape[key]
        if not ismap(value) or '$MERGE' not in value:
            continue
        directive = value['$MERGE']

        if isinstance(directive, str):
            if directive not in MERGE_WORDS:
                fail('plugin_shape_invalid',
                     'invalid $MERGE directive at ' + key + ': ' + directive,
                     {'key': key, 'directive': directive})
            continue
        if ismap(directive) and 'deep' in directive:
            n = directive['deep']
            # `isinstance(True, int)` is True in Python, so `{"deep":
            # true}` would pass an int check and be read as depth 1.
            if (not isinstance(n, int)) or isinstance(n, bool) or n < 1:
                fail('plugin_shape_invalid',
                     'invalid $MERGE deep at ' + key + ': ' + str(n),
                     {'key': key, 'directive': directive})
            continue
        fail('plugin_shape_invalid',
             'invalid $MERGE directive at ' + key + ': ' + str(directive),
             {'key': key, 'directive': directive})


def ismap(value):
    return isinstance(value, dict)


def clone(value):
    if isinstance(value, list):
        return [clone(v) for v in value]
    if isinstance(value, dict):
        return {k: clone(v) for k, v in value.items()}
    return value
