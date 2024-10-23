# frozen_string_literal: true

require "action_dispatch"
require "action_dispatch/routing"
require "action_dispatch/routing/redirection"
require "action_dispatch/routing/mapper"
require "action_dispatch/routing/route_set"

require "dry/configurable"

require_relative "i18n_routing/version"
require_relative "i18n_routing/apply_patches"

module ActionDispatch
  module I18nRouting
    extend Dry::Configurable

    TRANSLATABLE_SEGMENT = /^([-_a-zA-Z0-9]+)(\()?/
    OPTIONAL_FORMAT_REGEX = %r{(?:\(\.:format\)+|\.:format)\Z}

    # Value required!
    #
    # The key of the Hash needs to be a host.
    # Example: +"localhost.fr"+
    #
    # The value of the +Hash+ needs to be an array of locales (symbol).
    # The first value is considered the default locale of the host.
    # Example: +[:'fr-FR']+
    #
    # Example:
    # +++
    # ActionDispatch::I18nRouting.config.available_locales_per_host = {
    #   "localhost.ch" => [:"de-CH", :"fr-CH", :"it-CH"],
    #   "localhost.co.uk" => [:"en-GB"],
    #   "localhost.de" => [:"de-DE"],
    #   "localhost.fr" => [:"fr-FR"]
    # }
    # +++
    #
    setting :available_locales_per_host, default: {}

    class Error < StandardError; end
  end
end
