{
  config,
  pkgs,
  ...
}: let
  username = "josh";
in {
  home.username = "${username}";
  home.homeDirectory = "/home/${username}";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [
    # nerd fonts
    nerd-fonts.meslo-lg
    nerd-fonts.jetbrains-mono
    nerd-fonts.caskaydia-cove
    # common programs
    direnv
    nix-direnv
    wl-clipboard
    git
    fish
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

  programs.gpg.enable = true;

  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;
    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  home.sessionVariables = {
  };

  programs.home-manager.enable = true;
}
