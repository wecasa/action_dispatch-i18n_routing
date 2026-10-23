# frozen_string_literal: true

RSpec.describe ActionDispatch::I18nRouting do
  describe "VERSION" do
    it "is a valid gem version string" do
      expect(Gem::Version.correct?(described_class::VERSION)).to be(true)
    end

    it "follows MAJOR.MINOR.PATCH" do
      expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe "Error" do
    it "inherits directly from StandardError, so a bare rescue catches it" do
      expect(described_class::Error.superclass).to eq(StandardError)
    end
  end

  describe "config.available_locales_per_host" do
    it "defaults to an empty hash" do
      expect(described_class.settings[:available_locales_per_host].default).to eq({})
    end

    it "can be assigned a hash of host => locales, keeping each host's locale order" do
      described_class.config.available_locales_per_host = {"x.fr" => [:"fr-FR"], "x.ch" => [:"fr-CH", :"de-CH", :"it-CH"]}

      expect(described_class.config.available_locales_per_host)
        .to eq("x.fr" => [:"fr-FR"], "x.ch" => [:"fr-CH", :"de-CH", :"it-CH"])
    end

    it "can be set through a configure block" do
      described_class.configure do |config|
        config.available_locales_per_host = {"x.co.uk" => [:"en-GB"]}
      end

      expect(described_class.config.available_locales_per_host).to eq("x.co.uk" => [:"en-GB"])
    end
  end

  describe "TRANSLATABLE_SEGMENT" do
    subject(:regex) { described_class::TRANSLATABLE_SEGMENT }

    {
      "people" => "people",
      "PEOPLE" => "PEOPLE",
      "my-page_2" => "my-page_2",
      "2024" => "2024",
      "-" => "-",
      "_" => "_"
    }.each do |segment, word|
      it "captures #{segment.inspect} as the translatable word" do
        match = regex.match(segment)

        expect(match.captures).to eq([word, nil])
      end
    end

    it "captures the word and the opening parenthesis of an optional group" do
      expect(regex.match("people(").captures).to eq(["people", "("])
    end

    it "captures a word containing hyphens, underscores and digits before a parenthesis" do
      expect(regex.match("my-page_2(").captures).to eq(["my-page_2", "("])
    end

    it "captures only the word in front of an optional format" do
      expect(regex.match("people(.:format)").captures).to eq(["people", "("])
    end

    ["", ":id", "*path", "(", "(.:format)", ".:format", ".json", "über", "%C3%BCber", " people"].each do |segment|
      it "does not match #{segment.inspect}" do
        expect(regex.match(segment)).to be_nil
      end
    end
  end

  describe "OPTIONAL_FORMAT_REGEX" do
    subject(:regex) { described_class::OPTIONAL_FORMAT_REGEX }

    {
      "(.:format)" => "(.:format)",
      ".:format" => ".:format",
      "/a(.:format)" => "(.:format)",
      "/people.:format" => ".:format",
      "/people/:id(.:format)" => "(.:format)",
      "/people(/:id)(.:format)" => "(.:format)",
      "/people(/archive(.:format))" => "(.:format))"
    }.each do |path, format|
      it "matches the trailing #{format.inspect} of #{path.inspect}" do
        expect(path[regex]).to eq(format)
      end
    end

    ["/people", "/people(.:locale)", "/a(.:format)/b", "/a.:format/b", "/people.json", ":format", ""].each do |path|
      it "does not match #{path.inspect}" do
        expect(regex.match(path)).to be_nil
      end
    end

    # Rails' own Mapping::OPTIONAL_FORMAT_REGEX also matches a trailing "/".
    # Here the "/" of a root path must stay part of the path, not the format.
    it "does not take the slash of a root path for a format" do
      expect(regex.match("/")).to be_nil
    end

    it "only strips the format at the end of a path" do
      path = +"/people(/:id)(.:format)"

      path.slice!(regex)

      expect(path).to eq("/people(/:id)")
    end
  end

  describe "patches" do
    it "prepends the Mapper patch ahead of ActionDispatch::Routing::Mapper" do
      ancestors = ActionDispatch::Routing::Mapper.ancestors

      expect(ancestors).to include(described_class::Patches::Mapper)
      expect(ancestors.index(described_class::Patches::Mapper))
        .to be < ancestors.index(ActionDispatch::Routing::Mapper)
    end

    it "prepends the RouteSet patch ahead of ActionDispatch::Routing::RouteSet" do
      ancestors = ActionDispatch::Routing::RouteSet.ancestors

      expect(ancestors).to include(described_class::Patches::RouteSet)
      expect(ancestors.index(described_class::Patches::RouteSet))
        .to be < ancestors.index(ActionDispatch::Routing::RouteSet)
    end

    it "makes the patched Mapper#add_route take precedence over Rails' own" do
      expect(ActionDispatch::Routing::Mapper.instance_method(:add_route).owner)
        .to eq(described_class::Patches::Mapper)
    end

    it "makes the patched Mapper#define_generate_prefix take precedence over Rails' own" do
      expect(ActionDispatch::Routing::Mapper.instance_method(:define_generate_prefix).owner)
        .to eq(described_class::Patches::Mapper)
    end

    it "exposes the localized DSL method on route mappers" do
      expect(ActionDispatch::Routing::Mapper.public_method_defined?(:localized)).to be(true)
    end

    it "exposes add_localized_route on route sets" do
      expect(ActionDispatch::Routing::RouteSet.new).to respond_to(:add_localized_route)
    end

    context "when drawing routes" do
      let(:route_set) { ActionDispatch::Routing::RouteSet.new }

      def drawn_routes
        route_set.routes.map do |route|
          [route.name, route.path.spec.to_s, route.defaults[:locale], route.constraints[:host]]
        end
      end

      before do
        I18n.available_locales = [:"fr-FR", :en]
        I18n.backend.store_translations(:"fr-FR", routes: {people: "personnes", pages: "pages-fr"})
        described_class.config.available_locales_per_host = {"x.fr" => [:"fr-FR"]}
      end

      it "localizes routes drawn inside a localized block" do
        route_set.draw { localized { get "people", to: "people#index", as: :people } }

        expect(drawn_routes).to eq([["people_fr_fr", "/personnes(.:format)", "fr-FR", "x.fr"]])
      end

      it "leaves routes drawn outside a localized block untouched" do
        route_set.draw { get "people", to: "people#index", as: :people }

        expect(drawn_routes).to eq([["people", "/people(.:format)", nil, nil]])
      end

      it "stops localizing routes once the localized block is over" do
        route_set.draw do
          localized { get "people", to: "people#index", as: :people }
          get "pages", to: "pages#index", as: :pages
        end

        expect(drawn_routes).to eq(
          [
            ["people_fr_fr", "/personnes(.:format)", "fr-FR", "x.fr"],
            ["pages", "/pages(.:format)", nil, nil]
          ]
        )
      end
    end
  end
end
