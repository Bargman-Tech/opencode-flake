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
{ lib
, stdenv
, stdenvNoCC
, bun
, bun2nix
, coreutils
, findutils
, nodejs
, patch
, patchelf
, makeBinaryWrapper
, ripgrep
, sysctl
, models-dev
, testers
, opencodeSrc
,
}:
let
  inherit (lib)
    getExe
    getExe'
    ;

  packageJson = lib.importJSON (opencodeSrc + "/packages/opencode/package.json");
  version = packageJson.version;

  # ── bun.lock reading ────────────────────────────────────────────────────
  # bun.lock is JSONC whose only extension is trailing commas. The previous
  # implementation split the whole file on `,` and dropped a comma whenever
  # the *next segment* began with `}`/`]` — which also deleted a comma INSIDE
  # a string value that happened to be followed by `}`/`]`, silently corrupting
  # fields (including integrity values) while `builtins.fromJSON` still
  # succeeded. That is a supply-chain hazard, not a formatting detail.
  #
  # This scanner walks the text character by character and tracks JSON string
  # state and escapes. A comma is removed only when it is outside a string and
  # the next non-whitespace character is `}` or `]`. Strings cannot contain a
  # literal newline, so the scan is line-local; a trailing comma at end of line
  # is held until the next non-whitespace line proves whether it precedes a
  # closer.
  isWs = c: c == " " || c == "\t" || c == "\r";

  scanLine =
    line:
    let
      cs = lib.stringToCharacters line;
      n = builtins.length cs;
      at = i: builtins.elemAt cs i;
      nextNonWs =
        i:
        if i >= n then
          n
        else if isWs (at i) then
          nextNonWs (i + 1)
        else
          i;
      go =
        i: inString: escaped: out: firstNonWs: lastNonWs:
        if i >= n then
          {
            text = lib.concatStrings (lib.reverseList out);
            inherit firstNonWs;
            trailingComma = lastNonWs != null && !lastNonWs.inString && lastNonWs.ch == ",";
          }
        else
          let
            c = at i;
            firstNonWs' = if firstNonWs == null && !isWs c then c else firstNonWs;
            lastNonWs' = if isWs c then lastNonWs else { ch = c; inString = inString; };
          in
          if inString then
            if escaped then
              go (i + 1) true false ([ c ] ++ out) firstNonWs' lastNonWs'
            else if c == "\\" then
              go (i + 1) true true ([ c ] ++ out) firstNonWs' lastNonWs'
            else if c == "\"" then
              go (i + 1) false false ([ c ] ++ out) firstNonWs' lastNonWs'
            else
              go (i + 1) true false ([ c ] ++ out) firstNonWs' lastNonWs'
          else if c == "\"" then
            go (i + 1) true false ([ c ] ++ out) firstNonWs' lastNonWs'
          else if c == "," then
            let
              j = nextNonWs (i + 1);
            in
            if j < n && (at j == "}" || at j == "]") then
              go (i + 1) false false out firstNonWs' lastNonWs'
            else
              go (i + 1) false false ([ c ] ++ out) firstNonWs' lastNonWs'
          else
            go (i + 1) false false ([ c ] ++ out) firstNonWs' lastNonWs';
    in
    go 0 false false [ ] null null;

  dropTrailingComma =
    line:
    let
      cs = lib.stringToCharacters line;
      n = builtins.length cs;
      at = i: builtins.elemAt cs i;
      findLast =
        i:
        if i < 0 then
          null
        else if isWs (at i) then
          findLast (i - 1)
        else
          i;
      idx = findLast (n - 1);
    in
    if idx == null || at idx != "," then
      line
    else
      lib.substring 0 idx line + lib.substring (idx + 1) (n - idx - 1) line;

  stripTrailingCommas =
    s:
    let
      lines = lib.splitString "\n" s;
      n = builtins.length lines;
      at = i: builtins.elemAt lines i;
      go =
        i: pending: acc:
        if i >= n then
          let
            acc' = if pending == null then acc else lib.reverseList pending ++ acc;
          in
          lib.concatStringsSep "\n" (lib.reverseList acc')
        else
          let
            r = scanLine (at i);
          in
          if r.firstNonWs == null then
            if pending == null then
              go (i + 1) null ([ r.text ] ++ acc)
            else
              go (i + 1) (pending ++ [ r.text ]) acc
          else
            let
              acc' =
                if pending == null then
                  acc
                else
                  let
                    first = builtins.head pending;
                    rest = builtins.tail pending;
                    first' =
                      if r.firstNonWs == "}" || r.firstNonWs == "]" then
                        dropTrailingComma first
                      else
                        first;
                    flushed = [ first' ] ++ rest;
                  in
                  lib.reverseList flushed ++ acc;
            in
            if r.trailingComma then
              go (i + 1) [ r.text ] acc'
            else
              go (i + 1) null ([ r.text ] ++ acc');
    in
    go 0 null [ ];

  rawLock = builtins.readFile (opencodeSrc + "/bun.lock");
  lock = builtins.fromJSON (stripTrailingCommas rawLock);

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
    lib.mapAttrsToList
      (
        _key: entry:
          if !(isRegistryEntry entry) then
            null
          else
            {
              id = builtins.elemAt entry 0;
              url = builtins.elemAt entry 1;
              integrity = builtins.elemAt entry 3;
            }
      )
      lock.packages
  );

  byId = lib.groupBy (e: e.id) registryEntries;

  # `lib.groupBy` collapses entries that share an id (for example a workspace
  # alias that resolves to the same registry package). Collapsing must never
  # paper over a disagreement: every member of a group must carry the same
  # integrity, otherwise the lockfile is internally inconsistent and the fetch
  # set would silently pick one of two answers. Prefer a member with a
  # non-empty URL, but the URL slot is empty for default-registry entries by
  # design (it is reconstructed from the id).
  chooseGroup =
    id: group:
    let
      integrities = lib.unique (map (e: e.integrity) group);
      urls = lib.filter (u: u != "") (map (e: e.url) group);
    in
    if builtins.length integrities != 1 then
      throw "bun.lock integrity disagreement for ${id}: ${lib.concatStringsSep ", " integrities}"
    else
      {
        inherit id;
        integrity = builtins.head integrities;
        url = if urls != [ ] then builtins.head urls else (builtins.head group).url;
      };

  # The expression bun2nix's `fetchBunDeps` consumes. Every URL and every
  # integrity value here is derived from the source's bun.lock at eval time.
  bunLockFetchSet =
    { fetchurl, ... }:
    lib.mapAttrs
      (
        id: group:
        let
          e = chooseGroup id group;
        in
        fetchurl {
          url = if e.url == "" then registryUrl id else e.url;
          hash = e.integrity;
        }
      )
      byId;

  # Round-trip verification: the parsed lockfile must still agree with the
  # raw bytes. For every package id, the id itself and *every string slot of
  # its tuple* must appear verbatim (quoted) in the source text.
  #
  # Checking every string slot, rather than assuming one fixed URL index, is
  # deliberate: bun.lock uses more than one tuple shape. Registry entries are
  # `[id, url, set, integrity]` (url is empty for the default registry); the
  # vendored/pkg.pr.new entries are `[id-with-source, set, integrity]`, so the
  # URL lives inside the identification string; the github entry is
  # `[id, set, resolved, integrity]`. A fixed `elemAt 1`/`elemAt 3` pair would
  # silently skip the integrity of every 3-tuple. This check covers the URL
  # and integrity wherever the tuple puts them, and it is what catches the
  # string-corrupting stripper the old split-on-comma implementation allowed.
  lockRoundtripFailures =
    let
      contains = needle: builtins.length (lib.splitString needle rawLock) > 1;
      entryOk =
        id:
        let
          e = lock.packages.${id};
          strings = builtins.filter builtins.isString e;
        in
        contains ("\"" + id + "\"")
        && builtins.all (s: contains ("\"" + s + "\"")) strings;
    in
    builtins.filter (id: !(entryOk id)) (builtins.attrNames lock.packages);

  # Patches declared in the lockfile's own `patchedDependencies` are applied
  # to the extracted packages before the cache is assembled. Bun's patcher is
  # whitespace-tolerant; `patch` is not, unless fuzz is allowed.
  #
  # Fuzz is recorded per patch instead of applied blindly to every dependency.
  # Measured against the registry tarballs the lockfile names at v1.19.3, 17 of
  # the 19 patches apply at fuzz 0. Only these two need fuzz 3:
  #   * @silvia-odwyer/photon-node@0.3.4 — hunk #10 of 10 lands with offset
  #     drift in photon_rs.js;
  #   * @ai-sdk/google@3.0.73 — the single hunk in
  #     src/convert-to-google-generative-ai-messages.ts lands with offset drift.
  # A patch that needs more than 3 is a signal to re-derive it, not to raise
  # the number: rejects fail the build below.
  patchFuzz = {
    "@silvia-odwyer/photon-node@0.3.4" = 3;
    "@ai-sdk/google@3.0.73" = 3;
  };

  patchOverrides = lib.mapAttrs
    (
      name: patchFile:
        pkg:
        stdenvNoCC.mkDerivation {
          pname = "patched-${lib.strings.sanitizeDerivationName name}";
          version = "0";
          dontUnpack = true;
          nativeBuildInputs = [
            patch
            coreutils
          ];
          buildPhase = ''
            runHook preBuild
            ${getExe' coreutils "mkdir"} -p "$out"
            ${getExe' coreutils "cp"} -r ${pkg}/. "$out"
            ${getExe' coreutils "chmod"} -R u+w "$out"

            # Reject detection has exactly two live detectors:
            #   1. `patch`'s exit status — a hunk that does not apply fails the
            #      derivation immediately; and
            #   2. the reject file named by `--reject-file`, checked for
            #      non-emptiness after a successful exit, so a future
            #      `--forward`-style change cannot turn a rejected hunk into a
            #      silently unpatched dependency.
            # `--reject-file` sends rejects to $TMPDIR, never into $out, so a
            # `find "$out" -name '*.rej'` would be dead code; it is not used.
            reject="$TMPDIR/rejects-${lib.strings.sanitizeDerivationName name}"
            if ! ${getExe patch} -p1 --fuzz=${toString (patchFuzz.${name} or 0)} \
                 --reject-file="$reject" -d "$out" < ${patchFile}; then
              ${getExe' coreutils "echo"} "patch failed for ${name}" >&2
              if [ -s "$reject" ]; then ${getExe' coreutils "cat"} "$reject" >&2; fi
              exit 1
            fi
            if [ -e "$reject" ] && [ -s "$reject" ]; then
              ${getExe' coreutils "echo"} "patch produced rejects for ${name} (fuzz=${toString (patchFuzz.${name} or 0)})" >&2
              ${getExe' coreutils "cat"} "$reject" >&2
              exit 1
            fi

            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            runHook postInstall
          '';
        }
    )
    (lib.mapAttrs (_name: path: opencodeSrc + "/${path}") (lock.patchedDependencies or { }));

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

  # Phase 5.1 (LLM-CORE dual-generation plan): honour the explicit
  # OPENCODE_APP_NAME / OPENCODE_DATA_HOME / OPENCODE_STATE_HOME /
  # OPENCODE_CACHE_HOME contract while preserving every XDG default. The
  # paths themselves stay per-machine and come from the NixOS module.
  patches = [ ./patches/opencode-state-paths-v1.patch ];

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
    # - OPENCODE_DISABLE_EMBEDDED_WEB_UI: this build passes
    #   `--skip-embed-web-ui`, so there is no `opencode-web-ui.gen.ts` bundle
    #   and upstream's `embeddedUI()` would return null anyway. Setting the
    #   upstream flag (defined in src/effect/runtime-flags.ts as
    #   `disableEmbeddedWebUi: bool("OPENCODE_DISABLE_EMBEDDED_WEB_UI")`)
    #   makes `opencode web`'s proxy to https://app.opencode.ai an explicit
    #   choice rather than an accident of the missing file.
    wrapProgram "$out/bin/opencode" \
      --prefix PATH : ${
        lib.makeBinPath (
          [ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ]
        )
      } \
      --set OPENCODE_DISABLE_AUTOUPDATE true \
      --set OPENCODE_DISABLE_EMBEDDED_WEB_UI true

    runHook postInstall
  '';

  passthru = {
    tests.version = testers.testVersion {
      package = finalAttrs.finalPackage;
      command = "HOME=$(${getExe' coreutils "mktemp"} -d) ${getExe finalAttrs.finalPackage} --version";
      inherit version;
    };

    # Exposure for the flake's lock round-trip check (and for humans): the
    # raw text the parser saw and the parsed package map.
    bunLock = {
      text = rawLock;
      packages = lock.packages;
    };

    # Lazily evaluated: a check that touches this attribute proves that every
    # parsed entry still appears verbatim in the source lockfile.
    bunLockRoundtrip =
      if lockRoundtripFailures == [ ] then
        "ok"
      else
        throw "bun.lock round-trip failed for: ${lib.concatStringsSep ", " lockRoundtripFailures}";
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
