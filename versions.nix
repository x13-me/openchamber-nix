# Machine-updated by .github/update-openchamber.sh — do not edit by hand.
{
  version = "1.24.2";
  rev = "614d7f76e581a132a86575c03d3fa9aad5e624b6";
  srcHash = "sha256-89hKIXndRBfLOzFPmeYA/Hnl7mUIFGB3hlpjdUcmhLI=";
  # Upstream-expected opencode CLI version: the packages/web
  # @opencode-ai/sdk pin (tracks the CLI release line; the server has no
  # separate binary-version gate). Maintained by
  # .github/update-openchamber.sh; drives the opencodePackage skew warning.
  opencodeVersion = "1.18.31";
  systems = {
    x86_64-linux = {
      arch = "x86_64";
      appimage = "sha256-4F/FoPxvj9TH6yBfrURaFeY6DoBWl+HlsVM4I9oeLPM=";
    };
    aarch64-linux = {
      arch = "arm64";
      appimage = "sha256-y3srws/T4Bhapf//o9iDDMz3hq2fRDnVC8LT1z5s1xc=";
    };
  };
}
