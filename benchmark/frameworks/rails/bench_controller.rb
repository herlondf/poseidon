# Minimal Rails contender for the framework comparison: serves the three
# TechEmpower-style endpoints, nothing else - same contract as every other
# contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
# keep-alive). This file is copied into a Rails API-only skeleton generated
# fresh at image-build time by `rails new` (see Dockerfile), served by Puma -
# Rails' own default app server since Rails 5 - only this file, routes.rb and
# large.json are committed to the repo.
class BenchController < ActionController::API
  LARGE_JSON = File.read(Rails.root.join("large.json")).freeze

  def plaintext
    render plain: "Hello, World!"
  end

  def json_small
    render plain: '{"message":"Hello, World!"}', content_type: "application/json"
  end

  def json_large
    render plain: LARGE_JSON, content_type: "application/json"
  end
end
