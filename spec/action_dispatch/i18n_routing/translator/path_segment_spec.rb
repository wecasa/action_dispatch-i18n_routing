# frozen_string_literal: true

RSpec.describe ActionDispatch::I18nRouting::Translator::PathSegment do
  describe ".translate" do
    # NOTE: .translate strips a trailing "(" from its argument in place
    # (String#slice!), so it needs a mutable String. Every example below goes
    # through #translate, which hands it an unfrozen copy.
    def translate(segment, locale = :fr, scope = people_scope)
      described_class.translate(segment.dup, locale, scope)
    end

    let(:people_scope) { [:routes, :controllers, "people"] }

    before do
      I18n.available_locales = %i[en fr de]

      I18n.backend.store_translations(
        :fr,
        routes: {
          people: "personnes",
          about: "à propos",
          search: "recherche avancée",
          slug: "titre",
          "my-page_2": "ma-page",
          "2024": "deux-mille-vingt-quatre",
          id: "identifiant",
          path: "chemin",
          format: "forme",
          archive: "archives",
          foo: "truc",
          team: "l'équipe",
          controllers: {
            people: {people: "gens", new: "nouveau"},
            "admin/people": {people: "membres"}
          }
        }
      )
      I18n.backend.store_translations(:de, routes: {people: "leute", about: "über"})
    end

    it "returns an empty segment as is" do
      expect(translate("")).to eq("")
    end

    context "with a controller scope" do
      it "prefers the controller-scoped translation over the :routes one" do
        expect(translate("people")).to eq("gens")
      end

      it "uses a translation that only exists in the controller scope" do
        expect(translate("new")).to eq("nouveau")
      end

      it "does not use another controller's translations" do
        expect(translate("new", :fr, [:routes, :controllers, "pages"])).to eq("new")
      end

      it "looks up namespaced controllers by their full path" do
        expect(translate("people", :fr, [:routes, :controllers, "admin/people"])).to eq("membres")
      end
    end

    context "when the controller scope has no translation" do
      it "falls back to the :routes scope" do
        expect(translate("about")).to eq("%C3%A0%20propos")
      end

      it "falls back to the :routes scope for an unknown controller" do
        expect(translate("people", :fr, [:routes, :controllers, "pages"])).to eq("personnes")
      end
    end

    context "when there is no translation at all" do
      it "returns the segment unchanged" do
        expect(translate("unknown")).to eq("unknown")
      end

      it "returns the segment unchanged for a locale without any route translations" do
        expect(translate("people", :en)).to eq("people")
      end

      it "does not return an I18n 'translation missing' placeholder" do
        expect(translate("unknown")).not_to match(/translation missing/i)
      end
    end

    it "accepts a plain :routes scope" do
      expect(translate("people", :fr, :routes)).to eq("personnes")
    end

    it "translates into the requested locale" do
      expect([translate("people", :fr, :routes), translate("people", :de, :routes)])
        .to eq(%w[personnes leute])
    end

    it "accepts the locale as a String as well as a Symbol" do
      expect([translate("people", "de"), translate("people", :de)]).to eq(%w[leute leute])
    end

    it "does not depend on the current I18n.locale" do
      I18n.locale = :de

      expect(translate("people", :fr)).to eq("gens")
    end

    it "translates words made of letters, digits, hyphens and underscores" do
      expect([translate("my-page_2"), translate("2024")]).to eq(%w[ma-page deux-mille-vingt-quatre])
    end

    describe "segments that are not translated" do
      {
        ":id" => "a named param",
        "*path" => "a glob",
        "(" => "a lone opening parenthesis",
        "(.:format)" => "an optional format",
        "(archive" => "an optional group start",
        "foo:bar" => "a segment containing a param",
        ":format)" => "a param closing an optional group"
      }.each do |segment, description|
        it "leaves #{description} (#{segment.inspect}) untouched" do
          expect(translate(segment)).to eq(segment)
        end
      end
    end

    describe "named params with a hyphenated suffix" do
      it "translates the suffix and keeps the param" do
        expect(translate(":id-slug")).to eq(":id-titre")
      end

      it "looks the suffix up in the controller scope first" do
        expect(translate(":id-new")).to eq(":id-nouveau")
      end

      it "keeps an untranslated suffix as is" do
        expect(translate(":id-unknown")).to eq(":id-unknown")
      end

      it "translates the whole remainder after the first hyphen as one word" do
        expect(translate(":id-my-page_2")).to eq(":id-ma-page")
      end

      it "keeps a trailing opening parenthesis after a translated suffix" do
        expect(translate(":id-slug(")).to eq(":id-titre(")
      end

      it "leaves a second param in the suffix untouched" do
        expect(translate(":id-:slug")).to eq(":id-:slug")
      end

      it "leaves a param with an empty suffix untouched" do
        expect(translate(":id-")).to eq(":id-")
      end
    end

    describe "a trailing opening parenthesis" do
      it "is kept after a translated word" do
        expect(translate("people(")).to eq("gens(")
      end

      it "is kept after a word that falls back to the :routes scope" do
        expect(translate("about(")).to eq("%C3%A0%20propos(")
      end

      it "is kept after an untranslated word" do
        expect(translate("unknown(")).to eq("unknown(")
      end

      it "is kept after a hyphenated word" do
        expect(translate("my-page_2(")).to eq("ma-page(")
      end
    end

    describe "URI escaping of translations" do
      it "percent-encodes non-ASCII characters" do
        expect(translate("about", :de)).to eq("%C3%BCber")
      end

      it "percent-encodes spaces and accented characters" do
        expect(translate("search")).to eq("recherche%20avanc%C3%A9e")
      end

      it "leaves plain ASCII translations as they are" do
        expect(translate("people")).to eq("gens")
      end

      # Same escaping as Rails applies to a literal route path
      # (URI::DEFAULT_PARSER.escape in Mapper#add_route).
      it "keeps characters that Rails keeps in literal route paths, such as an apostrophe" do
        expect(translate("team")).to eq("l'%C3%A9quipe")
      end
    end
  end
end
