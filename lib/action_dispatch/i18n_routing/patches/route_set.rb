# frozen_string_literal: true

require_relative "../translator/route_helpers"
require_relative "../translator/path_segment"

module ActionDispatch
  module I18nRouting
    module Patches
      module RouteSet
        include ActionDispatch::Routing::Redirection

        def add_localized_route(mapping, name, anchor, scope, path, controller, default_action, to, via, formatted, options_constraints, options)
          ActionDispatch::I18nRouting::Translator::RouteHelpers.add(name, named_routes)

          ActionDispatch::I18nRouting.config.available_locales_per_host.each do |host, available_locales|
            sorted_available_locales = available_locales[1..] + [available_locales[0]]
            sorted_available_locales.each do |locale|
              translated_name = translate_name(name, locale, named_routes.names)
              translated_options = translate_options(options, locale)
              translated_options_constraints = translate_options_constraints(options_constraints, locale, host)
              i18n_route_scope = [
                :routes,
                :controllers,
                mapping.defaults[:controller]
              ]
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
                translated_options_constraints,
                anchor
              )
              add_route(translated_mapping, translated_name)
            end
          end
        end

        private

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
          joined_segments = translated_segments.join("/")
          "/#{joined_segments}#{format_segment}".gsub(%r{/\(/}, "(/")
        end

        def display_locale?(locale, host)
          ActionDispatch::I18nRouting.config.available_locales_per_host.fetch(host).many?
        end

        def translate_name(name, locale, named_routes_names = nil)
          return if name.blank?
          translated_name = "#{name}_#{locale.to_s.underscore}"
          translated_name if named_routes_names.exclude?(translated_name.to_sym)
        end

        def translate_options(options, locale)
          translated_options = options.dup || {}
          translated_options[:locale] = locale.to_s if translated_options.exclude?(:locale)
          translated_options
        end

        def translate_options_constraints(options_constraints, locale, host)
          translated_options_constraints = options_constraints.dup || {}
          translated_options_constraints[:locale] = locale.to_s
          translated_options_constraints[:host] = host
          translated_options_constraints
        end

        def translate_mapping(locale, route_set, translated_options, translated_path_ast, scope, controller, default_action, to, formatted, via, translated_options_constraints, anchor)
          scope_params = {
            blocks:      (scope[:blocks] || []).dup,
            constraints: scope[:constraints] || {},
            defaults:    scope[:defaults] || {},
            module:      scope[:module],
            options:     scope[:options] ? scope[:options].merge(translated_options) : translated_options
          }

          ActionDispatch::Routing::Mapper::Mapping.build scope_params, route_set, translated_path_ast, controller, default_action, to, via, formatted, translated_options_constraints, anchor, translated_options
        end
      end
    end
  end
end
