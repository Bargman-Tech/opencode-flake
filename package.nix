{
  stdenv,
  lib,
  fetchzip,
  patchelf,
  makeBinaryWrapper,
  ripgrep,
  sysctl,
  testers,
}:
let
  version = "1.18.4";
  # Prebuilt release assets from anomalyco/opencode (formerly sst/opencode).
  # Baseline builds avoid AVX requirements on older x86_64 CPUs.
  srcs = {
    "x86_64-linux" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64-baseline.tar.gz";
      # Unpacked NAR hash (fetchzip); not the raw archive hash
      hash = "sha256-zzmbK9vi3obosRAvv/Lc32kF9U7Q3lHLMZSFX7Xmyx4=";
      stripRoot = false;
    };
    "aarch64-linux" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-arm64.tar.gz";
      hash = "sha256-NTmlIcKlMbZNySoaRgXlsPafAvucii7Ivx1+GU27TaA=";
      stripRoot = false;
    };
    "aarch64-darwin" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-darwin-arm64.zip";
      hash = "sha256-JlRJZWCyXtiLBRCMiwvXQ0BFL87pbzySBeiMgbZV840=";
      stripRoot = false;
    };
    "x86_64-darwin" = fetchzip {
      url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-darwin-x64-baseline.zip";
      hash = "sha256-0/Xk6FiPyccEtd2lR42iaIBqte2VBHrwDdfg8NSsSv8=";
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

  nativeBuildInputs = [ makeBinaryWrapper ] ++ lib.optionals needsPatchelf [ patchelf ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 opencode $out/bin/opencode

    ${lib.optionalString needsPatchelf ''
      # NixOS: use store dynamic linker so the prebuilt binary can execute
      patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" $out/bin/opencode
    ''}

    # Match nixpkgs runtime hardening:
    # - OPENCODE_DISABLE_AUTOUPDATE: never self-upgrade out from under Nix
    # - PATH += ripgrep: codebase search / tools that shell out to `rg`
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${
        lib.makeBinPath (
          [ ripgrep ]
          ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ]
        )
      } \
      --set OPENCODE_DISABLE_AUTOUPDATE true

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
