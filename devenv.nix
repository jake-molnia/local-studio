{ lib, pkgs, ... }:

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
  agentRuntimePort = 8081;
  frontendPort = 3100;
  controllerUrl = "http://127.0.0.1:${toString controllerPort}";
  agentRuntimeUrl = "http://127.0.0.1:${toString agentRuntimePort}";
  frontendUrl = "http://127.0.0.1:${toString frontendPort}";
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
      "services/agent-runtime/package.json"
      "services/agent-runtime/bun.lock"
      "shared/package.json"
      "shared/bun.lock"
    ];
    before = [
      "devenv:enterShell"
      "devenv:processes:head-node"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
      "devenv:processes:agent-runtime"
      "devenv:processes:frontend"
      "devenv:processes:electron"
    ];
  };

  processes.head-node = {
    cwd = "./controller";
    exec = ''
      if ! ${lib.getExe pkgs.python311} -c 'import socket; connection = socket.socket(); connection.bind(("127.0.0.1", ${toString controllerPort})); connection.close()' 2>/dev/null; then
        echo "Port ${toString controllerPort} is already in use" >&2
        exit 1
      fi
      exec bun run dev
    '';
    env.LOCAL_STUDIO_PORT = toString controllerPort;
    restart.on = "never";
    ready = {
      exec = "${lib.getExe pkgs.curl} --fail --silent --output /dev/null ${controllerUrl}/health";
      period = 1;
      timeout = 120;
    };
  };

  processes.agent-runtime = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    cwd = "./services/agent-runtime";
    exec = ''
      if ! ${lib.getExe pkgs.python311} -c 'import socket; connection = socket.socket(); connection.bind(("127.0.0.1", ${toString agentRuntimePort})); connection.close()' 2>/dev/null; then
        echo "Port ${toString agentRuntimePort} is already in use" >&2
        exit 1
      fi
      exec bun --watch src/server.ts
    '';
    after = [ "devenv:processes:head-node@ready" ];
    env = {
      PORT = toString agentRuntimePort;
      LOCAL_STUDIO_FRONTEND_BASE = frontendUrl;
    };
    restart.on = "never";
    ready = {
      exec = "${lib.getExe pkgs.curl} --fail --silent --output /dev/null ${agentRuntimeUrl}/health";
      period = 1;
      timeout = 120;
    };
  };

  processes.frontend = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    cwd = "./frontend";
    exec = ''
      if ! ${lib.getExe pkgs.python311} -c 'import socket; connection = socket.socket(); connection.bind(("127.0.0.1", ${toString frontendPort})); connection.close()' 2>/dev/null; then
        echo "Port ${toString frontendPort} is already in use" >&2
        exit 1
      fi
      exec ./node_modules/.bin/next dev -p ${toString frontendPort}
    '';
    after = [
      "devenv:processes:head-node@ready"
      "devenv:processes:agent-runtime@ready"
    ];
    env = {
      BACKEND_URL = controllerUrl;
      NEXT_PUBLIC_BACKEND_URL = controllerUrl;
      LOCAL_STUDIO_BACKEND_URL = controllerUrl;
      LOCAL_STUDIO_AGENT_RUNTIME_URL = agentRuntimeUrl;
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
    env.LOCAL_STUDIO_DESKTOP_DEV_SERVER_URL = frontendUrl;
    restart.on = "never";
  };
}
