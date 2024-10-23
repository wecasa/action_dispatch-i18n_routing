# frozen_string_literal: true

module ActionDispatch
  module I18nRouting
    module Patches
      module Mapper
        def localized
          @localized = true
          yield
          @localized = false
        ensure
          @localized = false
        end

        # This method is based on +ActionDispatch::Routing::Mapper::Resources+ (rails v7.2.1.1)
        #
        # Source: https://github.com/rails/rails/blob/a1f6a13f691e0929d40b7e1b1e0d31aa69778128/actionpack/lib/action_dispatch/routing/mapper.rb#L2007-L2032
        #
        def add_route(action, controller, options, _path, to, via, formatted, anchor, options_constraints)
          return super unless @localized

          path = path_for_action(action, _path)
          raise ArgumentError, "path is required" if path.blank?

          action = action.to_s

          default_action = options.delete(:action) || @scope[:action]

          if /^[\w\-\/]+$/.match?(action)
            default_action ||= action.tr("-", "_") unless action.include?("/")
          else
            action = nil
          end

          as = if !options.fetch(:as, true) # if it's set to nil or false
            options.delete(:as)
          else
            name_for_action(options.delete(:as), action)
          end

          path = ActionDispatch::Routing::Mapper::Mapping.normalize_path URI::DEFAULT_PARSER.escape(path), formatted
          ast = ActionDispatch::Journey::Parser.parse path

          mapping = ActionDispatch::Routing::Mapper::Mapping.build(@scope, @set, ast, controller, default_action, to, via, formatted, options_constraints, anchor, options)
          @set.add_localized_route(mapping, as, anchor, @scope, path, controller, default_action, to, via, formatted, options_constraints, options)
        end

        private

        def define_generate_prefix(app, name)
          return super unless @localized

          ActionDispatch::I18nRouting.config.available_locales_per_host.values.flatten.uniq.each do |locale|
            super(app, "#{name}_#{locale.to_s.underscore}")
          end
        end
      end
    end
  end
end
