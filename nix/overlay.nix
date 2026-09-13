# System-independent overlay: `prev.callPackage` only, never
# `self.packages.${system}`.
#
# Referencing flake outputs from an overlay pins it to this flake's nixpkgs
# revision and breaks composition with other overlays; rebuilding from
# `./packages` keeps the overlay freely composable.
#
# NOTE: no keep-sorted markers here on purpose — keep-sorted sorts raw
# lines, so it must only guard single-line entry lists (see module
# `imports`). Multi-line bindings would be scrambled.
_: prev:
let
  builtSource = prev.callPackage ../packages/built-source/package.nix { };
in
{
  openchamber-gui = prev.callPackage ../packages/openchamber-gui/package.nix { };

  openchamber-server = prev.callPackage ../packages/openchamber-server/package.nix {
    inherit builtSource;
  };
}
