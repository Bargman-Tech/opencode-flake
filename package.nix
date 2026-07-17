{
  stdenv,
  lib,
  fetchzip,
  patchelf,
  testers,
}:
let
  version = "1.18.3";
  # Prebuilt release assets from anomalyco/opencode (formerly sst/opencode).
  # Baseline builds avoid AVX requirements on older x86_64 CPUs.
  srcs = {
    "x86_64-linux" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64-baseline.tar.gz";
      # Unpacked NAR hash (fetchzip); not the raw archive hash
      hash = "sha256-utRBGXWc2hBuUGwHuOkj1NmjDbV0gxf5cLg4yZanVQ4=";
      stripRoot = false;
    };
    "aarch64-linux" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-arm64.tar.gz";
      hash = "sha256-uuvNQuN16AWjkeIj4oTjzeoyaXALWIqprhMY28GInAk=";
      stripRoot = false;
    };
    "aarch64-darwin" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-darwin-arm64.zip";
      hash = "sha256-/8K3SmfWU56vlbPaN1VvkOhYO0FDOOH4TB4cGpa25hc=";
      stripRoot = false;
    };
    "x86_64-darwin" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-darwin-x64-baseline.zip";
      hash = "sha256-ekgbzbY4FBQYi+XY0+aBVBEuD+g9Em7PISogTKZcxhg=";
      stripRoot = false;
    };
  };
  system = stdenv.hostPlatform.system;
  needsPatchelf = stdenv.isLinux;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "opencode";
  inherit version;

  src = srcs.${system} or (throw "unsupported system: ${system}");

  nativeBuildInputs = lib.optionals needsPatchelf [ patchelf ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 opencode $out/bin/opencode
    ${lib.optionalString needsPatchelf ''
      patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" $out/bin/opencode
    ''}
    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
    command = "HOME=$(mktemp -d) opencode --version";
    inherit version;
  };

  meta = with lib; {
    description = "AI coding agent built for the terminal";
    homepage = "https://github.com/anomalyco/opencode";
    changelog = "https://github.com/anomalyco/opencode/releases/tag/v${version}";
    license = licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    mainProgram = "opencode";
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
})
