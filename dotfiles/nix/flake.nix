{
  description = "Unified NixOS and Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    chaotic,
    home-manager,
    ...
  }:
    flake-parts.lib.mkFlake {
      inherit inputs;
    } {
      systems = ["x86_64-linux"];

      flake = let
        sharedArgs = {
          username = "josh";
          myuid = 1000;
          hostname = "methyl";
        };
      in {
        nixosConfigurations.${sharedArgs.hostname} = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {inherit sharedArgs;};
          modules = [
            chaotic.nixosModules.default

            ./nixos/configuration.nix
            ./nixos/modules/nvidia.nix
            ./nixos/modules/gigabyte-sleepfix.nix
            ./nixos/modules/nvidia-pm.nix
            ./nixos/modules/mounts.nix

            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {inherit sharedArgs;};
                users.${sharedArgs.username} = import ./home/home.nix;
              };
            }
          ];
        };
      };
    };
}
