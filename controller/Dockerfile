FROM node:22-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*

WORKDIR /source
COPY controller ./controller
COPY contracts ./contracts
RUN node controller/toolchain.mjs build -Doptimize=ReleaseSafe

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates chromium git openssh-client && rm -rf /var/lib/apt/lists/* && useradd --uid 1000 --create-home studio

COPY --from=build /source/controller/zig-out/bin/local-studio-controller /usr/local/bin/local-studio-controller
COPY --from=build /source/controller/zig-out/bin/secretspec /usr/local/bin/secretspec

ENV LOCAL_STUDIO_CONTROLLER_MODE=standalone
ENV LOCAL_STUDIO_DATA_DIR=/data
ENV LOCAL_STUDIO_MODELS_DIR=/models
ENV LOCAL_STUDIO_BUNDLED_CHROMIUM_PATH=/usr/bin/chromium

EXPOSE 8080

USER studio
WORKDIR /home/studio

ENTRYPOINT ["local-studio-controller"]
