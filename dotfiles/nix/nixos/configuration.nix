# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

let
  username = "josh";
  myuid = 1000;
in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./nvidia.nix
      ./gigabyte-sleepfix.nix
      ./nvidia-pm.nix
      <home-manager/nixos>
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # use the latest linux kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "methyl"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.networkmanager.enable = true;
  networking.firewall = {
    enable = false;
    # networking.firewall.allowedTCPPorts = [ ... ];
    # networking.firewall.allowedUDPPorts = [ ... ];
  };

  # Set your time zone.
  time.timeZone = "America/Denver";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing = {
    enable = true;
    drivers = with pkgs; [ brlaser ];
  };

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    wireplumber.enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    cifs-utils
    fish
    wget
    curl
    neovim
    home-manager
    firefox
    kdePackages.kate
    # container stuff
    dive
    podman-tui
    podman-compose
  ];
  

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.${username} = {
    isNormalUser = true;
    description = "${username}";
    uid = myuid;
    extraGroups = [ "networkmanager" "wheel" "input" ];
    packages = with pkgs; [
    ];
  };

  hardware = {
    bluetooth.enable = true;
    steam-hardware.enable = true;
  };
  programs.steam = {
    enable = true;
    extest.enable = true;
  };
  
  # enable containers via podman
  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers = {
      backend = "podman";
      # define containers to be started as systemd services below
      # 
      # container-name = {
      #   image = "..."
      #   autoStart = true;
      #   ports = [ "ip:port:port" ];
      # };
    };
  };

  # enable flatpak support
  services.flatpak.enable = true;
  systemd.services.flatpak-repo = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.flatpak ];
    script = ''
      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    '';
  };

  # enable appimage support
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # enable user configured nvidia support
  nvidia.enable = true;
  # enable gigabyte usb s3 wakeup fix
  services.sleepfix.enable = true;
  # enable nvidiapm helper
  services.nvidiapm.enable = true;

  services.gvfs.enable = true;
  fileSystems = let
    mygid = toString config.users.groups.users.gid;
    automount_opts = "credentials=/etc/nixos/.smb-secrets,uid=${toString myuid},gid=${mygid},dir_mode=0770,file_mode=0660,x-systemd.automount,noauto,x-systemd.idle-timeout=300,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";
  in
    {
      "/mnt/home" = {
        device = "//192.168.1.153/home";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
      "/mnt/FTPRoot" = {
        device = "//192.168.1.153/FTPRoot";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
      "/mnt/Downloads" = {
        device = "//192.168.1.153/Downloads";
        fsType = "cifs";
        options = ["${automount_opts}"];
      };
    };

  nixpkgs.config.allowUnfree = true;
  home-manager.useGlobalPkgs = true;
  programs.fish.enable = true;
    programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  system.stateVersion = "24.11";
}
