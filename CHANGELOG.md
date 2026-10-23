## [Unreleased]

- **Breaking:** a duplicate explicit `as:` inside `localized` raises `ArgumentError`, like Rails does outside `localized` (it silently left the route unnamed)
- **Breaking:** a locale configured for several hosts, or twice for one host, raises `ActionDispatch::I18nRouting::Error` when routes are drawn (its routes could not be named nor generated)
- Fix translated path segments losing every character after the leading word (`get "page(s)"` gave `/fiche`, `get "people(/archive)"` raised "missing right parenthesis")
- Fix crashes on path segments starting with a character such as `ü`, `~`, `@` or `+`, and on translation lookups returning a subtree (redirects or Rack apps under a controller's path)
- Fix route-level `constraints:` given as a lambda or a `matches?` object raising `NoMethodError` inside `localized`
- Fix a nested `localized` block turning localization off for the rest of the outer block
- Fix root-level optional segments on multi-locale hosts: `/de-ch(/:page)` instead of `/de-ch/(:page)` (so `/de-ch` is recognized)
- Engines mounted inside `localized` generate their own URLs under the mount point of `I18n.locale` (they always used the last locale's)
- Register the locale-dispatching `<name>_path` / `<name>_url` helpers like Rails' named route helpers (`helper_names`, `route_defined?`, removed on redraw), and define none for unnamed routes
- `PathSegment.translate` no longer modifies its argument

## [0.2.0] - 2026-10-23

- Support Rails 8.1: follow the new `Mapper#add_route` and `Mapping.build` signatures (`as` and `internal` arguments)
- Require actionpack and activesupport >= 8.1

## [0.1.0] - 2024-10-23

- Initial release
