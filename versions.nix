# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.23.2";
  webHash = "sha256-jZmlckmym/JEK4MK+Xxcc2MImiVHPz5Gk6CK+8un8kI=";
  # Opencode CLI release-line pin: the published web tarball's
  # @opencode-ai/sdk pin (informational basis for the major-skew warning;
  # the server declares no minimum CLI version). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage major-skew
  # warning.
  opencodeVersion = "1.18.31";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-M8KSrj30WASvk+qqdv8fQ+hyxEI7hNFg0XPmLsUmhc8=";
      nodeModules = "sha256-ydXeGMTl8GDfuRa3bJ94+PsEaC8z5GPnQfTC0UCKAmY=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-9HUdMi3MgZ6d4hSFsKqzXHhI8DLCFiKpsM5X1qffHXo=";
      nodeModules = "sha256-fFvmDsTRnmeXpuE3tCStfWxc5K26qZCd/WG/tT8aqVY=";
    };
  };
}
