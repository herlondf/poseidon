# Rails itself is generated fresh via `rails new` (gem resolved from
# RubyGems at build time) - nothing framework-related is vendored into this
# repo, only bench_controller.rb/routes.rb/large.json, copied into the
# generated --api skeleton to wire up the three endpoints. Served by Puma,
# Rails' own default app server since Rails 5 - not a separate choice.
FROM ruby:3.3-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential git >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN gem install rails --no-document
RUN rails new . --api --skip-active-record --skip-test --skip-bundle --skip-git
RUN bundle install
COPY routes.rb config/routes.rb
COPY bench_controller.rb app/controllers/bench_controller.rb
COPY large.json ./large.json
ENV RAILS_ENV=production
RUN echo "SECRET_KEY_BASE=$(bin/rails secret)" >> .env.production
EXPOSE 8080
CMD ["sh", "-c", "export $(cat .env.production) && bin/rails server -p 8080 -b 0.0.0.0"]
