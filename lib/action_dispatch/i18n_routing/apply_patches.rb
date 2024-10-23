# frozen_string_literal: true

require_relative "patches/mapper"
require_relative "patches/route_set"

ActionDispatch::Routing::Mapper.prepend ActionDispatch::I18nRouting::Patches::Mapper
ActionDispatch::Routing::RouteSet.prepend ActionDispatch::I18nRouting::Patches::RouteSet
