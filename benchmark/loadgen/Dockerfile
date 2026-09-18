# Load generator container - wrk (with Lua scripting) + curl (readiness poll).
# Containerizing the load generator too (not just the targets) means the only
# host requirement for the whole benchmark is Docker - nothing else to
# install, on Windows+Docker or Linux+Docker alike.
FROM debian:12-slim AS build
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      git build-essential libssl-dev zlib1g-dev ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/wg/wrk.git /wrk
WORKDIR /wrk
RUN make -j"$(nproc)"

FROM debian:12-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libssl3 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /wrk/wrk /usr/local/bin/wrk
COPY bench.lua /bench.lua
ENTRYPOINT ["wrk"]
