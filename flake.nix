{
  description =
    "NixOps: a tool for deploying to [NixOS](https://nixos.org) machines in a network or the cloud";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        pythonEnv = (pkgs.poetry2nix.mkPoetryEnv {
          projectDir = ./.;
          python = pkgs.python38;
        });
        linters.doc = pkgs.writers.writeBashBin "lint-docs" ''
          set -eux
          # When running it in the Nix sandbox, there is no git repository
          # but sources are filtered.
          if [ -d .git ];
          then
              FILES=$(${pkgs.git}/bin/git ls-files)
          else
              FILES=$(find .)
          fi
          echo "$FILES" | xargs ${pkgs.codespell}/bin/codespell -L keypair,iam,hda
          ${pythonEnv}/bin/sphinx-build -M clean doc/ doc/_build
          ${pythonEnv}/bin/sphinx-build -n doc/ doc/_build
        '';

      in {
        devShell = pkgs.mkShell {
          buildInputs = [
            pkgs.codespell
            pkgs.nixFlakes
            pkgs.nixfmt
            pkgs.openssh
            pkgs.poetry

            pkgs.rsync # Included by default on NixOS
            pythonEnv
          ] ++ (builtins.attrValues linters);

          shellHook = ''
            export PATH=${builtins.toString ./scripts}:$PATH
          '';
        };

        defaultPackage =
          let overrides = import ./overrides.nix { inherit pkgs; };

          in pkgs.poetry2nix.mkPoetryApplication {
            projectDir = ./.;

            propagatedBuildInputs = [ pkgs.openssh pkgs.rsync ];

            overrides = [ pkgs.poetry2nix.defaultPoetryOverrides overrides ];

            # TODO: Re-add manual build
          };

        nixosOptions = pkgs.nixosOptionsDoc {
          inherit (pkgs.lib.fixMergeModules
            [ ./nixops_digitalocean/nix/default.nix ] {
              inherit pkgs;
              name = "<name>";
              uuid = "<uuid>";
            })
            options;
        };

        rstNixosOptions = let
          oneRstOption = name: value: ''
            ${name}
            ${pkgs.lib.concatStrings
            (builtins.genList (_: "-") (builtins.stringLength name))}

            ${value.description}

            ${pkgs.lib.optionalString (value ? readOnly) ''
              Read Only
            ''}

            :Type: ${value.type}

            ${pkgs.lib.optionalString (value ? default) ''
              :Default: ${builtins.toJSON value.default}
            ''}

            ${pkgs.lib.optionalString (value ? example) ''
              :Example: ${builtins.toJSON value.example}
            ''}
          '';
          text = ''
            NixOps Options
            ==============
          '' + pkgs.lib.concatStringsSep "\n"
            (pkgs.lib.mapAttrsToList oneRstOption
              self.nixosOptions.${pkgs.system}.optionsNix);
        in pkgs.writeText "options.rst" text;

        docs = pkgs.stdenv.mkDerivation {
          name = "nixops-docs";
          # we use cleanPythonSources because the default gitignore
          # implementation doesn't support the restricted evaluation
          src = pkgs.poetry2nix.cleanPythonSources { src = ./.; };

          buildPhase = ''
            cp ${self.rstNixosOptions.${pkgs.system}} doc/manual/options.rst
            ${pythonEnv}/bin/sphinx-build -M clean doc/ doc/_build
            ${pythonEnv}/bin/sphinx-build -n doc/ doc/_build
          '';

          installPhase = ''
            mv doc/_build $out
          '';
        };

        checks.doc = pkgs.stdenv.mkDerivation {
          name = "lint-docs";
          # we use cleanPythonSources because the default gitignore
          # implementation doesn't support the restricted evaluation
          src = pkgs.poetry2nix.cleanPythonSources { src = ./.; };
          dontBuild = true;
          installPhase = ''
            ${linters.doc}/bin/lint-docs | tee $out
          '';
        };
      });
}
