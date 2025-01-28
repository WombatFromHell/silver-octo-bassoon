{
  config,
  lib,
  pkgs,
  sharedArgs,
  ...
}: let
  user = sharedArgs.username;
in {
  nix = {
    settings.experimental-features = ["nix-command" "flakes"];
    # gc = {
    #   automatic = true;
    #   dates = "weekly";
    #   options = "--delete-older-than 1w";
    # };
  };
  nixpkgs.config.allowUnfree = true;

  # NOTE: make sure to copy in/out your hardware-configuration.nix!
  imports = [./hardware-configuration.nix];

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    kernelPackages = pkgs.linuxPackages_latest;
    # provide some chaotic-nyx niceties
    # NOTE: enable these only after the first 'rebuild'
    # kernelPackages = pkgs.linuxPackages_cachyos;
    # services.scx.enable = true;

    kernelModules = ["i2c-dev"];
    kernelParams = [
      "amd_pstate=active"
      "acpi_enforce_resources=lax"
    ];
  };

  networking = {
    hostName = host;
    networkmanager.enable = true;
    firewall.enable = false;
  };

  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    priority = 100;
    memoryPercent = 13;
  };

  services = {
    earlyoom.enable = true;

    xserver.enable = true;
    displayManager.sddm.enable = true;
    desktopManager.plasma6.enable = true;
    xserver.xkb.layout = "us";

    sshd.enable = true;

    printing = {
      enable = true;
      # provide the brother printer lpd's
      drivers = with pkgs; [brlaser];
    };

    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      wireplumber.enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    flatpak.enable = true;
    ollama.enable = true;
  };
  security.rtkit.enable = true;

  environment.systemPackages = with pkgs; [
    cifs-utils
    fish
    wget
    curl
    neovim
    nh
    dive
    podman-tui
    podman-compose
  ];

  users.users.${user} = {
    isNormalUser = true;
    description = "${user}";
    uid = myuid;
    extraGroups = ["networkmanager" "wheel" "input" "i2c"];
  };

  hardware.bluetooth.enable = true;
  hardware.steam-hardware.enable = true;

  programs = {
    steam.enable = true;
    appimage.enable = true;

    nh = {
      enable = true;
      clean.enable = true;
      clean.extraArgs = "--keep-since 7d --keep 3";
      flake = "/home/${user}/.dotfiles/nix";
    };

    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };

  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  systemd.services.flatpak-repo = {
    wantedBy = ["multi-user.target"];
    path = [pkgs.flatpak];
    script = ''
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    '';
  };

  system.stateVersion = "24.11";
}
