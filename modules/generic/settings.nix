# Shared `services.openchamber.settings` option (RFC 0042 freeform JSON).
#
# Imported by `modules/nixos`; factored out so every system module
# (NixOS today, others later) shares one definition.
{ lib, pkgs, ... }:
let
  openchamberLib = import ../../lib { inherit lib; };
in
{
  _file = ./settings.nix;

  options.services.openchamber.settings = openchamberLib.mkSettingsOption {
    jsonType = (pkgs.formats.json { }).type;
  };
}
