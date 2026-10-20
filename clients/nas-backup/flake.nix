{
  description = "DealScout Outbound NAS Backup Client & NixOS Module";

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
            ${builtins.readFile ./dealscout_backup_client.py}
          '';
        }
      );

      nixosModules.default = import ./module.nix;
      nixosModules.backup = import ./module.nix;
    };
}
