{ config, lib, pkgs, ... }:

let
  bunVersion = "1.3.14";
  bunSources = {
    aarch64-darwin = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v${bunVersion}/bun-darwin-aarch64.zip";
      hash = "sha256-2LliIYKK1vl6x6wKt+lYcjQa92MAHogD6CZ2UsJlJiA=";
    };
    aarch64-linux = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v${bunVersion}/bun-linux-aarch64.zip";
      hash = "sha256-on/7Y6gxA3WDbg1vZorhf6jY0YuIw3yCHGUzGXOhmjs=";
    };
    x86_64-linux = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v${bunVersion}/bun-linux-x64.zip";
      hash = "sha256-lR7iruhV8IWVruxiJSJqKY0/6oOj3NZGXAnLzN9+hI8=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  controllerPort = 8082;
  localNodePort = 8083;
  frontendPort = 3100;
  controllerUrl = "http://127.0.0.1:${toString controllerPort}";
  localNodeUrl = "http://127.0.0.1:${toString localNodePort}";
  frontendUrl = "http://127.0.0.1:${toString frontendPort}";
  localStudioState = "${config.devenv.state}/local-studio";
  headDataDir = "${localStudioState}/head";
  frontendDataDir = "${localStudioState}/frontend";
  localNodeDataDir = "${localStudioState}/local-node";
  modelsDir = "${localStudioState}/models";
  desktopUserDataDir = "${localStudioState}/electron";
  zigController = "./controller-zig/zig-out/bin/local-studio-controller";
  portPreflight = ports: ''
    ${lib.getExe pkgs.python311} -c '
    import socket, sys
    ports = [${lib.concatMapStringsSep ", " toString ports}]
    busy = []
    sockets = []
    for port in ports:
        listener = socket.socket()
        try:
            listener.bind(("127.0.0.1", port))
        except OSError:
            busy.append(port)
            listener.close()
        else:
            sockets.append(listener)
    for listener in sockets:
        listener.close()
    if busy:
        print("Local Studio development ports already in use: " + ", ".join(map(str, busy)) + ". Stop the existing dev stack before starting another one.", file=sys.stderr)
        raise SystemExit(1)
    '
  '';
  bun = pkgs.bun.overrideAttrs (previous: {
    version = bunVersion;
    src = bunSources.${system} or (throw "Bun ${bunVersion} is unavailable for ${system}");
    passthru = previous.passthru // {
      sources = bunSources;
    };
  });
