# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.24.0";
  rev = "ea3ffa863bebe4d25463ec56c88ba67a1fe78639";
  srcHash = "sha256-5mm9835NA/NcPlIsbtXz4L8WQBxqlAuKKjI5x39xYWw=";
  # Upstream-expected opencode CLI version: the packages/web
  # @opencode-ai/sdk pin (tracks the CLI release line; the server has no
  # separate binary-version gate). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage skew warning.
  opencodeVersion = "1.18.31";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-DBo1Ue857oZU0pVHlI+5ZK3vlUiXGUow/Y/vdLOSo5Q=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-r5HFZjTPfdbG9KB1Th4IDV3Aa/mn0m3Uw+R4sxCo8ss=";
    };
  };
}
