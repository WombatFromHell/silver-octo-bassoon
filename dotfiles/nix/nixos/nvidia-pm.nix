{ config, lib, pkgs, ... }:

let
  smiPath = "${pkgs.linuxPackages.nvidia_x11.bin}/bin/nvidia-smi";
  scriptPath = pkgs.writeScriptBin "nvidiapm" ''
#!${pkgs.stdenv.shell}
NVIDIASMI="${smiPath}"
BASE_PL="320"
PYTHON="${pkgs.python3}/bin/python3"

do_math() {
  "$PYTHON" -c "from decimal import Decimal, ROUND_HALF_UP; print(int((Decimal(\"$1\") * Decimal(\"$2\")).quantize(Decimal('1'), rounding=ROUND_HALF_UP)))"
}

underclock() {
  "$NVIDIASMI" -pl "$1"
}
undo() {
  "$NVIDIASMI" -pl "$BASE_PL"
  "$NVIDIASMI" -rgc
  "$NVIDIASMI" -rmc
}

"$NVIDIASMI" -pm 1
[ "$1" != "undo" ] && undo

if [ "$1" == "high" ]; then
  underclock "$BASE_PL"
elif [ "$1" == "med" ]; then
  limit="$(do_math $BASE_PL 0.8)" # 80%
  underclock "$limit"
elif [ "$1" == "low" ]; then
  limit="$(do_math $BASE_PL 0.72)" # 72%
  underclock "$limit"
elif [ "$1" == "vlow" ]; then
  limit="$(do_math $BASE_PL 0.6)" # 60%
  underclock "$limit"
elif [ "$1" == "xlow" ]; then
  limit="$(do_math $BASE_PL 0.4)" # 40%
  underclock "$limit"
elif [ "$1" == "undo" ]; then
  undo
fi
'';
in
{
  options = {
    services.nvidiapm.enable = lib.mkEnableOption "NVIDIA Power Limit Service";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.nvidia.enable && config.services.nvidiapm.enable) {
        systemd.services.nvidiapm = {
          description = "NVIDIA Power Limit Service";
          wantedBy = [ "default.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${scriptPath}/bin/nvidiapm low";
            ExecStop = "${scriptPath}/bin/nvidiapm undo";
            RemainAfterExit = "yes";
          };
        };

        systemd.timers.nvidiapm = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = 5;
          };
        };
    })

    (lib.mkIf (!config.nvidia.enable && config.services.nvidiapm.enable) {
      warnings = [
        "The systemd unit 'nvidiapm' is enabled but requires 'nvidia.enable', and will not function without it!"
      ];
    })
  ];
}
