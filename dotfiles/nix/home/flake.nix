{
  description = "Home Manager Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    home-manager,
    ...
  }: let
    system = "x86_64-linux"; # Adjust if you're using a different system
    pkgs = nixpkgs.legacyPackages.${system};
    username = "josh";
  in {
    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;

      modules = [
        {
          home = {
            username = "${username}";
            homeDirectory = "/home/${username}";
            stateVersion = "24.11";
            packages = with pkgs; [
              # nerd fonts
              nerd-fonts.meslo-lg
              nerd-fonts.jetbrains-mono
              nerd-fonts.caskaydia-cove
              # common programs
              nh
              direnv
              nix-direnv
              wl-clipboard
              git
              fish
              dust
              fzf
              eza
              bat
              fd
              rdfind
              ripgrep
              zoxide
              python3
              # dev tools
              nil
              alejandra
            ];
          };

          programs = {
            gpg.enable = true;
            home-manager.enable = true;
          };

          home.file = {
            # Your file declarations here (currently empty as per original config)
          };

          home.sessionVariables = {
            # Your session variables here (currently empty as per original config)
          };
        }
      ];
    };
  };
}
