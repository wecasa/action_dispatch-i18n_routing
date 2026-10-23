# frozen_string_literal: true

module ActionDispatch
  module I18nRouting
    module Patches
      module Mapper
        # Option set by the mounted helpers of a localized engine, see
        # #mounted_helper_script_namer.
        MOUNTED_HELPER_OPTION = :_i18n_routing_mounted_helper

        def localized
          # Restore the enclosing state, so that a nested block does not stop
          # localizing the rest of the outer one.
          previous, @localized = @localized, true
          yield
        ensure
          @localized = previous
        end

        # This method is based on +ActionDispatch::Routing::Mapper::Resources+ (rails v8.1.4)
        #
        # Source: https://github.com/rails/rails/blob/v8.1.4/actionpack/lib/action_dispatch/routing/mapper.rb#L2195-L2215
        #
        def add_route(action, controller, as, options_action, _path, to, via, formatted, anchor, options_constraints, internal, options_mapping)
          return super unless @localized

          path = path_for_action(action, _path)
          raise ArgumentError, "path is required" if path.blank?

          action = action.to_s

          default_action = options_action || @scope[:action]

          if /^[\w\-\/]+$/.match?(action)
            default_action ||= action.tr("-", "_") unless action.include?("/")
          else
            action = nil
          end

          # Like Rails (see +name_for_action+), a name given with +as:+ must be
          # free, while a name derived from the path is dropped when taken.
          explicit_name = as != ActionDispatch::Routing::Mapper::DEFAULT
          as = name_for_action(as, action) if as

          path = ActionDispatch::Routing::Mapper::Mapping.normalize_path URI::RFC2396_PARSER.escape(path), formatted
          ast = ActionDispatch::Journey::Parser.parse path

          mapping = ActionDispatch::Routing::Mapper::Mapping.build(@scope, @set, ast, controller, default_action, to, via, formatted, options_constraints, anchor, internal, options_mapping)
          @set.add_localized_route(mapping, as, anchor, @scope, path, controller, default_action, to, via, formatted, options_constraints, internal, options_mapping, explicit_name:)
        end

        private

        # This method is based on +ActionDispatch::Routing::Mapper::Base+ (rails v8.1.4)
        #
        # Source: https://github.com/rails/rails/blob/v8.1.4/actionpack/lib/action_dispatch/routing/mapper.rb#L698-L730
        #
        # A localized engine is mounted once per locale: each mount point gets
        # its mounted helper (e.g. +blog_fr_fr+), and the engine's own routes
        # generate paths under the mount point of the current +I18n.locale+.
        # When that locale has no mount point, they fall back to the one of
        # +I18n.default_locale+, then to the one of the first configured locale.
        def define_generate_prefix(app, name)
          return super unless @localized

          locales = ActionDispatch::I18nRouting.config.available_locales_per_host.values.flatten.uniq
          script_namers = locales.to_h do |locale|
            locale_name = locale.to_s.underscore
            localized_name = "#{name}_#{locale_name}"
            script_namer = script_namer_for(localized_name)
            app.routes.define_mounted_helper(localized_name, mounted_helper_script_namer(script_namer))
            [locale_name, script_namer]
          end
          # No host configured: the engine is mounted nowhere, its routes keep
          # generating paths without a mount point, as before the draw.
          return if script_namers.empty?

          app.routes.extend Module.new {
            def optimize_routes_generation? = false

            define_method :find_script_name do |options|
              from_mounted_helper = options.delete(MOUNTED_HELPER_OPTION)
              if from_mounted_helper || (options.key?(:script_name) && options[:script_name].present?)
                super(options)
              else
                script_namer = script_namers[I18n.locale.to_s.underscore] ||
                  script_namers[I18n.default_locale.to_s.underscore] ||
                  script_namers.each_value.first
                script_namer.call(options)
              end
            end
          }
        end

        # A mounted helper (e.g. +blog_fr_fr+) gives the engine's routes the
        # script name of its own mount point. That script name is blank for a
        # mount point at "/" (Rails' RoutesProxy keeps only the request's
        # script name, ""), so the helper flags it as given: the engine's
        # routes must not replace it with the mount point of +I18n.locale+.
        # +find_script_name+ removes the flag before the path is generated.
        def mounted_helper_script_namer(script_namer)
          ->(options) do
            options[MOUNTED_HELPER_OPTION] = true
            script_namer.call(options)
          end
        end

        # Builds the script namer Rails builds for the mount route named +name+:
        # it generates the path of the mount point, for the engine's routes.
        def script_namer_for(name)
          route = @set.named_routes.get name
          url_helpers = @set.url_helpers

          ->(options) do
            prefix_options = options.slice(*route.segment_keys)
            prefix_options[:script_name] = "" if options[:original_script_name]

            if options[:_recall]
              prefix_options.reverse_merge!(options[:_recall].slice(*route.segment_keys))
            end

            # We must actually delete prefix segment keys to avoid passing them to next
            # url_for.
            route.segment_keys.each { |k| options.delete(k) }
            url_helpers.public_send(:"#{name}_path", prefix_options)
          end
        end
      end
    end
  end
end
