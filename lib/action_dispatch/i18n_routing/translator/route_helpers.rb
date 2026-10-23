# frozen_string_literal: true

module ActionDispatch
  module I18nRouting
    module Translator
      module RouteHelpers
        TEST_CASE_HOOKS = %i[
          action_controller_test_case action_mailer_test_case action_view_test_case
        ].freeze

        module_function

        # Add standard route helpers for default locale e.g.
        #   I18n.locale = :de
        #   people_path -> people_de_path
        #   I18n.locale = :fr
        #   people_path -> people_fr_path
        # Unnamed routes (nil, "" or false name) get no helper.
        def add(old_name, named_route_collection)
          return if old_name.blank?

          %w[path url].each do |suffix|
            helper_container = named_route_collection.send(:"#{suffix}_helpers_module")
            new_helper_name = :"#{old_name}_#{suffix}"

            helper_container.__send__(:define_method, new_helper_name) do |*args|
              # __send__(Translator.route_name_for(args, old_name, suffix, self), *args)
              locale = args.find { |arg| arg.is_a?(Hash) }&.fetch(:locale, nil)
              locale = (locale || I18n.locale).to_s.underscore
              __send__(:"#{old_name}_#{locale}_#{suffix}", *args)
            end

            # Track the helper in the Set Rails keeps for its own named route
            # helpers (@path_helpers / @url_helpers): helper_names (so it is not
            # a controller action), route_defined? and clear! (so a redraw
            # removes it) then treat it like any other named route helper.
            named_route_collection.instance_variable_get(:"@#{suffix}_helpers") << new_helper_name

            next unless ENV.fetch("RAILS_ENV", nil) == "test"

            TEST_CASE_HOOKS.each do |test_case_hook|
              ActiveSupport.on_load(test_case_hook) do
                include helper_container
              end
            end
          end
        end
      end
    end
  end
end
