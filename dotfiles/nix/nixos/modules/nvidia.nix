{
  config,
  lib,
  pkgs,
  ...
}: {
  options = {
    nvidia.enable = lib.mkEnableOption "User configured NVIDIA driver module";
  };
  config = lib.mkIf config.nvidia.enable {
    services.xserver.videoDrivers = ["nvidia"];

    hardware = {
      graphics = {
        enable = true;
        extraPackages = with pkgs; [
          nvidia-vaapi-driver
        ];
      };
      # opengl.enable = true;
      nvidia = {
        modesetting.enable = true;
        powerManagement.enable = true;
        open = true;
        nvidiaSettings = true;
        package = config.boot.kernelPackages.nvidiaPackages.latest;
      };
    };

    # enable nvidia-container-toolkit support (podman)
    virtualisation.docker.rootless.daemon.settings.features.cdi = true;
  };
}