in
{
  packages = [
    pkgs.curl
    pkgs.git
  ];

  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    lsp.enable = false;
    npm.enable = true;
    bun = {
      enable = true;
      package = bun;
    };
  };

  languages.python = {
    enable = true;
    package = pkgs.python311;
    lsp.enable = false;
    uv.enable = true;
  };

  tasks."local-studio:setup" = {
    exec = "npm run setup";
    execIfModified = [
      "package.json"
      "controller/package.json"
      "controller/bun.lock"
      "controller/contracts/package.json"
      "frontend/package.json"
      "frontend/package-lock.json"
      "shared/package.json"
      "shared/bun.lock"
    ];
    before = [
      "devenv:enterShell"
      "devenv:processes:head-node"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      "devenv:processes:local-node"
      "devenv:processes:frontend"
      "devenv:processes:electron"
    ];
  };

  processes.head-node = {
    exec = ''
      ${portPreflight [ controllerPort ]}
      node controller-zig/toolchain.mjs build
      exec ${zigController} --mode head --host 127.0.0.1 --port ${toString controllerPort}
    '';
    env = {
      LOCAL_STUDIO_CONTROLLER_MODE = "head";
      LOCAL_STUDIO_DATA_DIR = headDataDir;
      LOCAL_STUDIO_MODELS_DIR = modelsDir;
      LOCAL_STUDIO_PORT = toString controllerPort;
    };
    restart.on = "never";
    ready = {
      exec = "${lib.getExe pkgs.curl} --fail --silent --output /dev/null ${controllerUrl}/health";
      period = 1;
      timeout = 120;
    };
  };

  processes.local-node = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    exec = ''
      set -eu
      ${portPreflight [ localNodePort ]}
      ${zigController} --mode worker --host 127.0.0.1 --port ${toString localNodePort} &
      local_node_pid=$!
      stop_local_node() {
        kill -TERM "$local_node_pid" 2>/dev/null || true
      }
      trap stop_local_node INT TERM EXIT
      until ${lib.getExe pkgs.curl} --fail --silent --output /dev/null ${localNodeUrl}/health; do
        if ! kill -0 "$local_node_pid" 2>/dev/null; then
          wait "$local_node_pid"
          exit $?
        fi
        sleep 0.2
      done
      ${lib.getExe pkgs.curl} --fail --silent --output /dev/null \
        --request PUT \
        --header 'Content-Type: application/json' \
        --data '{"name":"Devenv Head","url":"${controllerUrl}","apiKey":"local-studio","nodeAddress":"${localNodeUrl}","nodeApiKey":"local-studio"}' \
        ${localNodeUrl}/api/agent/head-connection
      wait "$local_node_pid"
      local_node_status=$?
      trap - INT TERM EXIT
      exit "$local_node_status"
    '';
    after = [ "devenv:processes:head-node@ready" ];
    env = {
      LOCAL_STUDIO_CONTROLLER_MODE = "worker";
      LOCAL_STUDIO_DATA_DIR = localNodeDataDir;
      LOCAL_STUDIO_FRONTEND_BASE = frontendUrl;
      LOCAL_STUDIO_MODELS_DIR = modelsDir;
      LOCAL_STUDIO_PI_BIN = "./frontend/node_modules/.bin/pi";
      LOCAL_STUDIO_PORT = toString localNodePort;
    };
    restart.on = "never";
    ready = {
      exec = "${lib.getExe pkgs.curl} --fail --silent ${localNodeUrl}/api/agent/head-connection | ${lib.getExe pkgs.python311} -c 'import json, sys; payload = json.load(sys.stdin); raise SystemExit(0 if payload.get(\"connected\") and payload.get(\"url\") == \"${controllerUrl}\" else 1)'";
      period = 1;
      timeout = 120;
    };
  };

  processes.frontend = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    cwd = "./frontend";
    exec = ''
      ${portPreflight [ frontendPort ]}
      exec ./node_modules/.bin/next dev -p ${toString frontendPort}
    '';
    after = [
      "devenv:processes:head-node@ready"
      "devenv:processes:local-node@ready"
    ];
    env = {
      BACKEND_URL = localNodeUrl;
      LOCAL_STUDIO_BACKEND_URL = localNodeUrl;
      LOCAL_STUDIO_DATA_DIR = frontendDataDir;
      LOCAL_STUDIO_DISABLE_LEGACY_SETTINGS_MIGRATION = "1";
      LOCAL_STUDIO_CONTROLLER_URL = controllerUrl;
      LOCAL_STUDIO_PROXY_OVERRIDE_ALLOWLIST = "${localNodeUrl},${controllerUrl}";
      NEXT_PUBLIC_BACKEND_URL = localNodeUrl;
      NEXT_PUBLIC_LOCAL_STUDIO_CONTROLLER_URL = localNodeUrl;
      NEXT_PUBLIC_LOCAL_STUDIO_HEAD_URL = controllerUrl;
      NEXT_DIST_DIR = ".next-dev";
    };
    restart.on = "never";
    ready = {
      exec = "${lib.getExe pkgs.curl} --fail --silent --output /dev/null ${frontendUrl}/";
      initial_delay = 2;
      period = 1;
      timeout = 120;
    };
  };

  processes.electron = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    exec = ''
      npm --prefix frontend run desktop:build:main
      exec npm --prefix frontend run desktop:start
    '';
    after = [ "devenv:processes:frontend@ready" ];
    env = {
      LOCAL_STUDIO_DESKTOP_APP_NAME = "Local Studio Devenv";
      LOCAL_STUDIO_DESKTOP_CONTROLLER_PORT = toString localNodePort;
      LOCAL_STUDIO_DESKTOP_DEV_SERVER_URL = frontendUrl;
      LOCAL_STUDIO_DESKTOP_USER_DATA_DIR = desktopUserDataDir;
    };
    restart.on = "never";
  };
}
