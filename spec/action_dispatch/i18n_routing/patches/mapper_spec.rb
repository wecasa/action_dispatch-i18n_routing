# frozen_string_literal: true

require "stringio"
require "uri"

RSpec.describe ActionDispatch::I18nRouting::Patches::Mapper do
  let(:route_set) { ActionDispatch::Routing::RouteSet.new }
  # Named helpers are called with an explicit options hash: given anything else
  # as last argument, Rails compares it with ActionController::Parameters, which
  # is not loaded here.
  let(:url_helpers) { route_set.url_helpers }

  before do
    ActionDispatch::I18nRouting.config.available_locales_per_host = {
      "example.fr" => [:"fr-FR"],
      "example.ch" => [:"de-CH", :"fr-CH"]
    }

    I18n.backend.store_translations(:"fr-FR", routes: {people: "personnes"})
    I18n.backend.store_translations(:"fr-CH", routes: {people: "gens"})
    I18n.backend.store_translations(:"de-CH", routes: {people: "leute"})
    # I18n caches the set of available locales; declare them explicitly.
    I18n.available_locales = [:en, :"fr-FR", :"fr-CH", :"de-CH"]
  end

  def draw(&block)
    route_set.draw(&block)
  end

  def named_paths
    route_set.routes.select(&:name).to_h { |route| [route.name, route.path.spec.to_s] }
  end

  def route_table
    route_set.routes.map { |route| [route.name, route.verb, route.path.spec.to_s] }
  end

  # Rack::MockRequest cannot be loaded on this Ruby/Rack combination (it needs
  # the removed cgi/cookie library), so the Rack env is built by hand.
  def rack_env(url, method)
    uri = URI(url)
    {
      "REQUEST_METHOD" => method,
      "SERVER_NAME" => uri.host,
      "SERVER_PORT" => "80",
      "HTTP_HOST" => uri.host,
      "SCRIPT_NAME" => "",
      "PATH_INFO" => uri.path,
      "QUERY_STRING" => "",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new
    }
  end

  # Returns the recognized path parameters, or nil when no route matches.
  def recognize(url, method: "GET")
    request = ActionDispatch::Request.new(rack_env(url, method))
    route_set.recognize_path_with_request(request, request.path_info, {}, raise_on_missing: false)
  end

  # Route recognition resolves the controller constant and asks it for its
  # parameter encoding, like ActionController::Base does.
  def stub_controllers(*names)
    names.each do |name|
      stub_const(name, Class.new { def self.action_encoding_template(_action) = false })
    end
  end

  describe "routes drawn outside `localized`" do
    before { stub_controllers("PeopleController") }

    it "keeps the name, path and defaults Rails gives them" do
      draw { get "people", to: "people#index", as: :people }

      route = route_set.routes.first
      expect(route_set.routes.size).to eq(1)
      expect(route.name).to eq("people")
      expect(route.path.spec.to_s).to eq("/people(.:format)")
      expect(route.defaults).to eq(controller: "people", action: "index")
    end

    it "does not add locale or host constraints" do
      draw { get "people", to: "people#index" }

      expect(recognize("http://anything.test/people")).to eq(controller: "people", action: "index")
      expect(recognize("http://example.fr/personnes")).to be_nil
    end

    it "does not define per-locale helpers" do
      draw { get "people", to: "people#index", as: :people }

      expect(url_helpers.method_defined?(:people_path)).to be(true)
      expect(url_helpers.method_defined?(:people_fr_fr_path)).to be(false)
    end
  end

  describe "#localized" do
    before { stub_controllers("PeopleController", "PlainController") }

    it "adds one route per host and locale, suffixed with the underscored locale" do
      draw { localized { get "people", to: "people#index", as: :people } }

      expect(named_paths).to eq(
        "people_fr_fr" => "/personnes(.:format)",
        "people_fr_ch" => "/fr-ch/gens(.:format)",
        "people_de_ch" => "/de-ch/leute(.:format)"
      )
    end

    it "constrains each route to its host and sets its locale" do
      draw { localized { get "people", to: "people#index" } }

      expect(recognize("http://example.fr/personnes"))
        .to eq(host: "example.fr", locale: "fr-FR", controller: "people", action: "index")
      expect(recognize("http://example.ch/de-ch/leute"))
        .to eq(host: "example.ch", locale: "de-CH", controller: "people", action: "index")
      expect(recognize("http://example.ch/fr-ch/gens"))
        .to eq(host: "example.ch", locale: "fr-CH", controller: "people", action: "index")
    end

    it "does not recognize a locale's path on another host or without its translation" do
      draw { localized { get "people", to: "people#index" } }

      expect(recognize("http://example.ch/personnes")).to be_nil
      expect(recognize("http://example.fr/de-ch/leute")).to be_nil
      expect(recognize("http://example.fr/people")).to be_nil
    end

    it "generates translated paths and URLs through the per-locale helpers" do
      draw { localized { get "people", to: "people#index", as: :people } }

      expect(url_helpers.people_fr_fr_path({})).to eq("/personnes")
      expect(url_helpers.people_de_ch_path({})).to eq("/de-ch/leute")
      expect(url_helpers.people_fr_ch_url({})).to eq("http://example.ch/fr-ch/gens")
    end

    it "defines a locale-dispatching helper under the untranslated name" do
      draw { localized { get "people", to: "people#index", as: :people } }

      expect(url_helpers.people_path(locale: "de-CH")).to eq("/de-ch/leute")
      expect(url_helpers.people_url(locale: :"fr-FR")).to eq("http://example.fr/personnes")
    end

    it "leaves routes drawn after the block untouched" do
      draw do
        localized { get "people", to: "people#index", as: :people }
        get "plain", to: "plain#index", as: :plain
      end

      expect(named_paths).to include("plain" => "/plain(.:format)")
      expect(recognize("http://anything.test/plain")).to eq(controller: "plain", action: "index")
    end

    it "lets the exception raised inside the block propagate" do
      expect { draw { localized { raise ArgumentError, "boom" } } }.to raise_error(ArgumentError, "boom")
    end

    it "stops localizing once an exception has escaped the block" do
      boom = Class.new(StandardError)

      draw do
        begin
          localized do
            get "people", to: "people#index", as: :people
            raise boom
          end
        rescue boom
          # swallowed so the rest of the routes can be drawn
        end
        get "plain", to: "plain#index", as: :plain
      end

      expect(named_paths).to eq(
        "people_fr_fr" => "/personnes(.:format)",
        "people_fr_ch" => "/fr-ch/gens(.:format)",
        "people_de_ch" => "/de-ch/leute(.:format)",
        "plain" => "/plain(.:format)"
      )
      expect(recognize("http://anything.test/plain")).to eq(controller: "plain", action: "index")
    end

    context "when nested" do
      it "localizes the routes drawn inside the inner block" do
        draw { localized { localized { get "people", to: "people#index", as: :people } } }

        expect(named_paths.keys).to contain_exactly("people_fr_fr", "people_fr_ch", "people_de_ch")
      end

      it "stops localizing once the outermost block is closed" do
        draw do
          localized { localized { get "people", to: "people#index", as: :people } }
          get "plain", to: "plain#index", as: :plain
        end

        expect(named_paths).to include("plain" => "/plain(.:format)")
        expect(named_paths.keys).not_to include("plain_fr_fr")
      end
    end
  end

  describe "HTTP verbs" do
    before { stub_controllers("PeopleController") }

    it "localizes routes declared with every verb helper" do
      draw do
        localized do
          get "people/a", to: "people#a"
          post "people/b", to: "people#b"
          put "people/c", to: "people#c"
          patch "people/d", to: "people#d"
          delete "people/e", to: "people#e"
        end
      end

      french = route_set.routes.select { |route| route.defaults[:locale] == "fr-FR" }
      expect(french.map { |route| [route.verb, route.path.spec.to_s, route.defaults[:action]] }).to eq([
        ["GET", "/personnes/a(.:format)", "a"],
        ["POST", "/personnes/b(.:format)", "b"],
        ["PUT", "/personnes/c(.:format)", "c"],
        ["PATCH", "/personnes/d(.:format)", "d"],
        ["DELETE", "/personnes/e(.:format)", "e"]
      ])
    end

    it "only recognizes the declared verb" do
      draw { localized { post "people", to: "people#create" } }

      expect(recognize("http://example.fr/personnes", method: "POST")).to include(action: "create", locale: "fr-FR")
      expect(recognize("http://example.fr/personnes", method: "GET")).to be_nil
    end

    it "honours the verbs given to `match` with `via:`" do
      draw { localized { match "people/search", to: "people#search", via: [:get, :post] } }

      expect(route_table).to eq([
        ["people_search_fr_fr", "GET|POST", "/personnes/search(.:format)"],
        ["people_search_fr_ch", "GET|POST", "/fr-ch/gens/search(.:format)"],
        ["people_search_de_ch", "GET|POST", "/de-ch/leute/search(.:format)"]
      ])
      expect(recognize("http://example.ch/de-ch/leute/search", method: "POST")).to include(action: "search")
      expect(recognize("http://example.ch/de-ch/leute/search", method: "DELETE")).to be_nil
    end

    it "matches any verb with `via: :all`" do
      draw { localized { match "people/search", to: "people#search", via: :all } }

      %w[GET POST PUT PATCH DELETE].each do |verb|
        expect(recognize("http://example.fr/personnes/search", method: verb)).to include(action: "search")
      end
    end
  end

  describe "`resources` inside `localized`" do
    before do
      stub_controllers("PeopleController", "PhotosController")
      I18n.backend.store_translations(
        :"fr-FR",
        routes: {
          search: "recherche",
          preview: "apercu",
          controllers: {"people" => {new: "nouveau", edit: "modifier", preview: "apercu-personne"}}
        }
      )
    end

    it "names the index, new, edit and show routes per locale with translated paths" do
      draw { localized { resources :people } }

      expect(named_paths).to eq(
        "people_fr_fr" => "/personnes(.:format)",
        "people_fr_ch" => "/fr-ch/gens(.:format)",
        "people_de_ch" => "/de-ch/leute(.:format)",
        "new_person_fr_fr" => "/personnes/nouveau(.:format)",
        "new_person_fr_ch" => "/fr-ch/gens/new(.:format)",
        "new_person_de_ch" => "/de-ch/leute/new(.:format)",
        "edit_person_fr_fr" => "/personnes/:id/modifier(.:format)",
        "edit_person_fr_ch" => "/fr-ch/gens/:id/edit(.:format)",
        "edit_person_de_ch" => "/de-ch/leute/:id/edit(.:format)",
        "person_fr_fr" => "/personnes/:id(.:format)",
        "person_fr_ch" => "/fr-ch/gens/:id(.:format)",
        "person_de_ch" => "/de-ch/leute/:id(.:format)"
      )
    end

    it "routes the seven RESTful actions with their :id param" do
      draw { localized { resources :people } }

      expect([
        recognize("http://example.fr/personnes"),
        recognize("http://example.fr/personnes", method: "POST"),
        recognize("http://example.fr/personnes/nouveau"),
        recognize("http://example.fr/personnes/42"),
        recognize("http://example.fr/personnes/42/modifier"),
        recognize("http://example.fr/personnes/42", method: "PATCH"),
        recognize("http://example.fr/personnes/42", method: "PUT"),
        recognize("http://example.fr/personnes/42", method: "DELETE")
      ].map { |params| params&.slice(:action, :id) }).to eq([
        {action: "index"},
        {action: "create"},
        {action: "new"},
        {action: "show", id: "42"},
        {action: "edit", id: "42"},
        {action: "update", id: "42"},
        {action: "update", id: "42"},
        {action: "destroy", id: "42"}
      ])
    end

    it "generates member paths from the per-locale helpers" do
      draw { localized { resources :people } }

      expect(url_helpers.person_fr_fr_path(id: 42)).to eq("/personnes/42")
      expect(url_helpers.edit_person_de_ch_path(id: 42)).to eq("/de-ch/leute/42/edit")
      expect(url_helpers.person_fr_ch_url(id: 42)).to eq("http://example.ch/fr-ch/gens/42")
    end

    it "honours `only:`" do
      draw { localized { resources :people, only: [:index, :show] } }

      expect(named_paths.keys).to contain_exactly(
        "people_fr_fr", "people_fr_ch", "people_de_ch",
        "person_fr_fr", "person_fr_ch", "person_de_ch"
      )
      expect(recognize("http://example.fr/personnes", method: "POST")).to be_nil
    end

    it "translates member and collection routes, preferring controller-specific translations" do
      draw do
        localized do
          resources :people do
            member { get :preview }
            collection { get :search }
          end
        end
      end

      expect(named_paths).to include(
        "preview_person_fr_fr" => "/personnes/:id/apercu-personne(.:format)",
        "preview_person_de_ch" => "/de-ch/leute/:id/preview(.:format)",
        "search_people_fr_fr" => "/personnes/recherche(.:format)",
        "search_people_de_ch" => "/de-ch/leute/search(.:format)"
      )
      expect(recognize("http://example.fr/personnes/42/apercu-personne")).to include(action: "preview", id: "42")
      expect(recognize("http://example.fr/personnes/recherche")).to include(action: "search")
    end

    it "translates the explicit `path:` of a member action instead of the action name" do
      I18n.backend.store_translations(:"fr-FR", routes: {look: "regard"})

      draw { localized { resources(:people, only: []) { get :preview, on: :member, path: "look" } } }

      expect(named_paths).to eq(
        "preview_person_fr_fr" => "/personnes/:id/regard(.:format)",
        "preview_person_fr_ch" => "/fr-ch/gens/:id/look(.:format)",
        "preview_person_de_ch" => "/de-ch/leute/:id/look(.:format)"
      )
      expect(recognize("http://example.fr/personnes/42/regard")).to include(action: "preview", id: "42")
    end

    it "keeps the parent :person_id param of nested resources" do
      draw { localized { resources(:people) { resources :photos, only: :index } } }

      expect(named_paths).to include(
        "person_photos_fr_fr" => "/personnes/:person_id/photos(.:format)",
        "person_photos_de_ch" => "/de-ch/leute/:person_id/photos(.:format)"
      )
      expect(recognize("http://example.fr/personnes/7/photos"))
        .to eq(host: "example.fr", locale: "fr-FR", controller: "photos", action: "index", person_id: "7")
    end
  end

  describe "`resource` inside `localized`" do
    before do
      stub_controllers("ProfilesController")
      I18n.backend.store_translations(:"fr-FR", routes: {profile: "profil"})
    end

    it "names the singular routes per locale with translated paths" do
      draw { localized { resource :profile } }

      expect(named_paths).to eq(
        "new_profile_fr_fr" => "/profil/new(.:format)",
        "new_profile_fr_ch" => "/fr-ch/profile/new(.:format)",
        "new_profile_de_ch" => "/de-ch/profile/new(.:format)",
        "edit_profile_fr_fr" => "/profil/edit(.:format)",
        "edit_profile_fr_ch" => "/fr-ch/profile/edit(.:format)",
        "edit_profile_de_ch" => "/de-ch/profile/edit(.:format)",
        "profile_fr_fr" => "/profil(.:format)",
        "profile_fr_ch" => "/fr-ch/profile(.:format)",
        "profile_de_ch" => "/de-ch/profile(.:format)"
      )
    end

    it "routes to the pluralized controller" do
      draw { localized { resource :profile } }

      expect(recognize("http://example.fr/profil")).to include(controller: "profiles", action: "show")
      expect(recognize("http://example.fr/profil", method: "POST")).to include(controller: "profiles", action: "create")
      expect(recognize("http://example.ch/fr-ch/profile", method: "DELETE"))
        .to include(controller: "profiles", action: "destroy", locale: "fr-CH")
    end
  end

  describe "`scope` and `namespace` inside `localized`" do
    before { stub_controllers("PeopleController", "Admin::PeopleController", "Api::PeopleController") }

    it "looks up translations under the namespaced controller key" do
      I18n.backend.store_translations(
        :"fr-FR",
        routes: {admin: "administration", controllers: {"admin/people" => {people: "gens-admin"}}}
      )

      draw do
        localized do
          resources :people, only: :index
          namespace(:admin) { resources :people, only: :index }
        end
      end

      expect(named_paths).to include(
        "people_fr_fr" => "/personnes(.:format)",
        "admin_people_fr_fr" => "/administration/gens-admin(.:format)",
        "admin_people_de_ch" => "/de-ch/admin/leute(.:format)"
      )
      expect(recognize("http://example.fr/administration/gens-admin"))
        .to include(controller: "admin/people", action: "index", locale: "fr-FR")
    end

    it "keeps dynamic scope segments untranslated and prefixes the route name" do
      draw { localized { scope("/:account_id", as: :account) { get "people", to: "people#index" } } }

      expect(named_paths).to eq(
        "account_people_fr_fr" => "/:account_id/personnes(.:format)",
        "account_people_fr_ch" => "/fr-ch/:account_id/gens(.:format)",
        "account_people_de_ch" => "/de-ch/:account_id/leute(.:format)"
      )
      expect(recognize("http://example.fr/acme/personnes")).to include(account_id: "acme", controller: "people")
    end

    it "routes to the scoped module's controller" do
      draw { localized { scope(module: :api) { get "people", to: "people#index", as: :api_people } } }

      expect(named_paths).to include("api_people_fr_fr" => "/personnes(.:format)")
      expect(recognize("http://example.fr/personnes")).to include(controller: "api/people", action: "index")
    end

    it "applies scope-level constraints and defaults to every localized route" do
      draw do
        localized do
          constraints(id: /\d+/) { get "people/:id", to: "people#show", as: :person }
          defaults(kind: "vip") { get "people/vip", to: "people#vip", as: :vip }
        end
      end

      expect(recognize("http://example.ch/de-ch/leute/42")).to include(action: "show", id: "42")
      expect(recognize("http://example.ch/de-ch/leute/abc")).to be_nil
      expect(recognize("http://example.fr/personnes/vip")).to include(action: "vip", kind: "vip")
    end

    it "passes extra scope options on to every localized route as params and requirements" do
      draw { localized { scope(kind: "vip", id: /\d+/) { get "people/:id", to: "people#show", as: :person } } }

      expect(recognize("http://example.ch/fr-ch/gens/42"))
        .to eq(host: "example.ch", locale: "fr-CH", kind: "vip", controller: "people", action: "show", id: "42")
      expect(recognize("http://example.ch/fr-ch/gens/abc")).to be_nil
    end
  end

  describe "route-level options inside `localized`" do
    before { stub_controllers("PeopleController") }

    it "keeps a `constraints:` hash on top of the host and locale constraints" do
      draw { localized { get "people/:id", to: "people#show", as: :person, constraints: {id: /\d+/} } }

      expect(recognize("http://example.fr/personnes/42")).to include(action: "show", id: "42", locale: "fr-FR")
      expect(recognize("http://example.fr/personnes/abc")).to be_nil
      expect(recognize("http://example.ch/de-ch/leute/abc")).to be_nil
    end

    it "turns extra options into params and regexp options into requirements" do
      draw { localized { get "people/:id", to: "people#show", as: :person, kind: "vip", id: /\d+/ } }

      expect(recognize("http://example.ch/de-ch/leute/42"))
        .to eq(host: "example.ch", locale: "de-CH", kind: "vip", controller: "people", action: "show", id: "42")
      expect(recognize("http://example.ch/de-ch/leute/abc")).to be_nil
    end

    it "honours `format: false` and `format: true` in the translated paths" do
      draw do
        localized do
          get "people", to: "people#index", as: :people, format: false
          get "people/export", to: "people#export", as: :export, format: true
        end
      end

      expect(named_paths).to eq(
        "people_fr_fr" => "/personnes",
        "people_fr_ch" => "/fr-ch/gens",
        "people_de_ch" => "/de-ch/leute",
        "export_fr_fr" => "/personnes/export.:format",
        "export_fr_ch" => "/fr-ch/gens/export.:format",
        "export_de_ch" => "/de-ch/leute/export.:format"
      )
      expect(recognize("http://example.fr/personnes.json")).to be_nil
      expect(recognize("http://example.fr/personnes/export.csv")).to include(action: "export", format: "csv")
      expect(recognize("http://example.fr/personnes/export")).to be_nil
    end

    it "uses a string `format:` as the default and only accepted format" do
      draw { localized { get "people", to: "people#index", as: :people, format: "json" } }

      expect(recognize("http://example.ch/fr-ch/gens"))
        .to eq(host: "example.ch", locale: "fr-CH", format: "json", controller: "people", action: "index")
      expect(recognize("http://example.ch/fr-ch/gens.json")).to include(format: "json")
      expect(recognize("http://example.ch/fr-ch/gens.xml")).to be_nil
    end

    it "URI-escapes the untranslated parts of the path, as Rails does" do
      draw { localized { get "people/année-:year", to: "people#index", as: :archives } }

      expect(named_paths).to include(
        "archives_fr_fr" => "/personnes/ann%C3%A9e-:year(.:format)",
        "archives_de_ch" => "/de-ch/leute/ann%C3%A9e-:year(.:format)"
      )
      expect(recognize("http://example.fr/personnes/ann%C3%A9e-2024")).to include(action: "index", year: "2024")
      expect(url_helpers.archives_fr_fr_path(year: 2024)).to eq("/personnes/ann%C3%A9e-2024")
    end
  end

  describe "route names" do
    before { stub_controllers("PeopleController") }

    it "adds unnamed routes when `as: false` is given" do
      draw { localized { get "people", to: "people#index", as: false } }

      expect(route_table).to eq([
        [nil, "GET", "/personnes(.:format)"],
        [nil, "GET", "/fr-ch/gens(.:format)"],
        [nil, "GET", "/de-ch/leute(.:format)"]
      ])
      expect(route_set.named_routes.names).to be_empty
      # `as:` is a routing option, never a request param.
      expect(recognize("http://example.ch/fr-ch/gens"))
        .to eq(host: "example.ch", locale: "fr-CH", controller: "people", action: "index")
    end

    it "adds unnamed routes when `as: nil` is given" do
      draw { localized { get "people", to: "people#index", as: nil } }

      expect(route_table.map(&:first)).to eq([nil, nil, nil])
      expect(route_set.named_routes.names).to be_empty
      expect(recognize("http://example.fr/personnes"))
        .to eq(host: "example.fr", locale: "fr-FR", controller: "people", action: "index")
    end

    it "uses a custom `as:` name as the prefix of every localized name" do
      draw { localized { get "people", to: "people#index", as: :team } }

      expect(named_paths).to eq(
        "team_fr_fr" => "/personnes(.:format)",
        "team_fr_ch" => "/fr-ch/gens(.:format)",
        "team_de_ch" => "/de-ch/leute(.:format)"
      )
      expect(recognize("http://example.fr/personnes"))
        .to eq(host: "example.fr", locale: "fr-FR", controller: "people", action: "index")
    end

    it "derives the name from the path when `as:` is omitted" do
      draw { localized { get "people/feed", to: "people#feed" } }

      expect(named_paths.keys).to contain_exactly("people_feed_fr_fr", "people_feed_fr_ch", "people_feed_de_ch")
    end

    it "leaves a route unnamed when its path has a dynamic segment and `as:` is omitted, as Rails does" do
      draw { localized { get "people/:id", to: "people#show" } }

      expect(route_table).to eq([
        [nil, "GET", "/personnes/:id(.:format)"],
        [nil, "GET", "/fr-ch/gens/:id(.:format)"],
        [nil, "GET", "/de-ch/leute/:id(.:format)"]
      ])
      expect(recognize("http://example.fr/personnes/42")).to include(action: "show", id: "42")
    end
  end

  describe "controller and action resolution" do
    before { stub_controllers("PeopleController", "AccountsController", "HomeController") }

    it "takes the controller and action from `to:`" do
      draw { localized { get "people", to: "people#index" } }

      expect(recognize("http://example.fr/personnes")).to include(controller: "people", action: "index")
    end

    it "takes the action from an `action:` option" do
      draw { localized { get "people/list", controller: :people, action: :index, as: :list } }

      expect(named_paths).to include("list_fr_fr" => "/personnes/list(.:format)")
      expect(recognize("http://example.fr/personnes/list")).to include(controller: "people", action: "index")
    end

    it "prefers the `action:` option over the action of the enclosing scope, as Rails does" do
      draw { localized { scope(action: :lookup) { get "people/:id", controller: :people, action: :show, as: :person } } }

      expect(recognize("http://example.ch/de-ch/leute/42")).to include(controller: "people", action: "show", id: "42")
    end

    it "falls back to the action given by the enclosing scope" do
      draw { localized { scope(action: :lookup) { get "people/:id", controller: :people, as: :lookup } } }

      expect(named_paths).to include("lookup_fr_fr" => "/personnes/:id(.:format)")
      expect(recognize("http://example.fr/personnes/42")).to include(controller: "people", action: "lookup", id: "42")
    end

    it "turns a hyphenated path into an underscored default action" do
      I18n.backend.store_translations(:"fr-FR", routes: {"log-in": "connexion"})

      draw do
        localized do
          scope(controller: :accounts) do
            get "log-in"
            get :"sign-out"
          end
        end
      end

      expect(named_paths).to include(
        "log_in_fr_fr" => "/connexion(.:format)",
        "log_in_de_ch" => "/de-ch/log-in(.:format)",
        "sign_out_fr_fr" => "/sign-out(.:format)"
      )
      expect(recognize("http://example.fr/connexion")).to include(controller: "accounts", action: "log_in")
      expect(recognize("http://example.ch/de-ch/log-in")).to include(controller: "accounts", action: "log_in")
      expect(recognize("http://example.fr/sign-out")).to include(controller: "accounts", action: "sign_out")
    end

    it "raises like Rails when no action can be derived from the path" do
      # Rails only derives an action from a single path segment: "/feed" has none.
      expect { ActionDispatch::Routing::RouteSet.new.draw { scope(controller: :accounts) { get "/feed" } } }
        .to raise_error(ArgumentError, /Missing :action/)
      expect { draw { localized { scope(controller: :accounts) { get "/feed" } } } }
        .to raise_error(ArgumentError, /Missing :action/)
      expect(route_set.routes).to be_empty
    end

    it "localizes the root route with the locale as the whole path on multi-locale hosts" do
      draw { localized { root to: "home#index" } }

      expect(named_paths).to eq("root_fr_fr" => "/", "root_fr_ch" => "/fr-ch", "root_de_ch" => "/de-ch")
      expect(recognize("http://example.fr/")).to include(controller: "home", action: "index", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch")).to include(controller: "home", action: "index", locale: "de-CH")
    end

    it "raises when the route resolves to an empty path" do
      # A canonical action at the root of a collection scope has no path; the
      # public DSL always builds a non-empty scope path, so the scope level is
      # set through the mapper's private helper.
      expect {
        draw { localized { with_scope_level(:collection) { get :index, to: "people#index" } } }
      }.to raise_error(ArgumentError, "path is required")
      expect(route_set.routes).to be_empty
    end
  end

  describe "`mount`" do
    let(:mounted_helpers_context) do
      Class.new.tap do |klass|
        klass.include(route_set.url_helpers)
        klass.include(route_set.mounted_helpers)
      end.new
    end

    before do
      I18n.backend.store_translations(:"fr-FR", routes: {blog: "journal"})
      I18n.backend.store_translations(:"de-CH", routes: {blog: "tagebuch"})
    end

    after do
      # Mounted engine helpers are defined on a module shared by every route set.
      helpers = ActionDispatch::Routing::RouteSet::MountedHelpers
      helpers.instance_methods.grep(/i18n_mapper_spec_/).each { |name| helpers.send(:remove_method, name) }
    end

    context "with a Rack application" do
      let(:rack_app) do
        ->(env) { [200, {}, ["#{env["SCRIPT_NAME"]} #{env["PATH_INFO"]}"]] }
      end

      it "mounts it once per host and locale under the translated path" do
        app = rack_app
        draw { localized { mount app, at: "blog", as: :i18n_mapper_spec_rack } }

        expect(named_paths).to eq(
          "i18n_mapper_spec_rack_fr_fr" => "/journal",
          "i18n_mapper_spec_rack_fr_ch" => "/fr-ch/blog",
          "i18n_mapper_spec_rack_de_ch" => "/de-ch/tagebuch"
        )
      end

      it "dispatches requests with the translated mount point as script name" do
        app = rack_app
        draw { localized { mount app, at: "blog", as: :i18n_mapper_spec_rack } }

        _status, _headers, body = route_set.call(rack_env("http://example.ch/de-ch/tagebuch/posts", "GET"))
        expect(body.to_a).to eq(["/de-ch/tagebuch /posts"])

        status, = route_set.call(rack_env("http://example.fr/de-ch/tagebuch/posts", "GET"))
        expect(status).to eq(404)
      end

      it "does not define mounted helpers, as for any plain Rack application" do
        app = rack_app
        draw { localized { mount app, at: "blog", as: :i18n_mapper_spec_rack } }

        expect(route_set.mounted_helpers.instance_methods.grep(/i18n_mapper_spec_rack/)).to be_empty
      end
    end

    context "with a Rails engine" do
      let(:engine_routes) do
        ActionDispatch::Routing::RouteSet.new.tap do |routes|
          routes.draw { get "posts", to: ->(env) { [200, {}, [env["SCRIPT_NAME"]]] }, as: :posts }
        end
      end

      # railties is not a dependency of the gem: a stand-in Rails::Railtie is
      # enough for Mapper#mount to treat the app as an engine.
      let(:engine) do
        stub_const("Rails::Railtie", Class.new)
        routes = engine_routes
        Class.new(Rails::Railtie) do
          define_singleton_method(:routes) { routes }
          define_singleton_method(:railtie_name) { "i18n_mapper_spec_blog" }
          define_singleton_method(:call) { |env| routes.call(env) }
        end
      end

      it "mounts it once per host and locale under the translated path" do
        mounted = engine
        draw { localized { mount mounted, at: "blog" } }

        expect(named_paths).to eq(
          "i18n_mapper_spec_blog_fr_fr" => "/journal",
          "i18n_mapper_spec_blog_fr_ch" => "/fr-ch/blog",
          "i18n_mapper_spec_blog_de_ch" => "/de-ch/tagebuch"
        )
      end

      it "defines a mounted helper per locale that generates the engine's routes under that locale's prefix" do
        mounted = engine
        draw { localized { mount mounted, at: "blog" } }

        expect(mounted_helpers_context.i18n_mapper_spec_blog_fr_fr.posts_path({})).to eq("/journal/posts")
        expect(mounted_helpers_context.i18n_mapper_spec_blog_fr_ch.posts_path({})).to eq("/fr-ch/blog/posts")
        expect(mounted_helpers_context.i18n_mapper_spec_blog_de_ch.posts_path({})).to eq("/de-ch/tagebuch/posts")
      end

      it "dispatches requests to the engine with the translated mount point as script name" do
        mounted = engine
        draw { localized { mount mounted, at: "blog" } }

        _status, _headers, body = route_set.call(rack_env("http://example.fr/journal/posts", "GET"))
        expect(body.to_a).to eq(["/journal"])
      end

      it "defines the regular, unsuffixed mounted helper when mounted outside `localized`" do
        mounted = engine
        draw { mount mounted, at: "blog" }

        expect(named_paths).to eq("i18n_mapper_spec_blog" => "/blog")
        expect(mounted_helpers_context.i18n_mapper_spec_blog.posts_path({})).to eq("/blog/posts")
        expect(route_set.mounted_helpers.method_defined?(:i18n_mapper_spec_blog_fr_fr)).to be(false)
      end
    end
  end
end
