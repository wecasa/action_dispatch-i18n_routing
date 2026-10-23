# frozen_string_literal: true

# The gem relies on ActiveSupport core extensions (String#underscore,
# Enumerable#many?, ...) that a Rails app loads before routes are drawn.
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require "action_dispatch/i18n_routing"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random
  Kernel.srand config.seed

  # Global state (gem config, I18n, ENV) is shared across examples: restore it.
  config.around do |example|
    original_locales_per_host = ActionDispatch::I18nRouting.config.available_locales_per_host
    # With RAILS_ENV=test every localized route registers global
    # ActiveSupport.on_load hooks: keep drawn route sets from piling them up.
    rails_env = ENV.delete("RAILS_ENV")
    example.run
  ensure
    ENV["RAILS_ENV"] = rails_env if rails_env
    ActionDispatch::I18nRouting.config.available_locales_per_host = original_locales_per_host
    I18n.backend.reload!
    I18n.available_locales = nil
    I18n.locale = I18n.default_locale
    # Assigning the locale caches the available locales set computed from the
    # (now empty) backend: drop it so the next example's translations count.
    I18n.config.clear_available_locales_set
  end
end
