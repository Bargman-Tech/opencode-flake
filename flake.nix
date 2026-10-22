{
  description = "OpenCode - a source-built, patchable terminal AI assistant";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # The upstream SOURCE, not a release tarball and not a binary. The rev is
    # upstream tag v1.19.3. Bumping this input is the ONLY thing needed to move
    # the CLI to another upstream revision: the version is read from the
    # source's own packages/opencode/package.json, and the dependency tree is
    # derived from the source's own bun.lock at evaluation time.
    opencode = {
      url = "github:anomalyco/opencode/e3c4eb242585dcd77be1a867391b7c25fd47ce52";
      flake = false;
    };

    # Lockfile-aware Bun dependency builder. It turns the upstream `bun.lock`
    # into a fetch set using the integrity hashes already recorded there, and
    # installs the dependency tree offline from the resulting cache. No
    # dependency hash is written in this repository.
    bun2nix = {
      url = "github:baileyluTCD/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      # Keep the fleet's existing nix-systems/default pin; do not let this
      # input swap the `systems` node other inputs already use.
      inputs.systems.url = "github:nix-systems/default/da67096a3b9bf56a91d16901293e51ba5b49a27e";
    };
  };

  outputs =
    { self, nixpkgs, opencode, bun2nix }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forEachSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit system;
          }
        );
    in
    {
      packages = forEachSystem (
        { pkgs, system }:
        {
          opencode = pkgs.callPackage ./package.nix {
            opencodeSrc = opencode;
            bun2nix = bun2nix.packages.${system}.default;
          };
          default = self.packages.${system}.opencode;
        }
      );

      apps = forEachSystem (
        { pkgs, system }:
        {
          opencode = {
            type = "app";
            program = "${self.packages.${system}.opencode}/bin/opencode";
          };
          default = self.apps.${system}.opencode;
        }
      );

      devShells = forEachSystem (
        { pkgs, system }:
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              self.packages.${system}.opencode
            ];
          };
        }
      );

      checks = forEachSystem (
        { pkgs, system }:
        let
          opencode = self.packages.${system}.opencode;

          # A source build that merely prints a version must not pass the
          # gate. This script exercises the CLI's own configuration and path
          # surfaces, and proves that a plugin's server export actually runs
          # (the instance bootstrap calls Plugin.init(), not `--version`).
          behaviourScript = pkgs.writeShellApplication {
            name = "check-opencode-behaviour";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.jq
              pkgs.gnugrep
            ];
            text = ''
              # jq programs are single-quoted on purpose: `$schema` and `$p` are
              # jq variables/literals, not shell expansions.
              set -euo pipefail
              JQ="${pkgs.lib.getExe pkgs.jq}"
              GREP="${pkgs.lib.getExe pkgs.gnugrep}"
              MKTEMP="${pkgs.lib.getExe' pkgs.coreutils "mktemp"}"
              MKDIR="${pkgs.lib.getExe' pkgs.coreutils "mkdir"}"
              CAT="${pkgs.lib.getExe' pkgs.coreutils "cat"}"
              BIN="${pkgs.lib.getExe opencode}"
              expected="${opencode.version}"

              tmp="$("$MKTEMP" -d)"
              export HOME="$tmp/home"
              export XDG_DATA_HOME="$tmp/data"
              export XDG_CACHE_HOME="$tmp/cache"
              export XDG_CONFIG_HOME="$tmp/config"
              export XDG_STATE_HOME="$tmp/state"
              export TMPDIR="$tmp/tmp"
              "$MKDIR" -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$TMPDIR" "$tmp/project"
              cd "$tmp/project"

              got="$("$BIN" --version)"
              if [ "$got" != "$expected" ]; then
                echo "version mismatch: got $got expected $expected" >&2
                exit 1
              fi

              # `debug paths` must report every global root, not just exist.
              "$BIN" debug paths > "$tmp/paths"
              for root in home data bin log repos cache config state tmp; do
                if ! "$GREP" -q "^$root " "$tmp/paths"; then
                  echo "debug paths missing root: $root" >&2
                  "$CAT" "$tmp/paths" >&2
                  exit 1
                fi
              done
              if ! "$GREP" -q "^data .*opencode$" "$tmp/paths"; then
                echo "debug paths data root does not end in /opencode" >&2
                exit 1
              fi

              # `debug config` must be the resolved config shape.
              "$BIN" debug config > "$tmp/config.json"
              # shellcheck disable=SC2016
              "$JQ" -e '.["$schema"] == "https://opencode.ai/config.json" and (.agent | type == "object") and (.mode | type == "object") and (.command | type == "object") and (.plugin | type == "array")' "$tmp/config.json" > /dev/null

              # Plugin-load smoke: a local plugin records the fact that its
              # server export was invoked. `debug skill` bootstraps the
              # instance, which is what calls Plugin.init().
              marker="$tmp/plugin-loaded"
              printf '%s\n' \
                'import { writeFileSync } from "node:fs";' \
                'export default async function () {' \
                '  writeFileSync(process.env.GATE2_MARKER, "loaded\n");' \
                '  return {};' \
                '}' > "$tmp/plugin.js"
              # shellcheck disable=SC2016
              "$JQ" -n --arg p "file://$tmp/plugin.js" \
                '{ "$schema": "https://opencode.ai/config.json", plugin: [ $p ] }' > "$tmp/content.json"

              OPENCODE_CONFIG_CONTENT="$("$CAT" "$tmp/content.json")" \
                "$BIN" debug config > "$tmp/config2.json"
              # shellcheck disable=SC2016
              "$JQ" -e --arg p "file://$tmp/plugin.js" '.plugin | index($p) != null' "$tmp/config2.json" > /dev/null

              GATE2_MARKER="$marker" \
                OPENCODE_CONFIG_CONTENT="$("$CAT" "$tmp/content.json")" \
                "$BIN" debug skill > /dev/null
              if [ ! -f "$marker" ]; then
                echo "plugin-load smoke failed: server export did not run" >&2
                exit 1
              fi
              if "$GREP" -qa "failed to load plugin" "$XDG_DATA_HOME/opencode/log/"*.log 2>/dev/null; then
                echo "plugin-load smoke failed: log records a plugin load failure" >&2
                exit 1
              fi

              echo "opencode behaviour ok: $got, 9 roots, plugin loaded"
            '';
          };

          # The parser rewrite is only as trustworthy as the round-trip
          # between the parsed lock and the raw bytes. `passthru` throws on
          # any mismatch, so merely evaluating this attribute is the check.
          roundtrip = opencode.passthru.bunLockRoundtrip;
        in
        {
          opencode = opencode;
          opencode-version = opencode.passthru.tests.version;

          opencode-behaviour = pkgs.runCommand "check-opencode-behaviour" { } ''
            ${pkgs.lib.getExe behaviourScript}
            ${pkgs.lib.getExe' pkgs.coreutils "touch"} $out
          '';

          bun-lock-roundtrip = pkgs.runCommand "check-bun-lock-roundtrip"
            {
              inherit roundtrip;
            } ''
            test "$roundtrip" = ok
            ${pkgs.lib.getExe' pkgs.coreutils "touch"} $out
          '';

          # ── Dead code detection ───────────────────────────────────────────
          # Same mechanism as LLM-CORE's check: `--no-lambda-pattern-names`
          # keeps function argument sets (`{ pkgs, system }`) from being
          # reported as dead bindings.
          deadnix = pkgs.writeShellApplication {
            name = "run-deadnix";
            meta.description = "Detect dead Nix code";
            runtimeInputs = [ pkgs.deadnix ];
            text = ''exec ${pkgs.lib.getExe pkgs.deadnix} --no-lambda-pattern-names "${self}"'';
          };

          # ── Format check ──────────────────────────────────────────────────
          formatting = pkgs.runCommand "check-formatting"
            { buildInputs = [ pkgs.nixpkgs-fmt ]; }
            "${pkgs.lib.getExe pkgs.nixpkgs-fmt} --check ${self} && ${pkgs.lib.getExe' pkgs.coreutils "touch"} $out";
        }
      );
    };
}
