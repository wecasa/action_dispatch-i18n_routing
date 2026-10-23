# frozen_string_literal: true

require_relative "../translator/route_helpers"
require_relative "../translator/path_segment"

module ActionDispatch
  module I18nRouting
    module Patches
      module RouteSet
        include ActionDispatch::Routing::Redirection

        # +explicit_name+ tells whether +name+ comes from an +as+ option: like
        # Rails, an explicit name already in use raises an ArgumentError, while
        # a derived one leaves the route unnamed.
        def add_localized_route(mapping, name, anchor, scope, path, controller, default_action, to, via, formatted, options_constraints, internal, options, explicit_name: false)
          verify_locales_per_host!
          ActionDispatch::I18nRouting::Translator::RouteHelpers.add(name, named_routes) if name.present?
          i18n_route_scope = translation_scope(mapping.defaults[:controller])

          ActionDispatch::I18nRouting.config.available_locales_per_host.each do |host, available_locales|
            sorted_available_locales = available_locales[1..] + [available_locales[0]]
            sorted_available_locales.each do |locale|
              translated_name = translate_name(name, locale, named_routes.names, explicit_name: explicit_name)
              translated_options = translate_options(options, locale)
              translated_options_constraints = translate_options_constraints(options_constraints, locale, host)
              translated_path = translate_path(path, locale, i18n_route_scope, host)
              translated_path_ast = ActionDispatch::Journey::Parser.parse(translated_path)
              translated_mapping = translate_mapping(
                locale,
                self,
                translated_options,
                translated_path_ast,
                scope,
                controller,
                default_action,
                to,
                formatted,
                via,
                options_constraints,
                translated_options_constraints,
                anchor,
                internal
              )
              add_route(translated_mapping, translated_name)
            end
          end
        end

        private

        # Each locale must belong to a single host, and be listed once there:
        # the localized route names (and so the people_path helpers) only
        # carry the locale, a second route for it could not be named nor
        # generated. Locales are compared as the route names write them, so
        # :"fr-FR", :"fr-fr" and :fr_FR (all "fr_fr") are the same locale.
        def verify_locales_per_host!
          spellings = Hash.new { |hash, locale_name| hash[locale_name] = [] }
          hosts_per_locale = Hash.new { |hash, locale_name| hash[locale_name] = [] }
          ActionDispatch::I18nRouting.config.available_locales_per_host.each do |host, available_locales|
            available_locales.each do |locale|
              locale_name = locale.to_s.underscore
              spellings[locale_name] |= [locale.to_sym]
              hosts_per_locale[locale_name] << host
            end
          end
          describe = ->(locale_name) { spellings[locale_name].map(&:inspect).join(" / ") }

          hosts_per_locale.each do |locale_name, listing_hosts|
            repeating_host = listing_hosts.find { |host| listing_hosts.count(host) > 1 }
            next unless repeating_host

            raise ActionDispatch::I18nRouting::Error,
              "Locale #{describe.call(locale_name)} is listed more than once for host #{repeating_host}"
          end

          shared_locales = hosts_per_locale.select { |_locale_name, listing_hosts| listing_hosts.many? }
          return if shared_locales.empty?

          locales = shared_locales.keys.map(&describe).join(", ")
          hosts = shared_locales.values.flatten.uniq.join(", ")
          subject = shared_locales.one? ? "Locale #{locales} is" : "Locales #{locales} are"
          raise ActionDispatch::I18nRouting::Error,
            "#{subject} configured for several hosts (#{hosts}); each locale must belong to a single host, " \
            'use region-specific locales such as :"fr-FR" and :"fr-CH"'
        end

        # Translations of a route are looked up under its controller, then
        # under :routes (see PathSegment); a route without controller (a
        # redirect, a Rack application) only has the latter.
        def translation_scope(controller)
          controller ? [:routes, :controllers, controller] : [:routes]
        end

        # route.path   => "/cleaning(.:format)"
        # locale       => :"de-AT"
        # route.scope  => [:routes, :controllers, "universe_landing_pages"]
        def translate_path(path, locale, scope, host)
          new_path = path.dup
          format_segment = new_path.slice!(ActionDispatch::I18nRouting::OPTIONAL_FORMAT_REGEX)
          translated_segments = new_path.split("/").map do |seg|
            seg.split(".").map do |phrase|
              ActionDispatch::I18nRouting::Translator::PathSegment.translate(phrase, locale, scope)
            end.join(".")
          end
          translated_segments.reject!(&:empty?)
          translated_segments.unshift(locale.to_s.downcase) if display_locale?(locale, host)
          # Normalized like Rails normalizes a route path: an optional segment
          # takes the slash in front of it ("/de-ch/(:page)" gives
          # "/de-ch(/:page)"), so the bare locale prefix is recognized too.
          joined_path = ActionDispatch::Routing::Mapper.normalize_path("/#{translated_segments.join("/")}")
          "#{joined_path}#{format_segment}"
        end

        def display_locale?(locale, host)
          ActionDispatch::I18nRouting.config.available_locales_per_host.fetch(host).many?
        end

        # Returns nil, leaving the route unnamed, for a blank name or a taken
        # localized name. A taken explicit name is returned anyway, so that
        # RouteSet#add_route raises as Rails does for a duplicate +as+ option.
        def translate_name(name, locale, named_routes_names = nil, explicit_name: false)
          return if name.blank?
          translated_name = "#{name}_#{locale.to_s.underscore}"
          translated_name if explicit_name || named_routes_names.exclude?(translated_name.to_sym)
        end

        def translate_options(options, locale)
          translated_options = options.dup || {}
          translated_options[:locale] = locale.to_s if translated_options.exclude?(:locale)
          translated_options
        end

        # A localized route always gets Hash constraints, pinning its locale
        # and host. Constraints given as a callable are no Hash to merge them
        # into: they become the constraint block of the route instead (see
        # #constraint_blocks).
        def translate_options_constraints(options_constraints, locale, host)
          translated_options_constraints = options_constraints.is_a?(Hash) ? options_constraints.dup : {}
          translated_options_constraints[:locale] = locale.to_s
          translated_options_constraints[:host] = host
          translated_options_constraints
        end

        # Like Rails' Mapping, a route constraint that is not a Hash (a lambda
        # or an object responding to +matches?+) replaces the constraint blocks
        # of the surrounding scope.
        def constraint_blocks(scope_blocks, options_constraints)
          return [options_constraints] unless options_constraints.nil? || options_constraints.is_a?(Hash)

          (scope_blocks || []).dup
        end

        def translate_mapping(locale, route_set, translated_options, translated_path_ast, scope, controller, default_action, to, formatted, via, options_constraints, translated_options_constraints, anchor, internal)
          scope_params = {
            blocks:      constraint_blocks(scope[:blocks], options_constraints),
            constraints: scope[:constraints] || {},
            defaults:    scope[:defaults] || {},
            module:      scope[:module],
            options:     scope[:options] ? scope[:options].merge(translated_options) : translated_options
          }

          ActionDispatch::Routing::Mapper::Mapping.build scope_params, route_set, translated_path_ast, controller, default_action, to, via, formatted, translated_options_constraints, anchor, internal, translated_options
        end
      end
    end
  end
end
