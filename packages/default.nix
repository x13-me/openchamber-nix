# Package scope: `makeScope` lets openchamber-server share the internal
# node-modules FOD via `self.callPackage`.
#
# `nodeModules` is intentionally internal — `nix/default.nix` strips it
# from the public `packages` output (it stays visible in `legacyPackages`).
#
# NOTE: no keep-sorted markers here on purpose — keep-sorted sorts raw
# lines, so it must only guard single-line entry lists (see module
# `imports`). Multi-line bindings would be scrambled.
{ pkgs }:
pkgs.lib.makeScope pkgs.newScope (self: {
  nodeModules = self.callPackage ./node-modules/package.nix { };

  openchamber-gui = self.callPackage ./openchamber-gui/package.nix { };

  openchamber-server = self.callPackage ./openchamber-server/package.nix {
    inherit (self) nodeModules;
  };
})
