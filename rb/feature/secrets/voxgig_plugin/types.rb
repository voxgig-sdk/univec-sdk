# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ruby/lib/voxgig_plugin/types.rb)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# frozen_string_literal: true

# Shared types. Deliberately small: the design's section 19 budget says
# the library owns naming, configuration, lifecycle, ordering, binding
# and teardown, and nothing else.
#
# RUBY'S ONE STRUCTURAL HAZARD IS SORT STABILITY. Array#sort and
# #sort_by are NOT guaranteed stable, and the canonical leans on
# JavaScript's stable sort in three places. Every sort in this port goes
# through `Util.stable_sort_by`, which decorates with the original index.

require 'json'

module VoxgigPlugin
  # Section 5.1's seven statuses, and no more. A port that adds an eighth
  # is diverging. `loading` and `closing` are observable only from inside
  # a callback or from another thread.
  STATUSES = %w[declared loaded pending live failed loading closing].freeze

  # Section 12's detail fields, IN THIS FIXED ORDER.
  #
  # The order is part of the contract, not a formatting preference. An
  # earlier draft named six fields while other sections promised
  # diagnostics that had nowhere to go, which would have left each port
  # inventing its own order and breaking message parity.
  DETAIL_ORDER = %w[
    host ref name tag point key capability
    range version match candidates cycle holders
    refs path cause
  ].freeze

  # `plugin/<code>: <text> [<key>=<value> ...]`
  #
  # Values render as COMPACT JSON, so a value containing a space or a
  # bracket cannot break the parse, and a list renders as a JSON array.
  # The bracket is absent entirely when no field applies.
  def self.formaterror(code, text, details = nil)
    details ||= {}
    parts = DETAIL_ORDER.filter_map do |k|
      next unless details.key?(k)

      "#{k}=#{JSON.generate(details[k])}"
    end
    tail = parts.empty? ? '' : " [#{parts.join(' ')}]"
    "plugin/#{code}: #{text}#{tail}"
  end

  # Every error carries a section 12 code. Ports compare by CODE and
  # never by message: wording is a port's own business, and pinning the
  # words would make every translation a corpus change. The FORMAT,
  # however, is pinned - a parseable message is what makes a log
  # searchable across twenty languages.
  class PluginError < StandardError
    attr_reader :code, :text, :details

    def initialize(code, text, details = nil)
      @code = code
      @text = text
      @details = details || {}
      super(VoxgigPlugin.formaterror(code, text, details))
    end
  end

  def self.fail_with(code, text, details = nil)
    raise PluginError.new(code, text, details)
  end

  # The section 12 code of an error, or '' for one this library did not
  # raise. The corpus compares by code, so the driver needs one place
  # that knows how to read it.
  def self.codeof(err)
    err.respond_to?(:code) ? err.code : ''
  end

  module Util
    # STABLE sort by a computed key. Ruby's own sort is not stable, and
    # the canonical's comparators fall through to a tie-break that
    # JavaScript's stable sort resolves by position - so an unstable
    # sort here diverges on nothing the corpus could name.
    def self.stable_sort_by(list)
      list.each_with_index.sort_by { |item, i| [yield(item), i] }.map(&:first)
    end

    def self.map?(value)
      value.is_a?(Hash)
    end

    def self.clone_value(value)
      case value
      when Array then value.map { |v| clone_value(v) }
      when Hash then value.each_with_object({}) { |(k, v), o| o[k] = clone_value(v) }
      else value
      end
    end
  end
end
