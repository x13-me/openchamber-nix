# OpenChamber flake helpers, written in nixdoc style (`/** ... */`).
#
# Extensible via `lib.extend` / `makeExtensible`:
#
# ```nix
# myLib = openchamberLib.extend (final: prev: { myHelper = ...; });
# ```
{ lib }:
lib.makeExtensible (_final: {
  /**
    Nix systems this flake builds for.

    Single source of truth: `nix/default.nix` derives `forAllSystems`
    from this list, and package `meta.platforms` mirrors it.
  */
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  /**
    Map a Nix system to the upstream OpenChamber AppImage arch naming.

    Upstream uses `x86_64` / `arm64` (NOT `aarch64`).

    # Arguments

    - `versions`: the parsed contents of `versions.nix`
      (`systems.<system>.arch`).
    - `system`: e.g. `"x86_64-linux"`.

    Fails fast on unknown systems so a bad matrix entry errors at
    evaluation time, not mid-build.

    # Example

    ```nix
    archOf versions "aarch64-linux" # => "arm64"
    ```
  */
  archOf =
    versions: system:
    versions.systems.${system}.arch or (throw "openchamber-nix: no arch mapping for system ${system}");

  /**
    Standard writable state directory option for `services.openchamber`.

    Backs the systemd `WorkingDirectory` / `ReadWritePaths` wiring and,
    for the default `openchamber` system user, the forced `HOME` / XDG /
    `OPENCHAMBER_DATA_DIR` paths. Personal-user instances (custom `user`)
    inherit the login user's `HOME` instead and ignore this for data
    resolution.

    # Arguments

    - `default`: state directory (defaults to `"/var/lib/openchamber"`).
  */
  mkDataDirOption =
    {
      default ? "/var/lib/openchamber",
    }:
    lib.mkOption {
      type = lib.types.path;
      inherit default;
      description = ''
        Writable state directory for the service (systemd WorkingDirectory
        and ReadWritePaths).

        When running as the default `openchamber` system user, this is also
        the base for the forced HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
        XDG_STATE_HOME, XDG_CACHE_HOME, and OPENCHAMBER_DATA_DIR environment
        (`<dataDir>/.config/openchamber`). When `user` points at an existing
        login account, HOME/XDG are inherited from that account instead, so
        personal-user instances keep using `~/.config/openchamber` etc.
      '';
    };

  /**
    Standard UI bind host option for `services.openchamber`.

    # Arguments

    - `default`: bind address (defaults to `"127.0.0.1"`).
  */
  mkHostOption =
    {
      default ? "127.0.0.1",
    }:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "Host for the web UI to bind to.";
    };

  /**
    Standard UI listen port option for `services.openchamber`.

    # Arguments

    - `default`: TCP port (defaults to `3000`).
  */
  mkPortOption =
    {
      default ? 3000,
    }:
    lib.mkOption {
      type = lib.types.port;
      inherit default;
      description = "Port for the web UI to listen on.";
    };

  /**
    Standard UI password-file option for `services.openchamber`.

    The file is staged via `LoadCredential` so the service never needs
    direct read access to the raw host path; it is never copied into the store.

    # Arguments

    - `default`: path or `null` (defaults to `null`, i.e. no password).
  */
  mkPasswordFileOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      inherit default;
      description = "File containing the UI password (passed as OPENCHAMBER_UI_PASSWORD_FILE).";
    };

  /**
    Standard flag allowing unauthenticated LAN binds for `services.openchamber`.

    Mirrors upstream `OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN=true` (the escape
    hatch for `assertAuthenticatedNetworkExposure`: a network-exposed bind
    without a UI password throws `AUTH_CONFIG_ERROR` unless this is set).
    Prefer `uiPasswordFile`; enable this only to consciously accept the risk.

    # Arguments

    - `default`: allow unauthenticated LAN exposure (defaults to `false`).
  */
  mkAllowUnauthenticatedLanOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = ''
        Allow the server to bind a network-reachable address without UI
        password authentication (sets OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN=true).

        Upstream refuses such binds by default — prefer `uiPasswordFile`.
      '';
    };

  /**
    Standard managed-chat worktree directory option for `services.openchamber`.

    Relocates managed chat worktrees (`OPENCHAMBER_CHATS_DIR`); unset means
    upstream keeps them under the data directory (`<dataDir>/chats`).

    # Arguments

    - `default`: path or `null` (defaults to `null`, i.e. unset).
  */
  mkChatsDirOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      inherit default;
      description = "Directory for managed chat worktrees (passed as OPENCHAMBER_CHATS_DIR).";
    };

  /**
    Standard LAN-bind shortcut option for `services.openchamber`.

    Mirrors upstream `openchamber serve --lan`: when no explicit `host` is
    given, the CLI binds `0.0.0.0` instead of loopback. Upstream then
    requires UI password authentication for the network-exposed bind (see
    `allowUnauthenticatedLan`).

    # Arguments

    - `default`: bind all interfaces when `host` is at its default (defaults to `false`).
  */
  mkLanOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = ''
        Bind all interfaces (`0.0.0.0`) when `host` is left at its loopback
        default — the Nix equivalent of `openchamber serve --lan` (the flag
        is also passed on the command line; `--host` always carries the
        effective address).

        A network-exposed bind requires `uiPasswordFile` (or
        `allowUnauthenticatedLan`) — evaluation fails fast otherwise,
        mirroring upstream's refusal to serve LAN without UI auth.
      '';
    };

  /**
    Standard external OpenCode server URL option for `services.openchamber`.

    Points the server at an already-running OpenCode instance
    (`OPENCODE_HOST`, e.g. `http://hostname:4096`) instead of its managed
    one. Takes precedence over `opencodePort` when both are set (upstream
    `resolveOpenCodeEnvConfig`); combine with `skipOpencodeStart` to stop
    the server from spawning its own OpenCode process.

    # Arguments

    - `default`: URL or `null` (defaults to `null`, i.e. managed OpenCode).
  */
  mkOpencodeHostOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      inherit default;
      example = "http://hostname:4096";
      description = ''
        Base URL of an external OpenCode server to use (passed as
        OPENCODE_HOST). Must use an http(s) scheme with an explicit port
        and no path/query/hash — upstream ignores (with a warning) anything
        else.
      '';
    };

  /**
    Standard managed-OpenCode bind hostname option for `services.openchamber`.

    Bind hostname for the OpenCode server this service manages
    (`OPENCHAMBER_OPENCODE_HOSTNAME`, upstream default `127.0.0.1`).
    Upstream falls back to loopback (with an error log) when given an
    invalid hostname or IP.

    # Arguments

    - `default`: bind hostname (defaults to `"127.0.0.1"`).
  */
  mkOpencodeHostnameOption =
    {
      default ? "127.0.0.1",
    }:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "Bind hostname for the managed OpenCode server (passed as OPENCHAMBER_OPENCODE_HOSTNAME).";
    };

  /**
    Standard external OpenCode server port option for `services.openchamber`.

    Port of an already-running OpenCode instance to connect to
    (`OPENCODE_PORT`). Ignored when `opencodeHost` is set; combine with
    `skipOpencodeStart` to stop the server from spawning its own OpenCode
    process.

    # Arguments

    - `default`: TCP port or `null` (defaults to `null`, i.e. managed OpenCode).
  */
  mkOpencodePortOption =
    {
      default ? null,
    }:
    lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      inherit default;
      description = "Port of an external OpenCode server to connect to (passed as OPENCODE_PORT).";
    };

  /**
    Standard API-compression kill-switch option for `services.openchamber`.

    Sets `OPENCHAMBER_SKIP_API_COMPRESSION` (wins over the compress toggle;
    upstream compresses API responses unless skipping or running as the
    desktop runtime).

    # Arguments

    - `default`: skip API compression (defaults to `false`).
  */
  mkSkipApiCompressionOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Skip API response compression (sets OPENCHAMBER_SKIP_API_COMPRESSION).";
    };

  /**
    Standard managed-OpenCode opt-out option for `services.openchamber`.

    Skips starting (and stopping) the managed OpenCode subprocess and uses
    an external server instead (`OPENCODE_SKIP_START=true` plus
    `OPENCHAMBER_SKIP_OPENCODE_START=true`; upstream honors either, both
    are set — harmless, like the `--api-only` flag/env pairing). Combine
    with `opencodeHost` / `opencodePort`.

    # Arguments

    - `default`: skip the managed OpenCode server (defaults to `false`).
  */
  mkSkipOpencodeStartOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Use an external OpenCode server instead of spawning a managed one (sets OPENCODE_SKIP_START and OPENCHAMBER_SKIP_OPENCODE_START).";
    };

  /**
    Standard verbose request-logging option for `services.openchamber`.

    Sets `OPENCHAMBER_VERBOSE_REQUEST_LOGS` (upstream logs every request
    when enabled).

    # Arguments

    - `default`: verbose request logs (defaults to `false`).
  */
  mkVerboseRequestLogsOption =
    {
      default ? false,
    }:
    lib.mkOption {
      type = lib.types.bool;
      inherit default;
      description = "Log every request (sets OPENCHAMBER_VERBOSE_REQUEST_LOGS).";
    };

  /**
    Freeform service settings option (RFC 0042 style).

    Any attribute set; validated against the JSON format type so it can
    be serialized verbatim with `pkgs.formats.json`.

    # Arguments

    - `jsonType`: e.g. `(pkgs.formats.json {}).type`.
    - `default`: settings (defaults to `{}`).
  */
  mkSettingsOption =
    {
      jsonType,
      default ? { },
    }:
    lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonType;
      };
      inherit default;
      description = ''
        Freeform OpenChamber settings, serialized to JSON.

        Empty by default (service behavior unchanged). When non-empty,
        the module writes `/etc/openchamber/settings.json` and points
        the service at it — confirm the exact flag/env contract against
        `openchamber serve --help` for your pinned version.

        Never put secrets in settings: the generated file lives in the
        world-readable Nix store (the `/etc` copy is mode `0440`, but the
        store copy stays readable). Use password-file / credential options
        for secrets.
      '';
    };
})
