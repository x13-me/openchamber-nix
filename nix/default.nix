# Main flake outputs (imported by the thin `flake.nix`).
#
# Small-flake layout, no flake-parts/flake-utils/haumea:
# `forAllSystems` is just `lib.genAttrs` over `legacyPackages`.
{ nixpkgs, ... }:
let
  inherit (nixpkgs) lib;
  openchamberLib = import ../lib { inherit lib; };

  inherit (openchamberLib) systems;

  forAllSystems = fn: lib.genAttrs systems (s: fn nixpkgs.legacyPackages.${s});

  scopeFor = pkgs: import ../packages { inherit pkgs; };

  publicNames = [
    # keep-sorted start
    "openchamber-gui"
    "openchamber-server"
    "openchamber-web"
    # keep-sorted end
  ];

  isUsableOn =
    pkgs: _: pkg:
    lib.isDerivation pkg
    && !(pkg.meta.broken or false)
    && lib.meta.availableOn pkgs.stdenv.hostPlatform pkg;

  packages = forAllSystems (
    pkgs:
    let
      scope = scopeFor pkgs;
      public = lib.filterAttrs (isUsableOn pkgs) (lib.getAttrs publicNames scope);
    in
    public
    // {
      openchamber-gui-appimage = public.openchamber-gui;
      default = public.openchamber-server;
    }
  );

  formatterFor = pkgs: pkgs.callPackage ./formatter.nix { };
in
{
  inherit packages;

  apps = forAllSystems (
    pkgs:
    let
      system = pkgs.stdenv.hostPlatform.system;
      built = packages.${system};
      openchamber-gui = {
        type = "app";
        program = "${built.openchamber-gui}/bin/openchamber-gui";
      };
      openchamber-server = {
        type = "app";
        program = "${built.openchamber-server}/bin/openchamber";
      };
    in
    {
      inherit openchamber-gui openchamber-server;
      default = openchamber-server;
    }
  );

  # Raw scope (unfiltered, incl. internal `builtSource`); non-derivations
  # from `makeScope` bookkeeping (`callPackage`, `overrideScope`, …) are
  # dropped so every exposed member is a real package.
  legacyPackages = forAllSystems (pkgs: lib.filterAttrs (_: lib.isDerivation) (scopeFor pkgs));

  overlays = {
    default = import ./overlay.nix;
  };

  devShells = forAllSystems (
    pkgs:
    let
      formatter = formatterFor pkgs;
    in
    {
      default = pkgs.mkShellNoCC {
        packages = [
          # keep-sorted start
          pkgs.bun
          pkgs.git
          pkgs.just
          pkgs.nodejs_22
          # keep-sorted end
        ]
        ++ formatter.runtimeInputs;
        env.DIRENV_LOG_FORMAT = "";
      };
    }
  );

  checks = forAllSystems (
    pkgs:
    let
      formatter = formatterFor pkgs;
    in
    {
      formatting =
        pkgs.runCommandLocal "openchamber-formatting-check"
          {
            src = lib.cleanSource ../.;
            nativeBuildInputs = [ formatter ];
          }
          ''
            cd "$src"
            treefmt --tree-root-file flake.nix --ci
            touch "$out"
          '';
    }
  );

  formatter = forAllSystems formatterFor;

  nixosModules = {
    default = ../modules/nixos/default.nix;
    # Legacy alias (helium-nix compat): `nixosModules.openchamber`.
    openchamber = ../modules/nixos/default.nix;
  };

  homeModules = {
    default = ../modules/home-manager/default.nix;
  };

  hydraJobs =
    let
      jobsFor =
        system: map (name: lib.nameValuePair "${name}-${system}" packages.${system}.${name}) publicNames;
    in
    lib.listToAttrs (lib.concatMap jobsFor systems);

  lib = openchamberLib;
}
