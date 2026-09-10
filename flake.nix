{
  description = "OpenChamber on Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      versions = import ./versions.nix;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      # Upstream AppImage arch naming: x86_64 / arm64 (NOT aarch64).
      archOf = system: versions.systems.${system}.arch or (throw "openchamber-nix: no arch mapping for ${system}");

      appimageUrl =
        system:
        "https://github.com/openchamber/openchamber/releases/download/v${versions.version}/OpenChamber-${versions.version}-linux-${archOf system}.AppImage";

      # Shared source build: bun install + UI lib build + vite web build.
      # NOTE: the build phase needs network (bun registry). Build with
      # `--option sandbox false` if your builder denies network access.
      # NOTE: electron-updater self-update is meaningless in the store
      # (immutable); updates come through versions.nix + this flake only.
      builtSource = pkgs: pkgs.stdenv.mkDerivation {
        pname = "openchamber-built-source";
        version = versions.version;
        src = pkgs.fetchFromGitHub {
          owner = "openchamber";
          repo = "openchamber";
          rev = versions.rev;
          hash = versions.srcHash;
        };
        nativeBuildInputs = [ pkgs.bun pkgs.nodejs_22 ];
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR" BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
          bun install --frozen-lockfile
          bun run --cwd packages/ui build
          bun run --cwd packages/web build
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          # Keep workspace layout intact: root node_modules holds RELATIVE
          # symlinks into packages/*, so both must be copied together.
          cp -a package.json node_modules packages $out/
          # Tolerate either text (bun.lock) or binary (bun.lockb) lockfile.
          for lockfile in bun.lock bun.lockb; do
            [ -e "$lockfile" ] && cp -a "$lockfile" $out/
          done
          runHook postInstall
        '';
      };

      serverFor = pkgs: pkgs.stdenv.mkDerivation {
        pname = "openchamber-server";
        version = versions.version;
        src = builtSource pkgs;
        dontBuild = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out/lib/openchamber $out/bin
          cp -a $src/package.json $src/node_modules $src/packages $out/lib/openchamber/
          # Tolerate either text (bun.lock) or binary (bun.lockb) lockfile.
          for lockfile in "$src"/bun.lock "$src"/bun.lockb; do
            [ -e "$lockfile" ] && cp -a "$lockfile" $out/lib/openchamber/
          done
          makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/openchamber \
            --add-flags "$out/lib/openchamber/packages/web/bin/cli.js" \
            --prefix PATH : "${pkgs.lib.makeBinPath [ pkgs.opencode pkgs.git pkgs.openssh pkgs.bash ]}" \
            --set NODE_PATH "$out/lib/openchamber/node_modules" \
            --set SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          runHook postInstall
        '';
        meta = with pkgs.lib; {
          description = "OpenChamber server + CLI (openchamber serve)";
          homepage = "https://github.com/openchamber/openchamber";
          license = licenses.mit;
          mainProgram = "openchamber";
          platforms = systems;
        };
      };

      webFor = pkgs: pkgs.stdenv.mkDerivation {
        pname = "openchamber-web";
        version = versions.version;
        src = builtSource pkgs;
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/openchamber-web
          cp -a $src/packages/web/dist/. $out/share/openchamber-web/
          runHook postInstall
        '';
        meta = with pkgs.lib; {
          description = "OpenChamber static web UI assets";
          homepage = "https://github.com/openchamber/openchamber";
          license = licenses.mit;
          platforms = systems;
        };
      };

      guiFor = system: pkgs:
        let
          # Fetch once; shared by wrapType2 and the icon/desktop extraction.
          appSrc = pkgs.fetchurl {
            url = appimageUrl system;
            hash = versions.systems.${system}.appimage;
          };
        in
        pkgs.appimageTools.wrapType2 {
          pname = "openchamber-gui";
          version = versions.version;
          src = appSrc;
          # NOTE: electron-updater self-update is disabled by design here —
          # the AppImage lives in the immutable Nix store.
          extraInstallCommands =
            let
              extracted = pkgs.appimageTools.extract {
                pname = "openchamber-gui";
                inherit (versions) version;
                src = appSrc;
              };
            in
            ''
              for desktop in ${extracted}/*.desktop; do
                install -Dm444 "$desktop" -t $out/share/applications
              done
              sed -i 's|^Exec=AppRun.*|Exec=openchamber-gui|' $out/share/applications/*.desktop
              if [ -d ${extracted}/usr/share/icons ]; then
                cp -r ${extracted}/usr/share/icons $out/share/
              fi
              for icon in ${extracted}/*.png ${extracted}/*.svg; do
                [ -f "$icon" ] || continue
                ext="''${icon##*.}"
                install -Dm444 "$icon" "$out/share/icons/hicolor/512x512/apps/openchamber-gui.$ext"
              done
            '';
          meta = with pkgs.lib; {
            description = "OpenChamber desktop GUI (Electron AppImage)";
            homepage = "https://github.com/openchamber/openchamber";
            license = licenses.mit;
            mainProgram = "openchamber-gui";
            platforms = [ system ];
          };
        };
    in
    {
      packages = forSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          openchamber-server = serverFor pkgs;
          openchamber-web = webFor pkgs;
          openchamber-gui = guiFor system pkgs;
          openchamber-gui-appimage = self.packages.${system}.openchamber-gui;
          default = self.packages.${system}.openchamber-server;
        }
      );

      apps = forSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          openchamber-server = {
            type = "app";
            program = "${self.packages.${system}.openchamber-server}/bin/openchamber";
          };
          openchamber-gui = {
            type = "app";
            program = "${self.packages.${system}.openchamber-gui}/bin/openchamber-gui";
          };
          default = self.apps.${system}.openchamber-server;
        }
      );

      nixosModules.openchamber =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.openchamber;
        in
        {
          options.services.openchamber = {
            enable = lib.mkEnableOption "OpenChamber server";
            package = lib.mkOption {
              type = lib.types.package;
              default = pkgs.openchamber-server;
              description = "The openchamber-server package to run (provided by this flake's overlay).";
            };
            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Host for the web UI to bind to.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 3000;
              description = "Port for the web UI to listen on.";
            };
            uiPasswordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "File containing the UI password (passed as OPENCHAMBER_UI_PASSWORD_FILE).";
            };
          };
          config = lib.mkIf cfg.enable {
            systemd.services.openchamber = {
              description = "OpenChamber server";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              environment = {
                OPENCHAMBER_HOST = cfg.host;
                OPENCHAMBER_PORT = toString cfg.port;
              } // lib.optionalAttrs (cfg.uiPasswordFile != null) {
                # Staged via LoadCredential below so it stays readable under DynamicUser.
                OPENCHAMBER_UI_PASSWORD_FILE = "/run/credentials/openchamber.service/ui-password";
              };
              serviceConfig = {
                ExecStart = lib.escapeShellArgs [
                  "${cfg.package}/bin/openchamber"
                  "serve"
                  "--host"
                  cfg.host
                  "--port"
                  (toString cfg.port)
                ];
                Restart = "on-failure";
                DynamicUser = true;
                StateDirectory = "openchamber";
              } // lib.optionalAttrs (cfg.uiPasswordFile != null) {
                # LoadCredential stages the secret where DynamicUser can read
                # it; the raw host path (e.g. /run/secrets) may not be
                # accessible to the sandboxed service user otherwise.
                LoadCredential = [ "ui-password:${cfg.uiPasswordFile}" ];
              };
            };
          };
        };

      overlays.default = final: prev: {
        openchamber-server = self.packages.${prev.stdenv.hostPlatform.system}.openchamber-server;
        openchamber-web = self.packages.${prev.stdenv.hostPlatform.system}.openchamber-web;
        openchamber-gui = self.packages.${prev.stdenv.hostPlatform.system}.openchamber-gui;
      };

      devShells = forSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.bun pkgs.nodejs_22 ];
        };
      });
    };
}
