FROM node:22-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*

WORKDIR /source
COPY controller ./controller
COPY contracts ./contracts
RUN node controller/toolchain.mjs build -Doptimize=ReleaseSafe

FROM node:22-bookworm-slim

ARG TARGETARCH
ARG PI_VERSION=0.73.1
ARG CODEX_VERSION=0.150.0
ARG OPENCODE_VERSION=0.0.0-beta-18286
ARG CLAUDE_VERSION=2.1.232
ARG FX_VERSION=0.0.6

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates chromium curl git openssh-client && rm -rf /var/lib/apt/lists/* && useradd --uid 1000 --create-home studio
RUN npm install --global "@mariozechner/pi-coding-agent@${PI_VERSION}" "@openai/codex@${CODEX_VERSION}" && npm cache clean --force
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) package_arch="x64"; fx_arch="x86_64" ;; \
      arm64) package_arch="arm64"; fx_arch="aarch64" ;; \
      *) exit 1 ;; \
    esac; \
    work_dir="$(mktemp -d)"; \
    curl -fsSL "https://registry.npmjs.org/@opencode-ai/cli-linux-${package_arch}/-/cli-linux-${package_arch}-${OPENCODE_VERSION}.tgz" -o "$work_dir/opencode.tgz"; \
    mkdir "$work_dir/opencode"; \
    tar -xzf "$work_dir/opencode.tgz" -C "$work_dir/opencode"; \
    install -m 0755 "$work_dir/opencode/package/bin/opencode2" /usr/local/bin/opencode2; \
    curl -fsSL "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-${package_arch}/-/claude-code-linux-${package_arch}-${CLAUDE_VERSION}.tgz" -o "$work_dir/claude.tgz"; \
    mkdir "$work_dir/claude"; \
    tar -xzf "$work_dir/claude.tgz" -C "$work_dir/claude"; \
    install -m 0755 "$work_dir/claude/package/claude" /usr/local/bin/claude; \
    curl -fsSL "https://releases.fx.sh/v${FX_VERSION}/fx-linux-${fx_arch}.tar.gz" -o "$work_dir/fx.tgz"; \
    tar -xzf "$work_dir/fx.tgz" -C "$work_dir"; \
    install -m 0755 "$work_dir/fx" /usr/local/bin/fx; \
    rm -rf "$work_dir"

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
