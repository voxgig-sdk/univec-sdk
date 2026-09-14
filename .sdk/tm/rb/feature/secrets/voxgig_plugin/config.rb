# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/config.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# The declarative document (section 9): normalization, and the ten-level
# precedence ladder.
#
# TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
#
# `normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not
# merge options, and cannot: section 9.4 makes merge behaviour a property
# of the definition's option SHAPE, which normalization has never seen. A
# normalizer that flattened the option layers would make `$MERGE: append`
# unimplementable at load time, because the layers it must concatenate
# would already be collapsed.
#
# `resolve_options` applies the ladder, and it is the only place that
# knows the shape.

require_relative 'types'
require_relative 'ref'

module VoxgigPlugin
  MERGE_WORDS = %w[replace append].freeze

  def self.normalize_config(input)
    input ||= {}
    doc = input['doc'] || {}
    keys = input['keys'] || {}
    ikey = keys['instance'] || 'instance'
    dkey = keys['default'] || 'default'
    reserved = input['reserved'] || []
    profile = input['profile']

    # The rename is applied at TWO PLACES AND NO OTHERS: the document
    # root, and every profile.<name> overlay root (section 9.1). A rename
    # applied only at the root would leave `profile.prod.sdk`
    # untranslated and silently drop every environment override the host
    # depends on. Recursing further would be worse: option data is the
    # definition's.
    baseinst = doc[ikey]
    basedef = doc[dkey] || {}

    overlay = nil
    overlay = (doc['profile'] || {})[profile] if profile
    overlay = {} unless overlay.is_a?(Hash)
    overinst = overlay[ikey]
    overdef = overlay[dkey] || {}

    # Entry layers, base then overlay, each as {ref -> entry} plus the
    # order the form implies.
    base = config_entries(baseinst)
    over = config_entries(overinst)

    [base[:map].keys, over[:map].keys, basedef.keys, overdef.keys].each do |group|
      group.each { |r| config_checkreserved(r, reserved) }
    end

    # A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
    # the hard way: deriving order from a partial array silently dropped
    # config-activated features. Refs in the base but absent from the
    # overlay still load, in sorted position AFTER the listed ones. A
    # profile may also INTRODUCE a ref the base never declared.
    order = []
    over[:order].each { |r| order << r unless order.include?(r) }
    # The remainder keeps the BASE's own order - array position for the
    # array form, sorted refs for the map form.
    base[:order].each { |r| order << r unless order.include?(r) }

    instance = {}
    order.each_with_index do |ref, i|
      b = base[:map][ref]
      o = over[:map][ref]

      # MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
      # (section 9.3). A safety rule, not a tidiness one: if the overlay
      # had its defaults filled in before merging it would carry a
      # synthesized active:true and overwrite a base's false - silently
      # re-enabling a deliberately disabled integration in production.
      active = config_pick(o, 'active', config_pick(b, 'active', true))
      start = config_pick(o, 'start', config_pick(b, 'start', 'eager'))
      block = config_pick(o, 'order', config_pick(b, 'order', nil))

      # Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
      layers = []
      nm = refname(ref)
      [basedef[nm], b, overdef[nm], o].each do |src|
        layers << src['options'] if src.is_a?(Hash) && src.key?('options')
      end

      ent = { 'pos' => i, 'active' => active, 'start' => start,
              'optionlayers' => layers }
      ent['order'] = block unless block.nil?
      instance[ref] = ent
    end

    # `default` DECLARES NOTHING (section 9.3). It is a base for every
    # instance of that definition; it does not create one, and an entry
    # for a name with no instances is inert rather than an error - which
    # is what makes a shared library of defaults shippable.
    defout = {}
    basedef.each { |n, v| defout[n] = v }
    overdef.each { |n, v| defout[n] = v }

    { 'instance' => instance, 'order' => order, 'default' => defout }
  end

  # Both document forms reduce to {ref -> entry} plus the order the form
  # implies: array POSITION for the array form, sorted refs for the map
  # form.
  def self.config_entries(src)
    out = { map: {}, order: [] }
    return out if src.nil?

    if src.is_a?(Array)
      src.each do |item|
        ref = canon_ref(item['ref'])
        out[:map][ref] = item
        out[:order] << ref
      end
      return out
    end

    # Map-form refs arrive as KEYS, through a different path than an
    # array element's `ref` field - and must canonicalize the same way.
    src.each_key { |key| out[:map][canon_ref(key)] = src[key] }
    # Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    # sort identically under all three, so only mixed input
    # discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
    # 0x61-0x7A. Ruby's String#<=> is bytewise, which is exactly that.
    out[:order] = out[:map].keys.sort
    out
  end

  # Section 9.1: reservation is all-or-nothing per NAME, so the tagged
  # forms go too. A configuration surface that can disable the thing
  # reading it is not a surface, it is a trap.
  def self.config_checkreserved(ref, reserved)
    return if reserved.empty?
    return unless reserved.include?(refname(ref))

    fail_with('plugin_ref_reserved', "ref is reserved by the host: #{ref}",
              { 'ref' => ref })
  end

  # PRESENCE decides, not truthiness and not nil. A JSON `null` is a
  # present value in JavaScript (`undefined !== null`), so it must be one
  # here.
  def self.config_pick(src, key, dflt)
    src.is_a?(Hash) && src.key?(key) ? src[key] : dflt
  end

  # -------------------------------------------------------------------
  # resolve_options - section 9.3's ten levels, and 9.4's directives
  # -------------------------------------------------------------------

  def self.resolve_options(input)
    shape = input['shape'] || {}
    check_shape(shape)

    ref = canon_ref(input['ref'])
    name = refname(ref)
    doc = input['doc'] || {}
    profile = input['profile']

    overlay = nil
    overlay = (doc['profile'] || {})[profile] if profile
    overlay = {} unless overlay.is_a?(Hash)

    # ONE ordered merge, lowest to highest. Levels 3-6 are not two
    # namespaces collapsed separately and composed afterwards: that
    # inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    # SPECIFICITY, so a prod per-definition default would lose to a base
    # instance value.
    layers = [
      config_defaultsof(shape),                     # 1
      input['hostdefaults'],                        # 2
      config_optsof(doc['default'], name),          # 3
      config_optsof(doc['instance'], ref),          # 4
      config_optsof(overlay['default'], name),      # 5
      config_optsof(overlay['instance'], ref),      # 6
      input['env'],                                 # 7
      input['hostoptions'],                         # 8
      input['loadoptions'],                         # 9
      input['patch']                                # 10
    ]

    out = {}
    layers.each do |layer|
      next if layer.nil?

      out = config_mergeone(out, layer, shape)
    end
    out
  end

  # The shape's non-directive values are the level-1 defaults.
  def self.config_defaultsof(shape)
    out = {}
    shape.each do |k, v|
      next if v.is_a?(Hash) && v.key?('$MERGE')

      out[k] = v
    end
    out
  end

  def self.config_optsof(src, key)
    return nil if src.nil?

    # The array form is equivalent to the map form (section 9.1).
    if src.is_a?(Array)
      src.each do |item|
        return item['options'] if canon_ref(item['ref']) == key
      end
      return nil
    end

    src.each_key do |k|
      next unless canon_ref(k) == key

      entry = src[k]
      return entry.is_a?(Hash) ? entry['options'] : nil
    end
    nil
  end

  # Merge ONE layer onto the accumulator, honouring the shape's
  # directives. The directive holds at EVERY precedence level, not only
  # between document levels - section 9.4 makes it a property of the
  # shape, which does not know which layer a value arrived from.
  def self.config_mergeone(base, over, shape)
    return base if over.nil?
    return Util.clone_value(over) unless base.is_a?(Hash) && over.is_a?(Hash)

    out = base.dup

    over.each do |k, o|
      directive = nil
      directive = shape[k]['$MERGE'] if shape.is_a?(Hash) && shape[k].is_a?(Hash)
      b = out[k]

      if directive == 'replace'
        out[k] = Util.clone_value(o)
      elsif directive == 'append'
        bl = b.is_a?(Array) ? b : []
        ol = o.is_a?(Array) ? o : [o]
        out[k] = bl + ol
      elsif directive.is_a?(Hash) && directive.key?('deep')
        out[k] = config_deepto(b, o, directive['deep'])
      else
        # Library default: deep for maps, REPLACE for lists. struct.merge
        # is element-wise by index, which for option maps is nearly
        # always wrong - ["a"] over ["x","y","z"] yielding ["a","y","z"]
        # is the defect station hit on secrets.providers.
        out[k] = if b.is_a?(Hash) && o.is_a?(Hash)
                   config_mergeone(b, o, nil)
                 else
                   Util.clone_value(o)
                 end
      end
    end
    out
  end

  # Merge N levels below this key, replace below that.
  def self.config_deepto(base, over, n)
    return Util.clone_value(over) if n <= 0
    return Util.clone_value(over) unless base.is_a?(Hash) && over.is_a?(Hash)

    out = base.dup
    over.each { |k, v| out[k] = config_deepto(out[k], v, n - 1) }
    out
  end

  # Section 9.4: N is an integer of at least 1, and everything else is an
  # error.
  #
  # `{"deep": 0}` is rejected DESPITE having an obvious reading, because
  # "replace at this key" already has a spelling and two spellings for
  # one behaviour is the defect class this repo exists to avoid.
  def self.check_shape(shape)
    return unless shape.is_a?(Hash)

    shape.each do |k, v|
      next unless v.is_a?(Hash) && v.key?('$MERGE')

      directive = v['$MERGE']

      if directive.is_a?(String)
        next if MERGE_WORDS.include?(directive)

        fail_with('plugin_shape_invalid',
                  "invalid $MERGE directive at #{k}: #{directive}",
                  { 'key' => k, 'directive' => directive })
      end

      if directive.is_a?(Hash) && directive.key?('deep')
        n = directive['deep']
        # `true.is_a?(Integer)` is false in ruby, so the boolean case
        # falls out for free here - unlike python, where it does not.
        next if n.is_a?(Integer) && n >= 1

        fail_with('plugin_shape_invalid',
                  "invalid $MERGE deep at #{k}: #{JSON.generate(n)}",
                  { 'key' => k, 'directive' => directive })
      end

      fail_with('plugin_shape_invalid',
                "invalid $MERGE directive at #{k}: #{JSON.generate(directive)}",
                { 'key' => k, 'directive' => directive })
    end
  end
end
