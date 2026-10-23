# frozen_string_literal: true

module ActionDispatch
  module I18nRouting
    module Translator
      module PathSegment
        class << self
          private

          # Returns the translation of +str+ in +scope+, falling back to the
          # :routes scope, or +str+ itself when neither has one. Only a String
          # counts as a translation: a key naming a subtree of translations
          # (e.g. "controllers") returns a Hash, which is treated as missing.
          def translate_resource(str, locale, scope)
            [scope, :routes].each do |lookup_scope|
              translation = I18n.t(str, locale: locale, scope: lookup_scope, default: nil)
              return translation if translation.is_a?(String)
            end

            str
          end

          def translate_string(str, locale, scope)
            translated_resource = translate_resource(str, locale.to_s, scope)

            URI::DEFAULT_PARSER.escape translated_resource
          end
        end

        module_function

        # Translates a single path segment.
        #
        # Only the word the segment starts with (letters, digits, "-" and "_",
        # see TRANSLATABLE_SEGMENT) is translated; every other character is
        # kept verbatim: "page(s)" gives "fiche(s)", "people(" gives "gens(".
        # A named param followed by a hyphenated suffix (":id-slug") keeps the
        # param and translates the suffix.
        # The segment is returned untouched when it has no translation, is
        # blank, does not start with such a word ("%C3%BCber", "~me"), begins
        # with "(" (optional group) or "*" (wildcard), or contains a ":" (param
        # key). The argument is never modified, so it may be frozen.
        def translate(segment, locale, scope)
          return segment if segment.empty?

          if segment.start_with?(":")
            named_param, hyphenized = segment.split("-", 2)
            return "#{named_param}-#{translate(hyphenized, locale, scope)}" if hyphenized
          end

          return segment if segment.start_with?("(", "*") || segment.include?(":")

          matches = ActionDispatch::I18nRouting::TRANSLATABLE_SEGMENT.match(segment)
          return segment if matches.nil?

          translation = translate_string(matches[1], locale, scope)
          "#{matches.pre_match}#{translation}#{segment[matches.end(1)..]}"
        end
      end
    end
  end
end
