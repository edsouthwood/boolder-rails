source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby "3.3.5"

gem "rails", "~> 8.1.0"
# Security-patched 7.2 line; move to 8.x as its own upgrade
gem "puma", "~> 7.2", ">= 7.2.1"
gem "pg"
gem "pg_search"
gem "activerecord-postgis-adapter", "~> 11.1"
gem "aws-sdk-s3"
gem "image_processing", "~> 1.2"
gem "propshaft"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails", "~> 3.3.1" # pin to tailwindcss 3.3.1 (weird bug with 4.0 on my machine: https://github.com/tailwindlabs/tailwindcss/issues/17728#issuecomment-2884340873)
gem "bcrypt", "~> 3.1.7"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "solid_cache"
gem "solid_cable"
gem "solid_queue"
gem "mission_control-jobs"

gem "bootsnap", require: false
gem "kamal", require: false
gem "thruster", require: false

gem "bugsnag"
gem "kaminari"
gem "httparty"
gem "colorize"
gem "audited"
gem "ostruct" # TODO: remove
gem "rgeo-geojson", "~> 2.1.1" # TODO: update
gem "differ"
gem "breadcrumbs_on_rails"
gem "meta-tags"
gem "sitemap_generator"
gem "rack-attack"
# Patched 2.x; json 3 is a major upgrade to take separately
gem "json", "~> 2.19", ">= 2.19.9"
gem "invisible_captcha"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  gem "bundler-audit", require: false
  gem "rubocop-rails-omakase", require: false
  gem "pry"
  gem "dotenv-rails"
end

group :development do
  gem "web-console"
  gem "nokogiri"
  gem "sqlite3", ">= 2.1"
end

group :test do
  gem "capybara"
end
