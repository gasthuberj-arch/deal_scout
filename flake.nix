{
  description = "DealScout - Real-Time RSS Deal Tracker & NAS Backup Module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonEnv = pkgs.python3.withPackages (ps: [ ps.websockets ]);
        in {
          default = pkgs.writeScriptBin "dealscout-backup-client" ''
            #!${pythonEnv}/bin/python3
            ${builtins.readFile ./clients/nas-backup/dealscout_backup_client.py}
          '';
          backupClient = self.packages.${system}.default;
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          beamPkgs = pkgs.beam.packages.erlang_29;
        in {
          default = pkgs.mkShell {
            packages = [
              beamPkgs.elixir_1_20
              beamPkgs.erlang
              beamPkgs.rebar3
              pkgs.git
            ];

            shellHook = ''
              export MIX_REBAR3="${beamPkgs.rebar3}/bin/rebar3"
            '';
          };
        }
      );

      nixosModules = {
        default = import ./clients/nas-backup/module.nix;
        backup = import ./clients/nas-backup/module.nix;
      };
    };
}
