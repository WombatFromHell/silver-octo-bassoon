#!/usr/bin/env bash
# zswap-tweaks.sh: idempotent; safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

# Install stdin to <path> only if the content differs. Returns 0 if changed.
install_if_changed() {
  local path="$1" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m 644 "$tmp" "$path"
  rm -f "$tmp"
}

install_if_changed /etc/sysctl.d/99-memory.conf <<'EOF' && echo "updated 99-memory.conf" || echo "99-memory.conf unchanged"
# Managed by zswap-tweaks.sh
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_scale_factor = 125
vm.watermark_boost_factor = 0
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF

install_if_changed /etc/tmpfiles.d/zswap.conf <<'EOF' && echo "updated zswap.conf" || echo "zswap.conf unchanged"
# Managed by zswap-tweaks.sh
w /sys/module/zswap/parameters/compressor                - - - - zstd
w /sys/module/zswap/parameters/max_pool_percent          - - - - 30
w /sys/module/zswap/parameters/accept_threshold_percent  - - - - 80
w /sys/module/zswap/parameters/shrinker_enabled          - - - - Y
w /sys/kernel/mm/lru_gen/enabled                         - - - - y
w /sys/kernel/mm/transparent_hugepage/enabled            - - - - madvise
EOF

# Apply now (harmless if nothing changed); both are also applied on every boot.
sysctl -p /etc/sysctl.d/99-memory.conf >/dev/null
systemd-tmpfiles --create /etc/tmpfiles.d/zswap.conf

echo
grep -r . /sys/module/zswap/parameters/ | sed 's|/sys/module/zswap/parameters/||'
