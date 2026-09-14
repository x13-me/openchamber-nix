# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.23.2";
  rev = "64648f7ba3d64bcc7060c996100128407e048b67";
  srcHash = "sha256-zCVXjxa5RNH5GIrJSBrM2rkZ6Ymp31FSHr4D7zIg2W8=";
  # Upstream-expected opencode CLI version: the packages/web
  # @opencode-ai/sdk pin (tracks the CLI release line; the server has no
  # separate binary-version gate). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage skew warning.
  opencodeVersion = "1.18.31";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-M8KSrj30WASvk+qqdv8fQ+hyxEI7hNFg0XPmLsUmhc8=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-9HUdMi3MgZ6d4hSFsKqzXHhI8DLCFiKpsM5X1qffHXo=";
    };
  };
}
