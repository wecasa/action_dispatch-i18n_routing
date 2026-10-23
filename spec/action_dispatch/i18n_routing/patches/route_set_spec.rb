# frozen_string_literal: true

require "stringio"

RSpec.describe ActionDispatch::I18nRouting::Patches::RouteSet do
  subject(:route_set) { ActionDispatch::Routing::RouteSet.new }

  let(:locales_per_host) { {"x.fr" => [:"fr-FR"], "x.ch" => [:"de-CH", :"fr-CH"]} }
  let(:translations) do
    {
      "fr-FR": {people: "personnes"},
      "fr-CH": {people: "gens"},
      "de-CH": {people: "leute"}
    }
  end
  # Rack endpoint used by routes that must be recognized: unlike "people#index"
  # it does not need a controller class to be dispatched.
  let(:endpoint) { ->(_env) { [200, {}, []] } }

  before do
    ActionDispatch::I18nRouting.config.available_locales_per_host = locales_per_host
    # Declaring the locales explicitly also drops the set of available locales
    # I18n memoizes, which may be stale (computed before this example stored
    # its translations).
    I18n.available_locales = locales_per_host.values.flatten | translations.keys
    translations.each { |locale, routes| I18n.backend.store_translations(locale, routes: routes) }
  end

  # Draws the given routes inside a `localized` block. The block is evaluated
  # by the route mapper and receives the Rack endpoint as argument.
  def draw_localized(&routes)
    app = endpoint
    route_set.draw { localized { instance_exec(app, &routes) } }
  end

  def route_names
    route_set.routes.map(&:name)
  end

  def path_specs
    route_set.routes.map { |route| route.path.spec.to_s }
  end

  def named_route(name)
    route_set.named_routes[name]
  end

  def path_spec(name)
    named_route(name).path.spec.to_s
  end

  # The Rack env is built by hand because Rack::MockRequest needs cgi/cookie,
  # which recent Rubies dropped.
  def rack_env(url, method)
    uri = URI(url)
    {
      "REQUEST_METHOD" => method,
      "SCRIPT_NAME" => "",
      "PATH_INFO" => uri.path,
      "QUERY_STRING" => uri.query.to_s,
      "SERVER_NAME" => uri.host,
      "SERVER_PORT" => uri.port.to_s,
      "HTTP_HOST" => uri.host,
      "rack.url_scheme" => uri.scheme,
      "rack.input" => StringIO.new
    }
  end

  # Sends a request through the route set and returns the recognized path
  # parameters, or nil when no route matched.
  def recognize(url, method: "GET")
    env = rack_env(url, method)
    status, = route_set.call(env)
    ActionDispatch::Request.new(env).path_parameters if status == 200
  end

  def url_helpers
    # Rails' named route helpers compare their last argument with
    # ActionController::Parameters, which a Rails app always loads but this
    # gem does not require.
    stub_const("ActionController::Parameters", Class.new) unless defined?(ActionController::Parameters)
    Class.new.include(route_set.url_helpers).new
  end

  describe "#add_localized_route" do
    context "with a single-locale host and a multi-locale host" do
      before { draw_localized { get "people", to: "people#index", as: :people } }

      it "adds one route per host and per locale of that host" do
        expect(route_names).to contain_exactly("people_fr_fr", "people_fr_ch", "people_de_ch")
      end

      it "adds the routes host by host, the default locale of a host last" do
        expect(route_names).to eq(%w[people_fr_fr people_fr_ch people_de_ch])
      end

      it "suffixes the route name with the underscored locale" do
        expect(route_set.named_routes.names).to contain_exactly(:people_fr_fr, :people_fr_ch, :people_de_ch)
      end

      it "translates the path for each locale" do
        expect(path_spec(:people_fr_fr)).to eq("/personnes(.:format)")
        expect(path_spec(:people_de_ch)).to eq("/de-ch/leute(.:format)")
      end

      it "prefixes the path with the downcased locale only on hosts serving several locales" do
        expect(path_specs).to eq(["/personnes(.:format)", "/fr-ch/gens(.:format)", "/de-ch/leute(.:format)"])
      end

      it "constrains each route to its host" do
        expect(named_route(:people_fr_fr).constraints).to eq(host: "x.fr")
        expect(named_route(:people_fr_ch).constraints).to eq(host: "x.ch")
        expect(named_route(:people_de_ch).constraints).to eq(host: "x.ch")
      end

      it "defaults the locale param to the route locale, as a string" do
        expect(route_set.routes.map { |route| route.defaults[:locale] }).to eq(%w[fr-FR fr-CH de-CH])
      end

      it "keeps the controller and action of the route" do
        expect(named_route(:people_de_ch).defaults).to include(controller: "people", action: "index")
      end

      it "registers people_path and people_url helpers dispatching to the localized routes" do
        helpers = url_helpers

        expect(helpers.people_path(locale: "fr-CH")).to eq("/fr-ch/gens")
        expect(helpers.people_url(locale: :"fr-FR")).to eq("http://x.fr/personnes")
      end

      it "makes people_path follow I18n.locale when no locale is given" do
        helpers = url_helpers
        I18n.locale = :"de-CH"

        expect(helpers.people_path).to eq("/de-ch/leute")
      end

      it "generates absolute urls on the host of each localized route" do
        helpers = url_helpers

        expect(helpers.people_fr_fr_url).to eq("http://x.fr/personnes")
        expect(helpers.people_de_ch_url).to eq("http://x.ch/de-ch/leute")
      end
    end

    context "with a host serving three locales" do
      let(:locales_per_host) { {"x.ch" => [:"de-CH", :"fr-CH", :"it-CH"]} }
      let(:translations) { {} }

      it "keeps the configured order of the other locales and adds the default one last" do
        draw_localized { get "people", to: "people#index", as: :people }

        expect(route_names).to eq(%w[people_fr_ch people_it_ch people_de_ch])
      end
    end

    context "when recognizing requests" do
      before do
        draw_localized do |app|
          get "people", to: app, as: :people
          get "people/:id", to: app, as: :person
        end
      end

      it "recognizes the translated path on its host with the route locale" do
        expect(recognize("http://x.fr/personnes")).to include(locale: "fr-FR")
        expect(recognize("http://x.ch/fr-ch/gens")).to include(locale: "fr-CH")
        expect(recognize("http://x.ch/de-ch/leute")).to include(locale: "de-CH")
      end

      it "extracts dynamic segments and the format" do
        expect(recognize("http://x.ch/fr-ch/gens/12.json")).to include(locale: "fr-CH", id: "12", format: "json")
      end

      it "does not recognize a translated path on another host" do
        expect(recognize("http://x.ch/personnes")).to be_nil
        expect(recognize("http://x.fr/fr-ch/gens")).to be_nil
      end

      it "does not recognize the untranslated path" do
        expect(recognize("http://x.fr/people")).to be_nil
      end

      it "does not recognize a path of a multi-locale host without its locale prefix" do
        expect(recognize("http://x.ch/gens")).to be_nil
      end

      it "does not recognize a translation under the prefix of another locale" do
        expect(recognize("http://x.ch/fr-ch/leute")).to be_nil
      end
    end

    describe "path translation" do
      it "translates each static segment and leaves dynamic segments untouched" do
        I18n.backend.store_translations(:"fr-FR", routes: {edit: "modifier"})

        draw_localized { get "people/:id/edit", to: "people#edit", as: :edit_person }

        expect(path_spec(:edit_person_fr_fr)).to eq("/personnes/:id/modifier(.:format)")
      end

      it "keeps segments that have no translation for the locale" do
        I18n.backend.store_translations(:"fr-FR", routes: {edit: "modifier"})

        draw_localized { get "people/:id/edit", to: "people#edit", as: :edit_person }

        expect(path_spec(:edit_person_fr_ch)).to eq("/fr-ch/gens/:id/edit(.:format)")
      end

      it "prefers translations scoped to the route controller over global ones" do
        I18n.backend.store_translations(:"fr-FR", routes: {show: "montrer", controllers: {people: {show: "voir"}}})

        draw_localized do
          get "people/:id/show", to: "people#show", as: :person
          get "articles/:id/show", to: "articles#show", as: :article
        end

        expect(path_spec(:person_fr_fr)).to eq("/personnes/:id/voir(.:format)")
        expect(path_spec(:article_fr_fr)).to eq("/articles/:id/montrer(.:format)")
      end

      it "translates each dot-separated part of a segment" do
        I18n.backend.store_translations(:"fr-FR", routes: {sitemap: "plan-du-site"})

        draw_localized { get "sitemap.xml.gz", to: "sitemaps#show", as: :sitemap }

        expect(path_spec(:sitemap_fr_fr)).to eq("/plan-du-site.xml.gz(.:format)")
        expect(path_spec(:sitemap_de_ch)).to eq("/de-ch/sitemap.xml.gz(.:format)")
      end

      it "leaves a format segment in the middle of the path in place" do
        I18n.backend.store_translations(:"fr-CH", routes: {download: "telecharger"})

        draw_localized { |app| get "people/:name.:format/download", to: app, as: :file, format: false }

        expect(path_spec(:file_fr_ch)).to eq("/fr-ch/gens/:name.:format/telecharger")
        expect(recognize("http://x.ch/fr-ch/gens/report.pdf/telecharger")).to include(name: "report", format: "pdf")
      end

      it "never translates the format segment" do
        I18n.backend.store_translations(:"fr-FR", routes: {format: "formatte"})

        draw_localized { get "people", to: "people#index", as: :people }

        expect(path_spec(:people_fr_fr)).to eq("/personnes(.:format)")
      end

      it "URI-escapes translations" do
        I18n.backend.store_translations(:"fr-FR", routes: {summer: "été"})

        draw_localized { |app| get "summer", to: app, as: :summer }

        expect(path_spec(:summer_fr_fr)).to eq("/%C3%A9t%C3%A9(.:format)")
        expect(recognize("http://x.fr/%C3%A9t%C3%A9")).to include(locale: "fr-FR")
      end

      it "keeps optional segments" do
        draw_localized { get "people(/:page)", to: "people#index", as: :people }

        expect(path_spec(:people_fr_fr)).to eq("/personnes(/:page)(.:format)")
        expect(path_spec(:people_fr_ch)).to eq("/fr-ch/gens(/:page)(.:format)")
      end

      it "keeps glob segments" do
        draw_localized { get "people/*path", to: "people#index", as: :people }

        expect(path_spec(:people_de_ch)).to eq("/de-ch/leute/*path(.:format)")
      end

      it "translates segments coming from a surrounding scope" do
        I18n.backend.store_translations(:"fr-FR", routes: {admin: "administration"})

        draw_localized do
          scope "admin" do
            get "people", to: "people#index", as: :admin_people
          end
        end

        expect(path_spec(:admin_people_fr_fr)).to eq("/administration/personnes(.:format)")
        expect(path_spec(:admin_people_de_ch)).to eq("/de-ch/admin/leute(.:format)")
      end

      it "puts the locale prefix before an optional segment of a surrounding scope" do
        draw_localized do |app|
          scope("(:region)") { get "people", to: app, as: :people }
        end

        expect(path_spec(:people_de_ch)).to eq("/de-ch(/:region)/leute(.:format)")
        expect(recognize("http://x.ch/de-ch/leute")).to include(locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/zurich/leute")).to include(locale: "de-CH", region: "zurich")
        expect(recognize("http://x.fr/paris/personnes")).to include(locale: "fr-FR", region: "paris")
        expect(url_helpers.people_path(locale: "fr-CH", region: "geneve")).to eq("/fr-ch/geneve/gens")
      end

      it "maps the root path to / or to the bare locale prefix" do
        draw_localized { |app| get "/", to: app, as: :root }

        expect(path_specs).to eq(["/", "/fr-ch", "/de-ch"])
        expect(recognize("http://x.fr/")).to include(locale: "fr-FR")
        expect(recognize("http://x.ch/de-ch")).to include(locale: "de-CH")
      end

      it "moves the slash of a root optional segment into it after the locale prefix" do
        draw_localized { |app| get "(/:page)", to: app, as: :home }

        expect(path_specs).to eq(["/(:page)(.:format)", "/fr-ch(/:page)(.:format)", "/de-ch(/:page)(.:format)"])
      end

      it "recognizes the bare locale prefix of a root path made of an optional segment" do
        draw_localized { |app| get "(/:page)", to: app, as: :home }

        expect(recognize("http://x.ch/de-ch")).to include(locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/")).to include(locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/2")).to include(locale: "de-CH", page: "2")
        expect(recognize("http://x.fr/")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/2")).to include(locale: "fr-FR", page: "2")
        expect(url_helpers.home_path(locale: "fr-CH")).to eq("/fr-ch")
        expect(url_helpers.home_path(locale: "fr-CH", page: 2)).to eq("/fr-ch/2")
      end

      it "moves the slash of a root optional segment written without it, or coming from a scope" do
        draw_localized do |app|
          get "(:page)", to: app, as: :home
          scope("(:region)") { get "/", to: app, as: :region }
        end

        expect(path_spec(:home_de_ch)).to eq("/de-ch(/:page)(.:format)")
        expect(path_spec(:region_de_ch)).to eq("/de-ch(/:region)(.:format)")
        expect(path_spec(:region_fr_fr)).to eq("/(:region)(.:format)")
        expect(recognize("http://x.ch/de-ch")).to include(locale: "de-CH")
      end

      it "appends the required format of a root path to the bare locale prefix" do
        draw_localized { |app| get "/", to: app, as: :feed, format: true }

        expect(path_specs).to eq(["/.:format", "/fr-ch.:format", "/de-ch.:format"])
        expect(recognize("http://x.ch/de-ch.json")).to include(locale: "de-CH", format: "json")
      end

      it "appends the optional format of a root path to the bare locale prefix" do
        draw_localized { |app| get "(.:format)", to: app, as: :home }

        expect(path_specs).to eq(["/(.:format)", "/fr-ch(.:format)", "/de-ch(.:format)"])
        expect(recognize("http://x.ch/de-ch")).to include(locale: "de-CH")
        expect(recognize("http://x.ch/de-ch.json")).to include(locale: "de-CH", format: "json")
      end

      it "omits the format segment with `format: false`" do
        draw_localized { |app| get "people", to: app, as: :people, format: false }

        expect(path_spec(:people_fr_ch)).to eq("/fr-ch/gens")
        expect(recognize("http://x.fr/personnes")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/personnes.json")).to be_nil
      end

      it "requires the format segment with `format: true`" do
        draw_localized { |app| get "people", to: app, as: :people, format: true }

        expect(path_spec(:people_fr_ch)).to eq("/fr-ch/gens.:format")
        expect(recognize("http://x.fr/personnes.json")).to include(format: "json")
        expect(recognize("http://x.fr/personnes")).to be_nil
      end

      it "defaults and restricts the format with `format: \"json\"`" do
        draw_localized { |app| get "people", to: app, as: :people, format: "json" }

        expect(recognize("http://x.ch/de-ch/leute")).to include(format: "json", locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/leute.json")).to include(format: "json", locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/leute.xml")).to be_nil
      end
    end

    context "with a mounted Rack application" do
      let(:mounted_requests) { [] }
      let(:endpoint) do
        lambda do |env|
          mounted_requests << env.values_at("SCRIPT_NAME", "PATH_INFO")
          [200, {}, []]
        end
      end

      before { draw_localized { |app| mount app, at: "people", as: :people_app } }

      it "mounts the application under the translated path of each locale" do
        expect(path_specs).to eq(["/personnes", "/fr-ch/gens", "/de-ch/leute"])
      end

      it "dispatches the requests under the translated path to the application" do
        expect(recognize("http://x.ch/fr-ch/gens/foo/bar")).to include(locale: "fr-CH")
        expect(recognize("http://x.fr/personnes/baz")).to include(locale: "fr-FR")
        expect(mounted_requests).to eq([["/fr-ch/gens", "/foo/bar"], ["/personnes", "/baz"]])
      end
    end

    context "with a redirect" do
      before do
        draw_localized { get "people", to: redirect { |params, _request| "/#{params[:locale].downcase}/team" } }
      end

      it "redirects from the translated path of every locale, giving the redirect the route locale" do
        responses = ["http://x.fr/personnes", "http://x.ch/de-ch/leute"].map do |url|
          status, headers, = route_set.call(rack_env(url, "GET"))
          [status, headers["location"]]
        end

        expect(responses).to eq([[301, "http://x.fr/fr-fr/team"], [301, "http://x.ch/de-ch/team"]])
      end
    end

    context "with a route without controller" do
      # A controller sharing its name with a path segment has a subtree of
      # translations under that key.
      before { I18n.backend.store_translations(:"fr-FR", routes: {controllers: {people: {edit: "modifier"}}}) }

      it "translates its path with the global translations" do
        draw_localized do |app|
          get "people", to: app, as: :people
          get "people/old", to: redirect("/people"), as: :old_people
        end

        expect(path_spec(:people_fr_fr)).to eq("/personnes(.:format)")
        expect(path_spec(:old_people_fr_fr)).to eq("/personnes/old(.:format)")
      end

      it "looks its translations up under :routes only, not under a controller" do
        allow(ActionDispatch::I18nRouting::Translator::PathSegment).to receive(:translate).and_call_original

        draw_localized { |app| get "people", to: app, as: :people }

        expect(ActionDispatch::I18nRouting::Translator::PathSegment)
          .to have_received(:translate).with("people", anything, [:routes]).exactly(3).times
      end
    end

    describe "constraints, defaults and options" do
      it "applies segment constraints given in the route options" do
        draw_localized { |app| get "people/:id", to: app, as: :person, constraints: {id: /\d+/} }

        expect(recognize("http://x.ch/fr-ch/gens/12")).to include(id: "12", locale: "fr-CH")
        expect(recognize("http://x.ch/fr-ch/gens/abc")).to be_nil
      end

      it "keeps request constraints given in the route options next to the host" do
        draw_localized { get "people", to: "people#index", as: :people, constraints: {subdomain: "www"} }

        expect(named_route(:people_fr_fr).constraints).to eq(subdomain: "www", host: "x.fr")
      end

      it "applies a lambda given as route constraints, next to the host and locale" do
        draw_localized do |app|
          get "people", to: app, as: :people, constraints: ->(request) { request.query_string == "allowed" }
        end

        expect(recognize("http://x.fr/personnes?allowed")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/personnes")).to be_nil
        expect(recognize("http://x.fr/fr-ch/gens?allowed")).to be_nil
        expect(named_route(:people_fr_ch).constraints).to eq(host: "x.ch")
        expect(url_helpers.people_url(locale: "fr-CH")).to eq("http://x.ch/fr-ch/gens")
      end

      it "applies an object responding to matches? given as route constraints" do
        constraint = Object.new
        def constraint.matches?(request) = request.query_string == "allowed"

        draw_localized { |app| get "people", to: app, as: :people, constraints: constraint }

        expect(recognize("http://x.ch/de-ch/leute?allowed")).to include(locale: "de-CH")
        expect(recognize("http://x.ch/de-ch/leute")).to be_nil
      end

      it "lets a callable given as route constraints replace the constraint blocks of a surrounding scope, like Rails" do
        draw_localized do |app|
          constraints(->(request) { request.query_string.include?("scope") }) do
            get "people", to: app, as: :people, constraints: ->(request) { request.query_string.include?("route") }
          end
        end

        expect(recognize("http://x.fr/personnes?route")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/personnes?scope")).to be_nil
      end

      it "applies defaults given in the route options" do
        draw_localized { |app| get "people", to: app, as: :people, defaults: {format: "json"} }

        expect(recognize("http://x.fr/personnes")).to include(format: "json", locale: "fr-FR")
      end

      it "keeps a locale given in the route options instead of the route locale" do
        draw_localized { get "people", to: "people#index", as: :people, locale: "custom" }

        expect(route_set.routes.map { |route| route.defaults[:locale] }).to all(eq("custom"))
      end

      it "keeps the HTTP verbs of the route" do
        draw_localized { |app| match "people", to: app, as: :people, via: %i[get post] }

        expect(recognize("http://x.fr/personnes", method: "POST")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/personnes", method: "DELETE")).to be_nil
      end

      it "merges the constraints of a surrounding scope" do
        draw_localized do
          constraints(subdomain: "api") { get "people", to: "people#index", as: :people }
        end

        expect(named_route(:people_de_ch).constraints).to eq(subdomain: "api", host: "x.ch")
      end

      it "merges the defaults of a surrounding scope" do
        draw_localized do |app|
          defaults(foo: "bar") { get "people", to: app, as: :people }
        end

        expect(recognize("http://x.ch/de-ch/leute")).to include(foo: "bar", locale: "de-CH")
      end

      it "merges the options of a surrounding scope" do
        draw_localized do |app|
          scope(foo: "bar") { get "people", to: app, as: :people }
        end

        expect(recognize("http://x.fr/personnes")).to include(foo: "bar", locale: "fr-FR")
      end

      it "applies the constraint blocks of a surrounding scope" do
        draw_localized do |app|
          constraints(->(request) { request.query_string == "allowed" }) do
            get "people", to: app, as: :people
          end
        end

        expect(recognize("http://x.fr/personnes?allowed")).to include(locale: "fr-FR")
        expect(recognize("http://x.fr/personnes")).to be_nil
      end

      it "prefixes the controller with the module of a surrounding scope" do
        draw_localized do
          scope(module: "admin") { get "people", to: "people#index", as: :people }
        end

        expect(named_route(:people_fr_fr).defaults).to include(controller: "admin/people")
      end

      it "takes the controller and the action from a surrounding controller scope" do
        I18n.backend.store_translations(:"fr-FR", routes: {controllers: {people: {list: "liste"}}})

        draw_localized do
          controller(:people) { get "list", as: :people_list }
        end

        expect(named_route(:people_list_fr_fr).defaults).to include(controller: "people", action: "list")
        expect(path_spec(:people_list_fr_fr)).to eq("/liste(.:format)")
        expect(path_spec(:people_list_de_ch)).to eq("/de-ch/list(.:format)")
      end
    end

    describe "route names" do
      it "leaves routes unnamed when their localized name is already taken" do
        draw_localized do |app|
          get "people", to: app, as: :people
          post "people", to: app
        end

        expect(route_names).to eq(%w[people_fr_fr people_fr_ch people_de_ch] + [nil, nil, nil])
        expect(recognize("http://x.ch/fr-ch/gens", method: "POST")).to include(locale: "fr-CH")
      end

      it "leaves routes unnamed with `as: nil`" do
        draw_localized { |app| get "people", to: app, as: nil }

        expect(route_names).to eq([nil, nil, nil])
        expect(recognize("http://x.fr/personnes")).to include(locale: "fr-FR")
      end

      it "leaves the routes Rails leaves unnamed in a resource unnamed" do
        draw_localized { resources :people, only: %i[index create] }

        expect(route_names).to eq(%w[people_fr_fr people_fr_ch people_de_ch] + [nil, nil, nil])
      end

      it "defines no people_path-like helper for unnamed routes" do
        draw_localized do |app|
          get "people/:id", to: app
          get "people", to: app, as: nil
          get "others", to: app, as: false
        end

        expect(route_set.named_routes.path_helpers_module.instance_methods).to be_empty
        expect(route_set.named_routes.url_helpers_module.instance_methods).to be_empty
      end

      it "raises like Rails when an explicit name is already in use" do
        expect do
          draw_localized do |app|
            get "people", to: app, as: :people
            get "others", to: app, as: :people
          end
        end.to raise_error(ArgumentError, /\AInvalid route name, already in use: 'people_fr_fr'/)
      end

      it "raises like Rails when an explicit name is in use by a route drawn outside `localized`" do
        app = endpoint

        expect do
          route_set.draw do
            get "team", to: app, as: :people_de_ch
            localized { get "people", to: app, as: :people }
          end
        end.to raise_error(ArgumentError, /\AInvalid route name, already in use: 'people_de_ch'/)
      end

      # The mapper tells whether the name comes from an `as:` option; here
      # every name is declared explicit, whatever the mapper finds.
      context "when the name is declared explicit" do
        before do
          allow(route_set).to receive(:add_localized_route).and_wrap_original do |method, *args, **options|
            method.call(*args, **options.merge(explicit_name: true))
          end
        end

        it "raises the error Rails raises for a name already in use" do
          expect do
            draw_localized do |app|
              get "people", to: app, as: :people
              post "people", to: app
            end
          end.to raise_error(ArgumentError, /\AInvalid route name, already in use: 'people_fr_fr'/)
        end

        it "adds the routes when their name is free" do
          draw_localized { |app| get "people", to: app, as: :people }

          expect(route_names).to eq(%w[people_fr_fr people_fr_ch people_de_ch])
        end
      end

      context "when hosts share a locale" do
        let(:locales_per_host) { {"a.fr" => [:fr], "b.ch" => [:de, :fr]} }
        let(:translations) { {fr: {people: "gens"}, de: {people: "leute"}} }

        def draw_people
          draw_localized { |app| get "people", to: app, as: :people }
        end

        it "raises an error naming the shared locale and its hosts" do
          expect { draw_people }.to raise_error(
            ActionDispatch::I18nRouting::Error,
            "Locale :fr is configured for several hosts (a.fr, b.ch); each locale must belong to a single host, " \
            'use region-specific locales such as :"fr-FR" and :"fr-CH"'
          )
        end

        it "adds no route nor helper" do
          expect { draw_people }.to raise_error(ActionDispatch::I18nRouting::Error)

          expect(route_set.routes).to be_empty
          expect(route_set.named_routes.path_helpers_module.instance_methods).to be_empty
        end

        context "with several shared locales" do
          let(:locales_per_host) { {"a.fr" => [:fr, :de], "b.ch" => [:de, :fr], "c.it" => [:it]} }

          it "names every shared locale and the hosts sharing them" do
            expect { draw_people }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              /\ALocales :fr, :de are configured for several hosts \(a\.fr, b\.ch\);/
            )
          end
        end

        # The routes below get implicit names: a second route for the locale
        # would silently be left unnamed, no ArgumentError would reveal it.
        context "when the hosts sharing it are not the first two" do
          let(:locales_per_host) { {"a.fr" => [:fr], "b.de" => [:de], "c.ch" => [:it, :fr]} }

          it "raises an error naming them" do
            expect { draw_localized { resources :people, only: :index } }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              /\ALocale :fr is configured for several hosts \(a\.fr, c\.ch\);/
            )
          end
        end

        context "when it is a Symbol for a host and a String for another" do
          let(:locales_per_host) { {"a.fr" => [:fr], "b.ch" => [:de, "fr"]} }

          it "raises an error naming it once" do
            expect { draw_localized { resources :people, only: :index } }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              /\ALocale :fr is configured for several hosts \(a\.fr, b\.ch\);/
            )
          end
        end

        # The route names, and so the hosts' routes, only differ by the
        # underscored locale: people_fr_fr for all these spellings.
        context "when it is spelled with another case or an underscore" do
          let(:locales_per_host) { {"a.fr" => [:"fr-FR"], "b.be" => [:fr_FR], "c.lu" => [:"fr-fr"]} }
          let(:translations) { {} }

          it "raises an error naming every spelling" do
            expect { draw_localized { resources :people, only: :index } }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              /\ALocale :"fr-FR" \/ :fr_FR \/ :"fr-fr" is configured for several hosts \(a\.fr, b\.be, c\.lu\);/
            )
          end
        end
      end

      context "when a host lists a locale more than once" do
        let(:locales_per_host) { {"a.fr" => [:"fr-FR"], "b.ch" => [:"de-CH", :"fr-CH", :"de-CH"]} }

        it "raises an error naming the locale and the host, for implicit and explicit names" do
          message = 'Locale :"de-CH" is listed more than once for host b.ch'

          expect { draw_localized { resources :people, only: :index } }
            .to raise_error(ActionDispatch::I18nRouting::Error, message)
          expect { draw_localized { |app| root to: app } }
            .to raise_error(ActionDispatch::I18nRouting::Error, message)
          expect(route_set.routes).to be_empty
        end

        context "when another host lists it too" do
          let(:locales_per_host) { {"a.ch" => [:"de-CH"], "b.ch" => [:"fr-CH", :"de-CH", :"de-CH"]} }

          it "names the host listing it more than once" do
            expect { draw_localized { resources :people, only: :index } }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              'Locale :"de-CH" is listed more than once for host b.ch'
            )
          end
        end

        context "with another spelling" do
          let(:locales_per_host) { {"b.ch" => [:"de-CH", :"fr-CH", :de_ch]} }
          let(:translations) { {} }

          it "raises an error naming every spelling" do
            expect { draw_localized { resources :people, only: :index } }.to raise_error(
              ActionDispatch::I18nRouting::Error,
              'Locale :"de-CH" / :de_ch is listed more than once for host b.ch'
            )
          end
        end
      end
    end

    context "when no host is configured" do
      let(:locales_per_host) { {} }

      it "adds no route" do
        draw_localized { get "people", to: "people#index", as: :people }

        expect(route_set.routes).to be_empty
      end
    end
  end

  describe "private helpers" do
    describe "#translate_name" do
      it "suffixes the name with the underscored locale" do
        expect(route_set.send(:translate_name, :people, :"de-CH", [])).to eq("people_de_ch")
        expect(route_set.send(:translate_name, "people", :fr, [])).to eq("people_fr")
      end

      it "returns nil for a blank name" do
        expect(route_set.send(:translate_name, nil, :"de-CH", [])).to be_nil
        expect(route_set.send(:translate_name, "", :"de-CH", [])).to be_nil
      end

      it "returns nil when the localized name is already taken" do
        expect(route_set.send(:translate_name, :people, :"de-CH", [:people_de_ch])).to be_nil
      end

      it "ignores names taken for other locales" do
        expect(route_set.send(:translate_name, :people, :"de-CH", [:people_fr_ch])).to eq("people_de_ch")
      end

      it "returns a taken localized name when the name is explicit" do
        expect(route_set.send(:translate_name, :people, :"de-CH", [:people_de_ch], explicit_name: true)).to eq("people_de_ch")
      end

      it "returns nil for a blank explicit name" do
        expect(route_set.send(:translate_name, nil, :"de-CH", [], explicit_name: true)).to be_nil
      end
    end

    describe "#translate_options" do
      it "adds the locale as a string" do
        expect(route_set.send(:translate_options, {as: :people}, :"fr-CH")).to eq(as: :people, locale: "fr-CH")
      end

      it "keeps an existing locale" do
        expect(route_set.send(:translate_options, {locale: "custom"}, :"fr-CH")).to eq(locale: "custom")
      end

      it "accepts nil options" do
        expect(route_set.send(:translate_options, nil, :"fr-CH")).to eq(locale: "fr-CH")
      end

      it "does not modify the given options" do
        options = {as: :people}.freeze

        route_set.send(:translate_options, options, :"fr-CH")

        expect(options).to eq(as: :people)
      end
    end

    describe "#translate_options_constraints" do
      it "adds the locale and the host to the given constraints" do
        constraints = route_set.send(:translate_options_constraints, {id: /\d+/}, :"fr-CH", "x.ch")

        expect(constraints).to eq(id: /\d+/, locale: "fr-CH", host: "x.ch")
      end

      it "accepts nil constraints" do
        expect(route_set.send(:translate_options_constraints, nil, :"fr-CH", "x.ch")).to eq(locale: "fr-CH", host: "x.ch")
      end

      it "pins the locale and host of the localized route" do
        constraints = route_set.send(:translate_options_constraints, {locale: "it", host: "x.it"}, :"fr-CH", "x.ch")

        expect(constraints).to eq(locale: "fr-CH", host: "x.ch")
      end

      it "does not modify the given constraints" do
        constraints = {id: /\d+/}.freeze

        route_set.send(:translate_options_constraints, constraints, :"fr-CH", "x.ch")

        expect(constraints).to eq(id: /\d+/)
      end

      it "returns only the locale and the host for callable constraints" do
        constraints = route_set.send(:translate_options_constraints, ->(_request) { true }, :"fr-CH", "x.ch")

        expect(constraints).to eq(locale: "fr-CH", host: "x.ch")
      end
    end

    describe "#constraint_blocks" do
      let(:scope_block) { ->(_request) { true } }

      it "keeps the constraint blocks of the scope for Hash constraints" do
        expect(route_set.send(:constraint_blocks, [scope_block], {id: /\d+/})).to eq([scope_block])
        expect(route_set.send(:constraint_blocks, [scope_block], nil)).to eq([scope_block])
        expect(route_set.send(:constraint_blocks, nil, {})).to eq([])
      end

      it "replaces them with callable constraints" do
        constraint = ->(_request) { false }

        expect(route_set.send(:constraint_blocks, [scope_block], constraint)).to eq([constraint])
      end
    end

    describe "#translation_scope" do
      it "looks the translations of a route up under its controller" do
        expect(route_set.send(:translation_scope, "admin/people")).to eq([:routes, :controllers, "admin/people"])
      end

      it "looks the translations of a route without controller up under :routes" do
        expect(route_set.send(:translation_scope, nil)).to eq([:routes])
      end
    end

    describe "#translate_path" do
      def translate_path(path, locale, host)
        route_set.send(:translate_path, path, locale, [:routes, :controllers, "people"], host)
      end

      it "translates the path and prefixes the locale on multi-locale hosts" do
        expect(translate_path("/people(.:format)", :"fr-FR", "x.fr")).to eq("/personnes(.:format)")
        expect(translate_path("/people(.:format)", :"fr-CH", "x.ch")).to eq("/fr-ch/gens(.:format)")
      end

      it "keeps a required format suffix" do
        expect(translate_path("/people.:format", :"de-CH", "x.ch")).to eq("/de-ch/leute.:format")
      end

      it "maps the root path to / or to the bare locale prefix" do
        expect(translate_path("/", :"fr-FR", "x.fr")).to eq("/")
        expect(translate_path("/", :"de-CH", "x.ch")).to eq("/de-ch")
      end

      # "(/:region)/people(.:format)" is what the mapper builds for
      # `scope("(:region)") { get "people" }`.
      it "keeps a leading optional segment after the locale prefix, without doubling its slash" do
        expect(translate_path("(/:region)/people(.:format)", :"fr-FR", "x.fr")).to eq("(/:region)/personnes(.:format)")
        expect(translate_path("(/:region)/people(.:format)", :"de-CH", "x.ch")).to eq("/de-ch(/:region)/leute(.:format)")
      end

      # "/(:page)(.:format)" is what the mapper builds for `get "(/:page)"`.
      it "moves the slash of a root optional segment into it after the locale prefix" do
        expect(translate_path("/(:page)(.:format)", :"fr-FR", "x.fr")).to eq("/(:page)(.:format)")
        expect(translate_path("/(:page)(.:format)", :"de-CH", "x.ch")).to eq("/de-ch(/:page)(.:format)")
        expect(translate_path("/(:page)(/:sort)", :"de-CH", "x.ch")).to eq("/de-ch(/:page)(/:sort)")
      end

      it "does not modify the given path" do
        path = +"/people(.:format)"

        translate_path(path, :"fr-CH", "x.ch")

        expect(path).to eq("/people(.:format)")
      end
    end
  end
end
