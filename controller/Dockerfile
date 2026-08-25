FROM node:22-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*

WORKDIR /source
COPY controller ./controller
COPY chat ./chat
COPY contracts ./contracts
RUN node controller/toolchain.mjs build -Doptimize=ReleaseSafe

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git openssh-client && rm -rf /var/lib/apt/lists/* && useradd --uid 1000 --create-home studio

COPY --from=build /source/controller/zig-out/bin/local-studio-controller /usr/local/bin/local-studio-controller

ENV LOCAL_STUDIO_CONTROLLER_MODE=standalone
ENV LOCAL_STUDIO_DATA_DIR=/data
ENV LOCAL_STUDIO_MODELS_DIR=/models

EXPOSE 8080

USER studio
WORKDIR /home/studio

ENTRYPOINT ["local-studio-controller"]
