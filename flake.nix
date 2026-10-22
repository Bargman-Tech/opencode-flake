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
        {
          opencode = self.packages.${system}.opencode;
          opencode-version = self.packages.${system}.opencode.passthru.tests.version;

          # ── Dead code detection ───────────────────────────────────────────
          # Same mechanism as LLM-CORE's check: `--no-lambda-pattern-names`
          # keeps function argument sets (`{ pkgs, system }`) from being
          # reported as dead bindings.
          deadnix = pkgs.writeShellApplication {
            name = "run-deadnix";
            meta.description = "Detect dead Nix code";
            runtimeInputs = [ pkgs.deadnix ];
            text = ''exec deadnix --no-lambda-pattern-names "${self}"'';
          };

          # ── Format check ──────────────────────────────────────────────────
          formatting = pkgs.runCommand "check-formatting"
            { buildInputs = [ pkgs.nixpkgs-fmt ]; }
            "nixpkgs-fmt --check ${self} && touch $out";
        }
      );
    };
}
