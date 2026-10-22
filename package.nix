# opencode — built from the upstream source tree, not from a release binary.
#
# The source is the `opencode` flake input (a pin on upstream tag v1.19.3).
# Two things follow from that, and neither is transcribed by hand:
#
#   * `version` is read from the source's own packages/opencode/package.json;
#   * the dependency tree comes from the source's own bun.lock — bun2nix turns
#     every registry entry in that lockfile into a fetch, using the integrity
#     value the lockfile already records, and `bun install --frozen-lockfile`
#     then installs offline from the resulting cache.
#
# Consequently, changing the `opencode` input rev changes the lockfile and the
# version in one move, and no hash in this repository has to be touched.
#
# Lockfile entries that are not npm-registry tarballs (36 `workspace:` links,
# one `github:` dependency, one direct pkg.pr.new tarball URL and two vendored
# tarballs) are deliberately absent from the fetch set. Their sources are
# either this input tree itself or reachable only from packages/app,
# packages/console/*, packages/stats/* and packages/enterprise — never from
# packages/opencode, the only workspace this build installs for.
{
  lib,
  stdenv,
  stdenvNoCC,
  bun,
  bun2nix,
  coreutils,
  findutils,
  nodejs,
  patch,
  patchelf,
  makeBinaryWrapper,
  ripgrep,
  sysctl,
  models-dev,
  testers,
  opencodeSrc,
}:
let
  inherit (lib)
    getExe
    getExe'
    ;

  packageJson = lib.importJSON (opencodeSrc + "/packages/opencode/package.json");
  version = packageJson.version;

  # ── bun.lock reading ────────────────────────────────────────────────────
  # bun.lock is JSON with trailing commas. Split on commas and drop only the
  # separator whose following segment begins with a closing brace/bracket.
  # Everything else — including the segments themselves — is preserved, so
  # the result is the source's own lockfile text with only those commas gone.
  stripTrailingCommas =
    s:
    let
      parts = lib.splitString "," s;
      startsWithClose =
        part:
        let
          t = lib.trim part;
        in
        lib.hasPrefix "}" t || lib.hasPrefix "]" t;
      fix =
        i: part:
        if i == 0 || startsWithClose part then part else "," + part;
    in
    lib.concatStrings (lib.genList (i: fix i (builtins.elemAt parts i)) (builtins.length parts));

  lock = builtins.fromJSON (stripTrailingCommas (builtins.readFile (opencodeSrc + "/bun.lock")));

  splitPackageId =
    id:
    let
      scoped = builtins.match "(@[^/]+/[^@]+)@(.+)" id;
    in
    if scoped != null then
      {
        name = builtins.elemAt scoped 0;
        version = builtins.elemAt scoped 1;
      }
    else
      let
        plain = builtins.match "([^@]+)@(.+)" id;
      in
      {
        name = builtins.elemAt plain 0;
        version = builtins.elemAt plain 1;
      };

  # Bun omits the tarball URL for packages served by the default registry;
  # reconstruct it from the lockfile's own package identity.
  registryUrl =
    id:
    let
      pkg = splitPackageId id;
      base = lib.last (lib.splitString "/" pkg.name);
    in
    "https://registry.npmjs.org/${pkg.name}/-/${base}-${pkg.version}.tgz";

  # A registry entry is a 4-tuple whose URL slot is a string (empty means the
  # default registry) and whose integrity slot is populated.
  isRegistryEntry = entry: builtins.length entry == 4 && builtins.isString (builtins.elemAt entry 1) && builtins.elemAt entry 3 != "";

  registryEntries = lib.filter (e: e != null) (
    lib.mapAttrsToList (
      _key: entry:
      if !(isRegistryEntry entry) then
        null
      else
        {
          id = builtins.elemAt entry 0;
          url = builtins.elemAt entry 1;
          integrity = builtins.elemAt entry 3;
        }
    ) lock.packages
  );

  byId = lib.groupBy (e: e.id) registryEntries;

  # The expression bun2nix's `fetchBunDeps` consumes. Every URL and every
  # integrity value here is derived from the source's bun.lock at eval time.
  bunLockFetchSet =
    { fetchurl, ... }:
    lib.mapAttrs (
      id: group:
      let
        e = builtins.head group;
      in
      fetchurl {
        url = if e.url == "" then registryUrl id else e.url;
        hash = e.integrity;
      }
    ) byId;

  # Patches declared in the lockfile's own `patchedDependencies` are applied
  # to the extracted packages before the cache is assembled. Bun's patcher is
  # whitespace-tolerant; `patch` is run with matching fuzz so the same patch
  # set lands identically here.
  patchOverrides = lib.mapAttrs (
    name: patchFile:
    pkg:
    stdenvNoCC.mkDerivation {
      pname = "patched-${lib.strings.sanitizeDerivationName name}";
      version = "0";
      dontUnpack = true;
      nativeBuildInputs = [ patch ];
      buildPhase = ''
        runHook preBuild
        ${getExe' coreutils "mkdir"} -p "$out"
        ${getExe' coreutils "cp"} -r ${pkg}/. "$out"
        ${getExe' coreutils "chmod"} -R u+w "$out"
        ${getExe patch} -p1 --fuzz=3 -d "$out" < ${patchFile}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        runHook postInstall
      '';
    }
  ) (lib.mapAttrs (_name: path: opencodeSrc + "/${path}") (lock.patchedDependencies or { }));

  bunCpu = if stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
  bunOs = if stdenv.hostPlatform.isLinux then "linux" else "darwin";

  # ── dependency tree (pure; no network) ──────────────────────────────────
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "opencode-node_modules";
    inherit version;
    src = opencodeSrc;

    nativeBuildInputs = [
      bun2nix.hook
      bun
      nodejs
    ];

    bunDeps = bun2nix.fetchBunDeps {
      bunNix = bunLockFetchSet;
      overrides = patchOverrides;
    };

    bunInstallFlags = [
      "--frozen-lockfile"
      "--no-progress"
      "--cpu=${bunCpu}"
      "--os=${bunOs}"
      "--filter"
      "!./"
      "--filter"
      "./packages/opencode"
    ];

    # The root postinstall builds native test fixtures that this build does
    # not need and that the sandbox cannot run.
    dontRunLifecycleScripts = true;
    dontUseBunBuild = true;
    dontUseBunCheck = true;

    installPhase = ''
      runHook preInstall
      ${getExe' coreutils "mkdir"} -p "$out"
      ${getExe' findutils "find"} . -type d -name node_modules -exec ${getExe' coreutils "cp"} -R --parents {} "$out" \;
      runHook postInstall
    '';
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode";
  inherit version;
  src = opencodeSrc;

  nativeBuildInputs = [
    bun
    nodejs
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ patchelf ];

  strictDeps = true;

  postPatch = ''
    # Upstream refuses to build under a bun other than the one named in its
    # root package.json. Relax that to a warning; Nix pins bun for us.
    substituteInPlace packages/script/src/index.ts \
      --replace-fail 'throw new Error(`This script requires bun@''${expectedBunVersionRange}' \
                     'console.warn(`Warning: This script requires bun@''${expectedBunVersionRange}'
  '';

  configurePhase = ''
    runHook preConfigure
    ${getExe' coreutils "cp"} -R ${nodeModules}/. .
    patchShebangs node_modules
    patchShebangs packages/*/node_modules
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    ${getExe' coreutils "mkdir"} -p "$HOME"

    # Offline model catalog snapshot and build identity.
    export MODELS_DEV_API_JSON="${models-dev}/dist/_api.json"
    export OPENCODE_DISABLE_MODELS_FETCH=true
    export OPENCODE_VERSION="${version}"
    export OPENCODE_CHANNEL=prod

    cd packages/opencode
    ${getExe bun} --bun ./script/build.ts --single --skip-install --skip-embed-web-ui

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    ${getExe' coreutils "install"} -Dm755 dist/opencode-*/bin/opencode "$out/bin/opencode"

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      # A Bun-compiled executable may be static (no interpreter) or linked
      # against the build glibc. Only rewrite the interpreter when one exists.
      if ${getExe patchelf} --print-interpreter "$out/bin/opencode" >/dev/null 2>&1; then
        interpreter="$(${getExe patchelf} --print-interpreter "$out/bin/opencode")"
        if [ "$interpreter" != "${stdenv.cc.bintools.dynamicLinker}" ]; then
          ${getExe patchelf} --set-interpreter "${stdenv.cc.bintools.dynamicLinker}" "$out/bin/opencode"
        fi
      fi
    ''}

    # Match nixpkgs runtime hardening:
    # - OPENCODE_DISABLE_AUTOUPDATE: never self-upgrade out from under Nix
    # - PATH += ripgrep: codebase search / tools that shell out to `rg`
    wrapProgram "$out/bin/opencode" \
      --prefix PATH : ${
        lib.makeBinPath (
          [ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ]
        )
      } \
      --set OPENCODE_DISABLE_AUTOUPDATE true

    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
    command = "HOME=$(${getExe' coreutils "mktemp"} -d) ${getExe finalAttrs.finalPackage} --version";
    inherit version;
  };

  meta = with lib; {
    description = "AI coding agent built for the terminal (source build)";
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
    sourceProvenance = with sourceTypes; [ fromSource ];
  };
})
