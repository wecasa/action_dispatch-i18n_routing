# frozen_string_literal: true

require "abstract_controller"

RSpec.describe ActionDispatch::I18nRouting::Translator::RouteHelpers do
  let(:route_set) { ActionDispatch::Routing::RouteSet.new }
  let(:named_routes) { route_set.named_routes }
  let(:rails_env) { nil }

  # An object behaving like a view/controller: it includes the route set's
  # url helpers (path + url) and has a default host for *_url helpers.
  let(:helpers) do
    routes = route_set
    helper_class = Class.new { include routes.url_helpers }
    helper_class.default_url_options = {host: "www.example.test"}
    helper_class.new
  end

  # Keep the RAILS_ENV == "test" branch under the example's control (whatever
  # the RAILS_ENV of the process running the suite) so that no
  # ActiveSupport.on_load hook is registered unless an example asks for it.
  around do |example|
    original_rails_env = ENV.fetch("RAILS_ENV", nil)
    assign_rails_env(rails_env)
    example.run
  ensure
    assign_rails_env(original_rails_env)
  end

  before do
    # Rails' named route helpers reference ActionController::Parameters when
    # the last argument is not a Hash. action_controller itself can't be
    # required here, so provide a stand-in for the duration of the example.
    stub_const("ActionController::Parameters", Class.new) unless defined?(ActionController::Parameters)

    I18n.available_locales = %i[en fr-FR fr-CH de-CH sr-Latn-RS]
  end

  def assign_rails_env(value)
    if value.nil?
      ENV.delete("RAILS_ENV")
    else
      ENV["RAILS_ENV"] = value
    end
  end

  # Named routes shaped like the ones the gem generates for a localized route:
  # "<name>_<locale.underscore>", with the locale as a route default.
  def draw_localized_variants
    route_set.draw do
      get "personnes", to: "people#index", as: :people_fr_fr, defaults: {locale: "fr-FR"}
      get "fr-ch/gens", to: "people#index", as: :people_fr_ch, defaults: {locale: "fr-CH"}
      get "de-ch/leute", to: "people#index", as: :people_de_ch, defaults: {locale: "de-CH"}
      get "sr-latn-rs/ljudi", to: "people#index", as: :people_sr_latn_rs, defaults: {locale: "sr-Latn-RS"}
      get "personnes/:id", to: "people#show", as: :person_fr_fr, defaults: {locale: "fr-FR"}
      get "fr-ch/gens/:id", to: "people#show", as: :person_fr_ch, defaults: {locale: "fr-CH"}
    end
  end

  describe ".add" do
    before { draw_localized_variants }

    context "when defining the helpers" do
      before { described_class.add(:people, named_routes) }

      it "exposes <name>_path and <name>_url to objects including the route set's url helpers" do
        expect(helpers).to respond_to(:people_path, :people_url)
      end

      it "defines <name>_path in the path helpers module only" do
        expect(named_routes.path_helpers_module.method_defined?(:people_path)).to be(true)
        expect(named_routes.url_helpers_module.method_defined?(:people_path)).to be(false)
      end

      it "defines <name>_url in the url helpers module only" do
        expect(named_routes.url_helpers_module.method_defined?(:people_url)).to be(true)
        expect(named_routes.path_helpers_module.method_defined?(:people_url)).to be(false)
      end

      it "exposes only <name>_url when the url helpers are included without path helpers" do
        routes = route_set
        url_only = Class.new { include routes.url_helpers(false) }.new

        expect(url_only).to respond_to(:people_url)
        expect(url_only).not_to respond_to(:people_path)
      end

      it "makes the helper callable on the route set's url_helpers module itself" do
        I18n.with_locale(:"fr-CH") do
          expect(route_set.url_helpers.people_path).to eq("/fr-ch/gens")
        end
      end

      it "does not define helpers for other route names" do
        expect(helpers).not_to respond_to(:person_path)
        expect(helpers).not_to respond_to(:person_url)
      end

      it "keeps the locale-specific helpers working" do
        expect(helpers.people_fr_ch_path).to eq("/fr-ch/gens")
      end
    end

    it "accepts the route name as a String" do
      described_class.add("people", named_routes)

      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_path).to eq("/personnes")
      end
    end

    it "keeps dispatching correctly when called twice for the same name" do
      2.times { described_class.add(:people, named_routes) }

      I18n.with_locale(:"de-CH") do
        expect(helpers.people_path).to eq("/de-ch/leute")
        expect(helpers.people_url).to eq("http://www.example.test/de-ch/leute")
      end
    end

    it "lists the helpers only once in helper_names when called twice for the same name" do
      2.times { described_class.add(:people, named_routes) }

      expect(named_routes.helper_names.tally.values_at("people_path", "people_url")).to eq([1, 1])
    end

    # The collection tracks its helpers to answer helper_names (subtracted
    # from controller action methods), route_defined? and to remove them on
    # clear! (when the routes are redrawn): the generic helpers must be part
    # of it like any named route helper.
    context "when registering the helpers in the named route collection" do
      before { described_class.add(:people, named_routes) }

      it "lists <name>_path and <name>_url in helper_names" do
        expect(named_routes.helper_names).to include("people_path", "people_url")
      end

      it "reports <name>_path and <name>_url as defined by route_defined?" do
        expect(named_routes.route_defined?(:people_path)).to be(true)
        expect(named_routes.route_defined?(:people_url)).to be(true)
      end

      it "keeps <name>_path and <name>_url out of a controller's action methods" do
        routes = route_set
        # Like ApplicationController: an abstract base class whose public
        # methods (url_for, ...) are not actions, bound to the route set.
        base_controller_class = Class.new(AbstractController::Base) do
          abstract!
          include AbstractController::UrlFor
        end
        base_controller_class.define_singleton_method(:_routes) { routes }
        controller_class = Class.new(base_controller_class) do
          include routes.url_helpers

          def index
          end
        end

        expect(controller_class.action_methods.to_a).to eq(["index"])
      end

      it "removes <name>_path and <name>_url when the collection is cleared" do
        named_routes.clear!

        expect(named_routes.path_helpers_module.method_defined?(:people_path)).to be(false)
        expect(named_routes.url_helpers_module.method_defined?(:people_url)).to be(false)
        expect(named_routes.helper_names).to be_empty
      end
    end

    # A localized route drawn without a name (no as:, as: nil, as: false)
    # has no generic helper: no junk "_path" or "false_path" method.
    [nil, "", false].each do |name|
      it "defines no helper when the route name is #{name.inspect}" do
        defined_helpers = lambda do
          [
            named_routes.path_helpers_module.instance_methods.sort,
            named_routes.url_helpers_module.instance_methods.sort,
            named_routes.helper_names.sort
          ]
        end

        expect { described_class.add(name, named_routes) }.not_to change(&defined_helpers)
      end
    end
  end

  describe "the <name>_path helper" do
    before do
      draw_localized_variants
      described_class.add(:people, named_routes)
      described_class.add(:person, named_routes)
    end

    {
      "fr-FR": "/personnes",
      "fr-CH": "/fr-ch/gens",
      "de-CH": "/de-ch/leute",
      "sr-Latn-RS": "/sr-latn-rs/ljudi"
    }.each do |locale, expected_path|
      it "dispatches to the #{locale} route when I18n.locale is #{locale}" do
        I18n.with_locale(locale) do
          expect(helpers.people_path).to eq(expected_path)
        end
      end
    end

    it "reads I18n.locale at call time rather than when the helper is defined" do
      fr_path = I18n.with_locale(:"fr-FR") { helpers.people_path }
      de_path = I18n.with_locale(:"de-CH") { helpers.people_path }

      expect([fr_path, de_path]).to eq(["/personnes", "/de-ch/leute"])
    end

    it "uses an explicit locale: String option over I18n.locale" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_path(locale: "de-CH")).to eq("/de-ch/leute")
      end
    end

    it "uses an explicit locale: Symbol option over I18n.locale" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_path(locale: :"fr-CH")).to eq("/fr-ch/gens")
      end
    end

    it "falls back to I18n.locale when the locale option is nil" do
      I18n.with_locale(:"fr-CH") do
        expect(helpers.people_path(locale: nil)).to eq("/fr-ch/gens")
      end
    end

    it "forwards positional route params" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.person_path(42)).to eq("/personnes/42")
      end
    end

    it "forwards route params given as a Hash" do
      I18n.with_locale(:"fr-CH") do
        expect(helpers.person_path(id: 7)).to eq("/fr-ch/gens/7")
      end
    end

    it "reads the explicit locale from the same Hash as the route params" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.person_path(id: 7, locale: "fr-CH")).to eq("/fr-ch/gens/7")
      end
    end

    it "forwards positional route params together with an explicit locale" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.person_path(42, locale: :"fr-CH")).to eq("/fr-ch/gens/42")
      end
    end

    it "forwards the format option" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.person_path(42, format: :json)).to eq("/personnes/42.json")
      end
    end

    it "forwards extra params as a query string" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_path(page: 2)).to eq("/personnes?page=2")
      end
    end

    # The helper deliberately dispatches to the exact locale (no fallback to
    # another locale's route): a missing variant surfaces as NoMethodError
    # naming the localized helper that does not exist.
    it "raises NoMethodError naming the missing helper when I18n.locale has no route" do
      I18n.with_locale(:en) do
        expect { helpers.people_path }.to raise_error(NoMethodError, /people_en_path/)
      end
    end

    it "raises NoMethodError naming the missing helper when the explicit locale has no route" do
      I18n.with_locale(:"fr-FR") do
        expect { helpers.person_path(1, locale: "de-CH") }
          .to raise_error(NoMethodError, /person_de_ch_path/)
      end
    end
  end

  describe "the <name>_url helper" do
    before do
      draw_localized_variants
      described_class.add(:people, named_routes)
      described_class.add(:person, named_routes)
    end

    it "dispatches to the route of I18n.locale" do
      I18n.with_locale(:"fr-CH") do
        expect(helpers.people_url).to eq("http://www.example.test/fr-ch/gens")
      end
    end

    it "uses an explicit locale option over I18n.locale" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_url(locale: :"de-CH")).to eq("http://www.example.test/de-ch/leute")
      end
    end

    it "forwards positional route params" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.person_url(42)).to eq("http://www.example.test/personnes/42")
      end
    end

    it "forwards url options such as host and protocol" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_url(locale: "fr-CH", host: "x.ch", protocol: "https"))
          .to eq("https://x.ch/fr-ch/gens")
      end
    end

    it "raises NoMethodError naming the missing helper when the locale has no route" do
      I18n.with_locale(:"de-CH") do
        expect { helpers.person_url(1) }.to raise_error(NoMethodError, /person_de_ch_url/)
      end
    end
  end

  context "when localized routes are drawn" do
    before do
      ActionDispatch::I18nRouting.config.available_locales_per_host = {
        "x.fr" => [:"fr-FR"],
        "x.ch" => [:"de-CH", :"fr-CH"]
      }
      I18n.backend.store_translations(:"fr-FR", routes: {people: "personnes"})
      I18n.backend.store_translations(:"fr-CH", routes: {people: "gens"})
      I18n.backend.store_translations(:"de-CH", routes: {people: "leute"})

      route_set.draw do
        localized { get "people", to: "people#index", as: :people }
      end
    end

    it "defines dispatching path helpers for the route name" do
      paths = %i[fr-FR fr-CH de-CH].map { |locale| I18n.with_locale(locale) { helpers.people_path } }

      expect(paths).to eq(["/personnes", "/fr-ch/gens", "/de-ch/leute"])
    end

    it "defines dispatching url helpers that point at the host serving the locale" do
      urls = %i[fr-FR fr-CH de-CH].map { |locale| I18n.with_locale(locale) { helpers.people_url } }

      expect(urls).to eq(["http://x.fr/personnes", "http://x.ch/fr-ch/gens", "http://x.ch/de-ch/leute"])
    end

    it "lets an explicit locale option pick another host's route" do
      I18n.with_locale(:"fr-FR") do
        expect(helpers.people_url(locale: "fr-CH")).to eq("http://x.ch/fr-ch/gens")
      end
    end

    it "lists the dispatching helpers among the route set's helper names" do
      expect(named_routes.helper_names).to include("people_path", "people_url")
    end

    it "removes the dispatching helpers when the routes are redrawn without the localized route" do
      route_set.draw { get "other", to: "other#index", as: :other }

      expect(helpers).not_to respond_to(:people_path)
      expect(helpers).not_to respond_to(:people_url)
      expect(named_routes.route_defined?(:people_path)).to be(false)
    end

    it "defines the dispatching helpers again when the localized route is redrawn" do
      route_set.draw do
        localized { get "people", to: "people#index", as: :people }
      end

      expect(I18n.with_locale(:"de-CH") { helpers.people_path }).to eq("/de-ch/leute")
      expect(named_routes.helper_names.tally.values_at("people_path", "people_url")).to eq([1, 1])
    end
  end

  context "when localized routes are drawn for a locale made of several subtags" do
    before do
      ActionDispatch::I18nRouting.config.available_locales_per_host = {"x.rs" => [:"sr-Latn-RS"]}
      I18n.backend.store_translations(:"sr-Latn-RS", routes: {people: "ljudi"})

      route_set.draw do
        localized { get "people", to: "people#index", as: :people }
      end
    end

    it "dispatches to the route named after the whole locale" do
      I18n.with_locale(:"sr-Latn-RS") do
        expect(helpers.people_url).to eq("http://x.rs/ljudi")
      end
    end
  end

  describe "test case hooks" do
    let(:registered_hooks) { Hash.new { |hash, key| hash[key] = [] } }
    let(:test_case_hooks) { %i[action_controller_test_case action_mailer_test_case action_view_test_case] }

    before do
      allow(ActiveSupport).to receive(:on_load) do |hook_name, &block|
        registered_hooks[hook_name] << block
      end
    end

    context "when RAILS_ENV is test" do
      let(:rails_env) { "test" }

      it "registers the controller, mailer and view test case hooks, once for path and once for url helpers" do
        described_class.add(:people, named_routes)

        expect(registered_hooks.transform_values(&:size))
          .to eq(test_case_hooks.to_h { |hook_name| [hook_name, 2] })
      end

      it "registers hooks that include the helpers in the loaded test case class" do
        draw_localized_variants
        described_class.add(:people, named_routes)

        test_case_hooks.each do |hook_name|
          test_case_class = Class.new
          registered_hooks[hook_name].each { |hook| test_case_class.class_eval(&hook) }

          expect(test_case_class.new).to respond_to(:people_path, :people_url)
        end
      end

      it "still defines the helpers" do
        described_class.add(:people, named_routes)

        expect(helpers).to respond_to(:people_path, :people_url)
      end

      it "does not register any test case hook for an unnamed route" do
        described_class.add(nil, named_routes)

        expect(ActiveSupport).not_to have_received(:on_load)
      end
    end

    ["development", "production", nil].each do |env|
      context "when RAILS_ENV is #{env.inspect}" do
        let(:rails_env) { env }

        it "does not register any test case hook" do
          described_class.add(:people, named_routes)

          expect(ActiveSupport).not_to have_received(:on_load)
        end
      end
    end
  end
end
