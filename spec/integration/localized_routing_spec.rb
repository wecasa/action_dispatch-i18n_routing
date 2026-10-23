# frozen_string_literal: true

require "stringio"
require "uri"

RSpec.describe "Localized routing across hosts (integration)" do
  let(:locales_per_host) do
    {
      "example.fr" => [:"fr-FR"],
      "example.ch" => [:"de-CH", :"fr-CH", :"it-CH"],
      "example.co.uk" => [:"en-GB"]
    }
  end

  # Smallest object Rails' route dispatcher accepts as a controller class: it
  # answers every request with the path parameters the router recognized.
  let(:echo_controller) do
    Class.new do
      def self.action_encoding_template(_action)
        false
      end

      def self.make_response!(_request)
        nil
      end

      def self.dispatch(_action, request, _response)
        [200, {"content-type" => "text/plain"}, [request.path_parameters]]
      end
    end
  end

  # A mounted Rack application that reports where the router mounted it.
  let(:shop_app) do
    ->(env) { [200, {"content-type" => "text/plain"}, [{script_name: env["SCRIPT_NAME"], path_info: env["PATH_INFO"]}]] }
  end

  let(:invoice_number_constraint) { {number: /\d+/} }

  let(:route_set) do
    # The draw block runs inside the mapper, so it only sees local variables.
    shop = shop_app
    invoice_number = invoice_number_constraint
    beta_testers = ->(request) { request.get_header("HTTP_X_BETA") == "1" }

    ActionDispatch::Routing::RouteSet.new.tap do |routes|
      routes.draw do
        get "health", to: "health#show", as: :health

        localized do
          root to: "pages#home"
          get "about", to: "pages#about", as: :about
          get "contact", to: "pages#contact", as: :contact
          get "sitemap.xml", to: "pages#sitemap", as: :sitemap
          get "archive(/:year)", to: "pages#archive", as: :archive
          get "docs/*page", to: "pages#docs", as: :docs
          get "press", to: "pages#show", as: :press, defaults: {page: "press"}
          get "jobs", to: "pages#show", as: :jobs, page: "jobs"
          get "offers/:city-cleaning", to: "offers#show", as: :city_offer
          get "invoices/:number", to: "invoices#show", as: :invoice, constraints: invoice_number
          get "invoices/:number/pdf", to: "invoices#pdf"

          controller :pages do
            get "opening-hours"
          end

          resources :people, constraints: {id: /\d+/} do
            resources :comments, only: %i[index show]
          end

          scope "help" do
            get "faq", to: "pages#faq", as: :faq
          end

          scope "(:region)", region: /north|south/ do
            get "shops", to: "pages#shops", as: :shops
          end

          defaults format: "json" do
            get "feed", to: "pages#feed", as: :feed
          end

          constraints beta_testers do
            get "beta", to: "pages#beta", as: :beta
          end

          namespace :admin do
            resources :people, only: :index
          end

          mount shop, at: "shop", as: :shop
        end

        get "status", to: "health#status", as: :status
      end
    end
  end

  let(:helpers) { route_set.url_helpers }

  before do
    ActionDispatch::I18nRouting.config.available_locales_per_host = locales_per_host
    I18n.available_locales = [I18n.default_locale, *locales_per_host.values.flatten]

    I18n.backend.store_translations(
      :"fr-FR",
      routes: {
        people: "personnes", comments: "commentaires", new: "nouveau", edit: "modifier",
        about: "a-propos", help: "aide", invoices: "factures", admin: "administration",
        sitemap: "plan-du-site", archive: "archives", docs: "documentation", press: "presse",
        jobs: "emplois", offers: "offres", cleaning: "menage", "opening-hours": "horaires",
        shops: "boutiques", feed: "flux", shop: "boutique",
        controllers: {pages: {about: "qui-sommes-nous"}, "admin/people": {people: "membres"}}
      }
    )
    I18n.backend.store_translations(
      :"fr-CH",
      routes: {
        people: "gens", comments: "commentaires", new: "nouveau", edit: "modifier",
        about: "a-propos", help: "aide", invoices: "factures", shops: "boutiques"
      }
    )
    I18n.backend.store_translations(
      :"de-CH",
      routes: {
        people: "leute", comments: "kommentare", new: "neu", edit: "bearbeiten",
        about: "über-uns", help: "hilfe", invoices: "rechnungen", admin: "verwaltung",
        archive: "archiv", docs: "doku", offers: "angebote", cleaning: "reinigung",
        "opening-hours": "oeffnungszeiten", shops: "laeden"
      }
    )
    # it-CH is only partially translated and en-GB not at all: every missing
    # segment must fall back to the segment written in the routes file.
    I18n.backend.store_translations(:"it-CH", routes: {people: "persone", comments: "commenti"})

    %w[
      HealthController PagesController InvoicesController PeopleController
      CommentsController OffersController Admin::PeopleController
    ].each { |controller_name| stub_const(controller_name, echo_controller) }

    # Named route helpers type-check their last argument against
    # ActionController::Parameters, which a Rails app always loads but this
    # gem (which only depends on action_dispatch) does not.
    stub_const("ActionController::Parameters", Class.new) unless defined?(ActionController::Parameters)
  end

  # Builds the Rack env by hand: Rack::MockRequest (and therefore
  # RouteSet#recognize_path) is not loadable on every supported Ruby.
  def rack_env(url, method, headers)
    uri = URI.parse(url)
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
    }.merge(headers)
  end

  # Sends the request through the route set and returns what the matched
  # endpoint answered (the recognized path parameters for controllers), or nil
  # when no route matched.
  def recognize(url, method: "GET", headers: {})
    status, _headers, body = route_set.call(rack_env(url, method, headers))
    body.first if status == 200
  end

  describe "recognition" do
    it "resolves the same path to the locale of the requesting host" do
      expect(recognize("http://example.fr/contact"))
        .to include(controller: "pages", action: "contact", locale: "fr-FR")
      expect(recognize("http://example.co.uk/contact"))
        .to include(controller: "pages", action: "contact", locale: "en-GB")
    end

    it "serves the root of single-locale hosts at / in the host's locale" do
      expect(recognize("http://example.fr/")).to include(controller: "pages", action: "home", locale: "fr-FR")
      expect(recognize("http://example.co.uk/")).to include(controller: "pages", action: "home", locale: "en-GB")
    end

    it "serves the root of each locale of a multi-locale host under its locale prefix" do
      expect(recognize("http://example.ch/de-ch")).to include(controller: "pages", action: "home", locale: "de-CH")
      expect(recognize("http://example.ch/fr-ch")).to include(controller: "pages", action: "home", locale: "fr-CH")
      expect(recognize("http://example.ch/it-ch")).to include(controller: "pages", action: "home", locale: "it-CH")
    end

    {
      "http://example.fr/personnes" => "fr-FR",
      "http://example.ch/de-ch/leute" => "de-CH",
      "http://example.ch/fr-ch/gens" => "fr-CH",
      "http://example.ch/it-ch/persone" => "it-CH",
      "http://example.co.uk/people" => "en-GB"
    }.each do |url, locale|
      it "recognizes the translated path #{url} in #{locale}" do
        expect(recognize(url)).to include(controller: "people", action: "index", locale: locale)
      end
    end

    it "only recognizes a translated path on the host it was translated for" do
      expect(recognize("http://example.ch/de-ch/leute")).to include(locale: "de-CH")
      expect(recognize("http://example.fr/de-ch/leute")).to be_nil
      expect(recognize("http://example.co.uk/de-ch/leute")).to be_nil
      expect(recognize("http://example.ch/personnes")).to be_nil
      expect(recognize("http://example.fr/people")).to be_nil
    end

    it "does not recognize a path that mixes one locale's prefix with another locale's words" do
      expect(recognize("http://example.ch/de-ch/gens")).to be_nil
      expect(recognize("http://example.ch/fr-ch/leute")).to be_nil
      expect(recognize("http://example.ch/it-ch/leute")).to be_nil
    end

    it "requires the locale prefix on a multi-locale host" do
      expect(recognize("http://example.ch/leute")).to be_nil
      expect(recognize("http://example.ch/gens")).to be_nil
    end

    it "does not recognize localized paths on a host that is not configured" do
      expect(recognize("http://example.de/people")).to be_nil
      expect(recognize("http://example.de/personnes")).to be_nil
    end

    it "falls back to the original segment when a locale has no translation for it" do
      expect(recognize("http://example.ch/it-ch/persone/new")).to include(controller: "people", action: "new", locale: "it-CH")
      expect(recognize("http://example.ch/it-ch/about")).to include(controller: "pages", action: "about", locale: "it-CH")
      expect(recognize("http://example.co.uk/people/new")).to include(controller: "people", action: "new", locale: "en-GB")
      expect(recognize("http://example.ch/de-ch/hilfe/faq")).to include(controller: "pages", action: "faq", locale: "de-CH")
    end

    it "prefers a controller-scoped translation over the generic one" do
      expect(recognize("http://example.fr/qui-sommes-nous")).to include(controller: "pages", action: "about", locale: "fr-FR")
      expect(recognize("http://example.fr/a-propos")).to be_nil
      expect(recognize("http://example.ch/fr-ch/a-propos")).to include(controller: "pages", action: "about", locale: "fr-CH")
    end

    it "recognizes percent-encoded non-ASCII translations" do
      expect(recognize("http://example.ch/de-ch/%C3%BCber-uns"))
        .to include(controller: "pages", action: "about", locale: "de-CH")
    end

    it "translates every segment of resource member and nested routes" do
      expect(recognize("http://example.fr/personnes/nouveau")).to include(action: "new", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/leute/7/bearbeiten")).to include(action: "edit", id: "7", locale: "de-CH")
      expect(recognize("http://example.ch/fr-ch/gens/7/commentaires"))
        .to include(controller: "comments", action: "index", person_id: "7", locale: "fr-CH")
    end

    it "extracts path parameters" do
      expect(recognize("http://example.ch/fr-ch/gens/42"))
        .to include(controller: "people", action: "show", id: "42", locale: "fr-CH")
      expect(recognize("http://example.ch/de-ch/leute/7/kommentare/3"))
        .to include(controller: "comments", action: "show", person_id: "7", id: "3", locale: "de-CH")
    end

    it "extracts the format" do
      expect(recognize("http://example.fr/personnes/5.json")).to include(action: "show", id: "5", format: "json")
      expect(recognize("http://example.ch/it-ch/persone/12/commenti.xml"))
        .to include(controller: "comments", action: "index", person_id: "12", format: "xml", locale: "it-CH")
      expect(recognize("http://example.co.uk/people.json")).to include(action: "index", format: "json", locale: "en-GB")
    end

    it "dispatches on the HTTP verb like regular resources" do
      expect(recognize("http://example.ch/fr-ch/gens", method: "POST")).to include(action: "create", locale: "fr-CH")
      expect(recognize("http://example.fr/personnes/5", method: "PATCH")).to include(action: "update", id: "5")
      expect(recognize("http://example.co.uk/people/5", method: "DELETE")).to include(action: "destroy", locale: "en-GB")
      expect(recognize("http://example.fr/personnes/5", method: "POST")).to be_nil
    end

    # Rails also copies the route's host constraint into the params; the
    # examples below only care that nothing else leaks in.
    it "hands the controller exactly the route's parameters and the locale" do
      expect(recognize("http://example.fr/factures/12").except(:host))
        .to eq(controller: "invoices", action: "show", number: "12", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/leute/7/kommentare/3").except(:host))
        .to eq(controller: "comments", action: "show", person_id: "7", id: "3", locale: "de-CH")
    end

    it "keeps the route's own segment constraints" do
      expect(recognize("http://example.ch/de-ch/rechnungen/12"))
        .to include(controller: "invoices", action: "show", number: "12", locale: "de-CH")
      expect(recognize("http://example.ch/de-ch/rechnungen/abc")).to be_nil
    end

    it "leaves the constraints hash given to a route untouched" do
      route_set

      expect(invoice_number_constraint).to eq(number: /\d+/)
    end

    it "keeps segment constraints declared on a resource" do
      expect(recognize("http://example.fr/personnes/42")).to include(action: "show", id: "42")
      expect(recognize("http://example.fr/personnes/abc")).to be_nil
      expect(recognize("http://example.ch/de-ch/leute/abc/kommentare")).to be_nil
    end

    it "keeps the request constraints of an enclosing constraints block" do
      expect(recognize("http://example.ch/fr-ch/beta", headers: {"HTTP_X_BETA" => "1"}))
        .to include(controller: "pages", action: "beta", locale: "fr-CH")
      expect(recognize("http://example.ch/fr-ch/beta")).to be_nil
    end

    it "recognizes unnamed routes" do
      expect(recognize("http://example.ch/de-ch/rechnungen/12/pdf"))
        .to include(controller: "invoices", action: "pdf", number: "12", locale: "de-CH")
    end

    it "translates path scopes" do
      expect(recognize("http://example.fr/aide/faq")).to include(controller: "pages", action: "faq", locale: "fr-FR")
      expect(recognize("http://example.fr/help/faq")).to be_nil
    end

    it "keeps optional dynamic scopes and the requirements given to them, after the locale prefix" do
      expect(recognize("http://example.fr/boutiques")).to include(controller: "pages", action: "shops", locale: "fr-FR")
      expect(recognize("http://example.fr/north/boutiques")).to include(action: "shops", region: "north", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/laeden")).to include(action: "shops", locale: "de-CH")
      expect(recognize("http://example.ch/de-ch/south/laeden")).to include(action: "shops", region: "south", locale: "de-CH")
      expect(recognize("http://example.fr/east/boutiques")).to be_nil
    end

    it "translates the static part of a segment followed by an optional segment" do
      expect(recognize("http://example.fr/archives")).to include(controller: "pages", action: "archive", locale: "fr-FR")
      expect(recognize("http://example.fr/archives")).not_to include(:year)
      expect(recognize("http://example.ch/de-ch/archiv/2021")).to include(action: "archive", year: "2021", locale: "de-CH")
    end

    it "translates each dot-separated part of a segment" do
      params = recognize("http://example.fr/plan-du-site.xml")

      expect(params).to include(controller: "pages", action: "sitemap", locale: "fr-FR")
      expect(params).not_to include(:format)
      expect(recognize("http://example.ch/de-ch/sitemap.xml")).to include(action: "sitemap", locale: "de-CH")
    end

    it "translates hyphenated segments as a whole and derives an underscored action from them" do
      expect(recognize("http://example.fr/horaires")).to include(controller: "pages", action: "opening_hours", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/oeffnungszeiten")).to include(action: "opening_hours", locale: "de-CH")
      expect(recognize("http://example.co.uk/opening-hours")).to include(action: "opening_hours", locale: "en-GB")
    end

    it "translates the static suffix of a segment that starts with a param" do
      expect(recognize("http://example.fr/offres/paris-menage"))
        .to include(controller: "offers", action: "show", city: "paris", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/angebote/bern-reinigung")).to include(city: "bern", locale: "de-CH")
      expect(recognize("http://example.co.uk/offers/london-cleaning")).to include(city: "london", locale: "en-GB")
      expect(recognize("http://example.fr/offres/paris-cleaning")).to be_nil
    end

    it "keeps glob segments untranslated" do
      expect(recognize("http://example.fr/documentation/guides/setup"))
        .to include(controller: "pages", action: "docs", page: "guides/setup", locale: "fr-FR")
      expect(recognize("http://example.ch/de-ch/doku/faq")).to include(action: "docs", page: "faq", locale: "de-CH")
    end

    it "passes route defaults given inline, with defaults: or by a defaults block" do
      expect(recognize("http://example.fr/presse")).to include(controller: "pages", action: "show", page: "press", locale: "fr-FR")
      expect(recognize("http://example.fr/emplois")).to include(controller: "pages", action: "show", page: "jobs", locale: "fr-FR")
      expect(recognize("http://example.fr/flux")).to include(controller: "pages", action: "feed", format: "json", locale: "fr-FR")
    end

    it "translates namespaces, looking translations up under the namespaced controller" do
      expect(recognize("http://example.fr/administration/membres"))
        .to include(controller: "admin/people", action: "index", locale: "fr-FR")
      expect(recognize("http://example.fr/administration/personnes")).to be_nil
      expect(recognize("http://example.ch/de-ch/verwaltung/leute"))
        .to include(controller: "admin/people", action: "index", locale: "de-CH")
    end

    it "mounts Rack applications at the translated mount point of each locale" do
      expect(recognize("http://example.fr/boutique/panier")).to eq(script_name: "/boutique", path_info: "/panier")
      expect(recognize("http://example.ch/de-ch/shop")).to eq(script_name: "/de-ch/shop", path_info: "/")
      expect(recognize("http://example.co.uk/shop/basket")).to eq(script_name: "/shop", path_info: "/basket")
      expect(recognize("http://example.fr/shop/basket")).to be_nil
    end

    it "recognizes routes declared outside the localized block on every host, without a locale" do
      ["example.fr", "example.ch", "example.co.uk", "example.de"].each do |host|
        params = recognize("http://#{host}/health")

        expect(params).to include(controller: "health", action: "show")
        expect(params).not_to include(:locale)
      end
    end

    it "stops localizing once the localized block is closed" do
      params = recognize("http://example.fr/status")

      expect(params).to include(controller: "health", action: "status")
      expect(params).not_to include(:locale)
      expect(recognize("http://example.ch/de-ch/status")).to be_nil
    end
  end

  describe "generation" do
    it "registers one named route per host locale and none under the bare name" do
      people_routes = route_set.named_routes.names.grep(/\Apeople/)

      expect(people_routes).to contain_exactly(:people_fr_fr, :people_de_ch, :people_fr_ch, :people_it_ch, :people_en_gb)
      expect(route_set.named_routes.names).to include(:health, :status)
      expect(route_set.named_routes.names).not_to include(:health_fr_fr, :status_fr_fr)
    end

    it "names every named localized route <name>_<locale> and leaves unnamed routes unnamed" do
      locales = %w[fr_fr de_ch fr_ch it_ch en_gb]
      localized_names = %w[
        root about contact sitemap archive docs press jobs city_offer invoice opening_hours
        people new_person edit_person person person_comments person_comment
        faq shops feed beta admin_people shop
      ]

      expect(route_set.named_routes.names.map(&:to_s)).to contain_exactly(
        "health", "status", *localized_names.product(locales).map { |name, locale| "#{name}_#{locale}" }
      )
    end

    {
      people_fr_fr_path: "/personnes",
      people_de_ch_path: "/de-ch/leute",
      people_fr_ch_path: "/fr-ch/gens",
      people_it_ch_path: "/it-ch/persone",
      people_en_gb_path: "/people",
      root_fr_fr_path: "/",
      root_de_ch_path: "/de-ch",
      root_en_gb_path: "/",
      new_person_it_ch_path: "/it-ch/persone/new",
      faq_fr_ch_path: "/fr-ch/aide/faq",
      about_fr_fr_path: "/qui-sommes-nous",
      about_de_ch_path: "/de-ch/%C3%BCber-uns",
      admin_people_fr_fr_path: "/administration/membres",
      admin_people_de_ch_path: "/de-ch/verwaltung/leute",
      sitemap_fr_fr_path: "/plan-du-site.xml",
      sitemap_de_ch_path: "/de-ch/sitemap.xml",
      opening_hours_fr_fr_path: "/horaires",
      archive_fr_fr_path: "/archives",
      shops_fr_fr_path: "/boutiques",
      shops_it_ch_path: "/it-ch/shops"
    }.each do |helper, path|
      it "generates #{path} from #{helper}" do
        expect(helpers.public_send(helper)).to eq(path)
      end
    end

    it "fills in path parameters and the format" do
      expect(helpers.person_it_ch_path(12)).to eq("/it-ch/persone/12")
      expect(helpers.edit_person_fr_fr_path(5)).to eq("/personnes/5/modifier")
      expect(helpers.person_comment_de_ch_path(7, 3, format: :json)).to eq("/de-ch/leute/7/kommentare/3.json")
      expect(helpers.invoice_en_gb_path(99)).to eq("/invoices/99")
      expect(helpers.archive_de_ch_path(year: 2020)).to eq("/de-ch/archiv/2020")
      expect(helpers.shops_de_ch_path(region: "south")).to eq("/de-ch/south/laeden")
      expect(helpers.docs_fr_fr_path(page: "guides/setup")).to eq("/documentation/guides/setup")
      expect(helpers.city_offer_de_ch_path(city: "bern")).to eq("/de-ch/angebote/bern-reinigung")
    end

    it "builds _url helpers on the host the locale belongs to" do
      expect(helpers.people_fr_fr_url).to eq("http://example.fr/personnes")
      expect(helpers.people_fr_ch_url).to eq("http://example.ch/fr-ch/gens")
      expect(helpers.person_en_gb_url(3)).to eq("http://example.co.uk/people/3")
      expect(helpers.root_fr_fr_url).to eq("http://example.fr/")
      expect(helpers.root_it_ch_url).to eq("http://example.ch/it-ch")
    end

    it "keeps the locale's host in _url helpers even when a default host is configured" do
      route_set.default_url_options = {host: "www.example.com"}

      expect(helpers.people_de_ch_url).to eq("http://example.ch/de-ch/leute")
      expect(helpers.health_url).to eq("http://www.example.com/health")
    end

    it "leaves helpers of routes outside the localized block untouched" do
      expect(helpers.health_path).to eq("/health")
      expect(helpers.status_path).to eq("/status")
      expect(helpers).not_to respond_to(:health_fr_fr_path)
    end

    it "generates paths through url_for-style options using the locale to pick the variant" do
      expect(route_set.path_for(controller: "people", action: "index", locale: "fr-FR")).to eq("/personnes")
      expect(route_set.path_for(controller: "people", action: "show", id: 9, locale: "de-CH")).to eq("/de-ch/leute/9")
    end

    describe "locale-agnostic helpers" do
      it "picks the variant matching I18n.locale" do
        I18n.locale = :"fr-CH"

        expect(helpers.people_path).to eq("/fr-ch/gens")
        expect(helpers.person_path(3)).to eq("/fr-ch/gens/3")
        expect(helpers.person_comment_path(3, 4)).to eq("/fr-ch/gens/3/commentaires/4")
        expect(helpers.root_path).to eq("/fr-ch")
      end

      it "follows I18n.locale when it changes" do
        I18n.locale = :"en-GB"
        expect(helpers.people_path).to eq("/people")

        I18n.locale = :"fr-FR"
        expect(helpers.people_path).to eq("/personnes")
      end

      it "builds _url helpers on the host of the current I18n.locale" do
        I18n.locale = :"it-CH"

        expect(helpers.people_url).to eq("http://example.ch/it-ch/persone")
        expect(helpers.person_url(8)).to eq("http://example.ch/it-ch/persone/8")
      end

      it "lets an explicit locale: argument override I18n.locale" do
        I18n.locale = :"fr-CH"

        expect(helpers.person_path(3, locale: "de-CH")).to eq("/de-ch/leute/3")
        expect(helpers.person_path(3, locale: :"it-CH")).to eq("/it-ch/persone/3")
        expect(helpers.person_url(3, locale: :"fr-FR")).to eq("http://example.fr/personnes/3")
        expect(helpers.root_url(locale: :"en-GB")).to eq("http://example.co.uk/")
      end

      it "accepts the locale alongside named parameters" do
        expect(helpers.person_path(id: 3, locale: :"en-GB")).to eq("/people/3")
        expect(helpers.person_comment_path(7, 3, locale: "en-GB")).to eq("/people/7/comments/3")
        expect(helpers.about_path(locale: "de-CH")).to eq("/de-ch/%C3%BCber-uns")
      end

      it "does not leak the locale argument into the query string" do
        expect(helpers.people_path(locale: "fr-FR")).to eq("/personnes")
        expect(helpers.people_path(locale: "fr-FR", page: 2)).to eq("/personnes?page=2")
        expect(helpers.people_path(locale: "fr-FR", format: :json)).to eq("/personnes.json")
      end
    end

    describe "round trip" do
      it "recognizes every generated URL as the locale it was generated for" do
        locales_per_host.each do |host, locales|
          locales.each do |locale|
            url = helpers.person_comment_url(5, 6, locale: locale)

            expect(URI.parse(url).host).to eq(host)
            expect(recognize(url)).to include(
              controller: "comments", action: "show", person_id: "5", id: "6", locale: locale.to_s
            )
          end
        end
      end

      it "recognizes generated URLs whose translations contain non-ASCII characters" do
        expect(recognize(helpers.about_url(locale: "de-CH"))).to include(controller: "pages", action: "about", locale: "de-CH")
      end
    end
  end

  describe "hosts sharing a locale" do
    let(:locales_per_host) { {"example.fr" => [:"fr-FR"], "www.example.fr" => [:"fr-FR"]} }

    # Localized routes are named after their locale only: the route of the
    # second host could be neither named nor generated, and the helpers would
    # send its visitors to the first host.
    it "refuses to draw localized routes, naming the shared locale and its hosts" do
      expect { route_set }.to raise_error(
        ActionDispatch::I18nRouting::Error,
        /\ALocale :"fr-FR" is configured for several hosts \(example\.fr, www\.example\.fr\); each locale must belong to a single host/
      )
    end
  end

  # End-to-end checks of fixed bugs. Each example draws its own localized
  # routes, so that a route that cannot be drawn only fails its own example.
  describe "regressions" do
    let(:route_set) { ActionDispatch::Routing::RouteSet.new }

    def draw_localized(&routes)
      route_set.draw { localized { instance_exec(&routes) } }
    end

    # Status and headers of the response to a GET request, for endpoints that
    # do not answer 200 (redirects).
    def response_head(url)
      status, headers, = route_set.call(rack_env(url, "GET", {}))
      [status, headers["location"]]
    end

    context "with a segment made of more than a word" do
      before { I18n.backend.store_translations(:"fr-FR", routes: {page: "fiche"}) }

      it "keeps the optional suffix of a translated word" do
        draw_localized { get "page(s)", to: "pages#index", as: :pages }

        expect(recognize("http://example.fr/fiche")).to include(controller: "pages", action: "index", locale: "fr-FR")
        expect(recognize("http://example.fr/fiches")).to include(controller: "pages", action: "index", locale: "fr-FR")
        expect(recognize("http://example.co.uk/pages")).to include(controller: "pages", action: "index", locale: "en-GB")
        # Like Rails, generation keeps the optional part made of static text.
        expect(helpers.pages_path(locale: "fr-FR")).to eq("/fiches")
      end

      it "keeps the closing parenthesis of an optional segment" do
        draw_localized { get "people(/archive)", to: "people#index", as: :people }

        expect(recognize("http://example.fr/personnes")).to include(controller: "people", action: "index", locale: "fr-FR")
        expect(recognize("http://example.fr/personnes/archives")).to include(controller: "people", action: "index", locale: "fr-FR")
        expect(recognize("http://example.ch/de-ch/leute")).to include(controller: "people", action: "index", locale: "de-CH")
        expect(recognize("http://example.ch/de-ch/leute/archiv")).to include(controller: "people", action: "index", locale: "de-CH")
        expect(helpers.people_path(locale: "de-CH")).to eq("/de-ch/leute/archiv")
      end

      it "keeps an optional scope, after the locale prefix" do
        draw_localized do
          scope "(/archive)" do
            get "comments", to: "comments#index", as: :comments
          end
        end

        expect(recognize("http://example.fr/commentaires")).to include(controller: "comments", action: "index", locale: "fr-FR")
        expect(recognize("http://example.fr/archives/commentaires")).to include(controller: "comments", locale: "fr-FR")
        expect(recognize("http://example.ch/de-ch/kommentare")).to include(controller: "comments", locale: "de-CH")
        expect(recognize("http://example.ch/de-ch/archiv/kommentare")).to include(controller: "comments", locale: "de-CH")
        expect(recognize("http://example.ch/archiv/de-ch/kommentare")).to be_nil
        expect(helpers.comments_path(locale: "de-CH")).to eq("/de-ch/archiv/kommentare")
      end

      it "keeps the percent-encoded characters of an untranslated word" do
        draw_localized { get "café", to: "pages#cafe", as: :cafe }

        expect(recognize("http://example.fr/caf%C3%A9")).to include(controller: "pages", action: "cafe", locale: "fr-FR")
        expect(recognize("http://example.ch/it-ch/caf%C3%A9")).to include(controller: "pages", action: "cafe", locale: "it-CH")
        expect(recognize("http://example.fr/caf")).to be_nil
        expect(helpers.cafe_path(locale: "fr-FR")).to eq("/caf%C3%A9")
      end
    end

    context "with a segment that does not start with a translatable word" do
      it "keeps a percent-encoded segment as written" do
        draw_localized { get "über-uns", to: "pages#imprint", as: :imprint }

        expect(recognize("http://example.fr/%C3%BCber-uns")).to include(controller: "pages", action: "imprint", locale: "fr-FR")
        expect(recognize("http://example.ch/fr-ch/%C3%BCber-uns")).to include(controller: "pages", action: "imprint", locale: "fr-CH")
        expect(helpers.imprint_path(locale: "de-CH")).to eq("/de-ch/%C3%BCber-uns")
      end

      it "keeps a segment starting with a symbol as written and translates the others" do
        draw_localized { get "people/@me", to: "people#me", as: :me }

        expect(recognize("http://example.fr/personnes/@me")).to include(controller: "people", action: "me", locale: "fr-FR")
        expect(recognize("http://example.ch/de-ch/leute/@me")).to include(controller: "people", action: "me", locale: "de-CH")
        expect(helpers.me_path(locale: "it-CH")).to eq("/it-ch/persone/@me")
      end
    end

    context "with a key naming a group of translations" do
      # The people controller has translations of its own: "people" is also
      # the key of a group of translations under routes.controllers.
      before { I18n.backend.store_translations(:"fr-FR", routes: {controllers: {people: {archive: "historique"}}}) }

      it "translates the path of a redirect with the global translations" do
        draw_localized { get "people/archive", to: redirect("/personnes") }

        expect(response_head("http://example.fr/personnes/archives")).to eq([301, "http://example.fr/personnes"])
        expect(response_head("http://example.ch/de-ch/leute/archiv")).to eq([301, "http://example.ch/personnes"])
      end

      it "translates the path of a Rack application with the global translations" do
        export = shop_app
        draw_localized { get "people/export", to: export, as: :people_export }

        expect(recognize("http://example.fr/personnes/export")).to eq(script_name: "", path_info: "/personnes/export")
        expect(helpers.people_export_path(locale: "fr-FR")).to eq("/personnes/export")
      end

      it "still translates the routes of the controller with its own translations" do
        draw_localized do
          get "people/archive", to: "people#archive", as: :people_archive
          get "people/archive/old", to: redirect("/personnes/historique")
        end

        expect(recognize("http://example.fr/personnes/historique")).to include(controller: "people", action: "archive", locale: "fr-FR")
        expect(response_head("http://example.fr/personnes/archives/old")).to eq([301, "http://example.fr/personnes/historique"])
      end

      it "leaves a segment naming a group of translations untranslated" do
        draw_localized { get "controllers", to: "pages#controllers", as: :controllers_page }

        expect(recognize("http://example.fr/controllers")).to include(controller: "pages", action: "controllers", locale: "fr-FR")
        expect(helpers.controllers_page_path(locale: "fr-FR")).to eq("/controllers")
      end
    end
  end
end
