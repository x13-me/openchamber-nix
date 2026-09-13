# Package scope: `makeScope` lets server/web share the internal
# built-source build via `self.callPackage`.
#
# `builtSource` is intentionally internal — `nix/default.nix` strips it
# from the public `packages` output (it stays visible in `legacyPackages`).
#
# NOTE: no keep-sorted markers here on purpose — keep-sorted sorts raw
# lines, so it must only guard single-line entry lists (see module
# `imports`). Multi-line bindings would be scrambled.
{ pkgs }:
pkgs.lib.makeScope pkgs.newScope (self: {
  builtSource = self.callPackage ./built-source/package.nix { };

  openchamber-gui = self.callPackage ./openchamber-gui/package.nix { };

  openchamber-server = self.callPackage ./openchamber-server/package.nix {
    inherit (self) builtSource;
  };

  openchamber-web = self.callPackage ./openchamber-web/package.nix {
    inherit (self) builtSource;
  };
})
