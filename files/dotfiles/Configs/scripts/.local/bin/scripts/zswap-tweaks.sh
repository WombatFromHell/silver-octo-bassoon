#!/usr/bin/env bash
# zswap-tweaks.sh: memory tuning for a zswap + big-resident-model workstation. Idempotent.
#
#   --install          apply the sysctl / sysfs / systemd tweaks (original values snapshotted first)
#   --uninstall        remove everything this script manages, including swapfiles it created, and
#                      restore the snapshot
#   --swapfile FILE    create FILE as swap (btrfs/xfs/ext4 aware) and activate it with a systemd
#                      .swap unit. --size SIZE (e.g. 8G) overrides min(25% of RAM, 16G).
#
# `--selftest` checks the size arithmetic and needs no root. Sourcing this file defines the
# functions without running anything.
set -euo pipefail
shopt -s inherit_errexit

readonly TAG='# Managed by zswap-tweaks.sh' # first line of every unit/conf we own; uninstall greps for it
readonly SWAP_PCT=25 SWAP_MAX=16G MIB=1048576

# zswap pool cap. This box: ~21GB weights + ~3GB runtime leaves ~6GB for the desktop, so the
# default 20% cap (6GB) could eat all of it. 10% (3GB) holds ~9GB of pages at 3:1 and the
# shrinker pushes the rest to swap. accept_threshold and shrinker are already kernel defaults.
readonly POOL_PCT=10

# memory.low for the session slice. strata runs rootless in this UID's tree and maps a large
# resident arena into the GPU. memory.low only biases reclaim (it never pins a page), and the
# kernel ignores it when nothing unprotected is reclaimable, so 80% of usable RAM is the
# ceiling. MemoryMin= would make the pages exclusive and cause constant OOMs, so it stays unset.
# The arena's real guarantee is mlock/GTT, not a cgroup limit.
readonly MEMLOW=24G

# One table drives everything: the generated sysctl.d / tmpfiles.d files, the snapshot, the
# restore allowlist. Columns: kind, key, value, upstream default.
#  - value "-" means "snapshot and restore, never change".
#  - the default column only seeds the snapshot when an older version of this script already
#    applied the tweaks (live values are then no longer the originals).
#  - ratios sit before bytes on purpose: restoring a *_ratio zeroes the matching *_bytes, and
#    writing an unchanged *_bytes is a no-op, so restore round-trips whichever pair was in effect.
#  - dirty limits are bytes, not ratios: 5%/15% of a large RAM figure is multiple GB of dirty data.
#  - compressor: set a value to switch (zstd gives the best ratio; also consider zswap.compressor=
#    on the kernel cmdline so an lzo pool is not built first). lru_gen cuts the cost of each
#    reclaim scan. THP stays off automatic promotion because khugepaged migrating pages
#    invalidates the arena's KFD userptr without any swap.
tweaks=(
  "sysctl vm.swappiness                 30         60"
  "sysctl vm.page-cluster               0          3"
  "sysctl vm.watermark_scale_factor     125        10"
  "sysctl vm.watermark_boost_factor     0          15000"
  "sysctl vm.compaction_proactiveness   0          20"
  "sysctl vm.dirty_background_ratio     -          10"
  "sysctl vm.dirty_ratio                -          20"
  "sysctl vm.dirty_background_bytes     268435456  0"
  "sysctl vm.dirty_bytes                1073741824 0"
  "sysctl vm.max_map_count              1048576    65530"
  "sysfs  /sys/module/zswap/parameters/compressor          -        zstd"
  "sysfs  /sys/module/zswap/parameters/max_pool_percent    $POOL_PCT 20"
  "sysfs  /sys/kernel/mm/lru_gen/enabled                   y        0"
  "sysfs  /sys/kernel/mm/transparent_hugepage/enabled      madvise  always"
)

changed=0 # set by put() whenever it rewrites a file; gates daemon-reload

warn() { echo "$*" >&2; }
die() {
  warn "$*"
  exit 1
}
usage() { die "usage: ${0##*/} --install | --uninstall | --swapfile FILE [--size SIZE]"; }

# put PATH < content: install stdin at PATH iff it differs. Never pipe into it (subshell
# would lose `changed`); use a heredoc or `< <(...)`.
put() {
  local path=$1 content
  content=$(cat)
  if [[ -e $path && $(<"$path") == "$content" ]]; then
    echo "unchanged $path"
  else
    printf '%s\n' "$content" | install -D -m 644 /dev/stdin "$path"
    echo "updated   $path"
    changed=1
  fi
}

# emit KIND: this kind's changing tweaks, rendered as config lines.
emit() {
  local kind key val _
  while read -r kind key val _; do
    [[ $kind == "$1" && $val != - ]] || continue
    case $kind in
    sysctl) echo "$key = $val" ;;
    sysfs) echo "w $key - - - - $val" ;;
    esac
  done < <(printf '%s\n' "${tweaks[@]}")
}

# known KIND KEY: is this a knob in the table? Gate for everything read back from the snapshot.
known() {
  local kind key _
  while read -r kind key _; do
    [[ $kind == "$1" && $key == "$2" ]] && return 0
  done < <(printf '%s\n' "${tweaks[@]}")
  return 1
}

# live KIND KEY: current value; for "always [madvise] never" files, the bracketed word.
live() {
  local v
  case $1 in
  sysfs)
    v=$(<"$2") || return 1
    if [[ $v == *\[*\]* ]]; then
      v=${v#*\[}
      v=${v%%\]*}
    fi
    echo "$v"
    ;;
  sysctl) sysctl -n "$2" 2>/dev/null ;;
  esac
}

# Record original values once. Never overwritten, so re-runs can't capture our own tweaks.
# Written *as the owner*: root writing into a user-controlled path would follow a planted symlink.
snapshot() {
  [[ -e $state ]] && return 0
  local seeded=0 p kind key default val
  for p in "${managed[@]}"; do
    if [[ -e $p ]]; then seeded=1; fi
  done
  runuser -u "$owner" -- mkdir -p "${state%/*}"
  {
    if ((seeded)); then
      echo "# Seeded from upstream kernel defaults (tweaks were already applied before this"
      echo "# snapshot existed). Edit the values below if your distro's defaults differ."
    else
      echo "# Captured by zswap-tweaks.sh before the first install."
    fi
    echo "# format: sysfs|sysctl <path-or-key> <value>"
    while read -r kind key _ default; do
      val=$(live "$kind" "$key") || continue # knob absent on this kernel
      if ((seeded)); then val=$default; fi
      echo "$kind $key $val"
    done < <(printf '%s\n' "${tweaks[@]}")
  } | runuser -u "$owner" -- tee -- "$state" >/dev/null
  echo "saved original values to $state"
}

# The snapshot is user-writable and we are root: only restore known knobs with tame values.
restore_snapshot() {
  local kind key val
  while read -r kind key val; do
    if [[ -z $kind || $kind == \#* ]]; then continue; fi
    if ! known "$kind" "$key" || ! [[ $val =~ ^[[:alnum:]._-]+$ ]]; then
      warn "restore: ignoring '$kind $key $val'"
      continue
    fi
    case $kind in
    sysfs) if [[ -w $key ]]; then echo "$val" >"$key" || warn "restore: could not write $key"; fi ;;
    sysctl) sysctl -qw "$key=$val" || warn "restore: could not set $key" ;;
    esac
  done <"$state"
  rm -f "$state"
  echo "restored original values from snapshot"
}

# set_memlow BYTES: write the live cgroup value. systemd only applies drop-in changes when the
# slice (re)starts, and restarting user@UID.service would kill the login session.
set_memlow() {
  local f=/sys/fs/cgroup/user.slice/user-$uid.slice/memory.low
  if [[ ! -w $f ]]; then
    warn "memory.low not writable; takes effect at next login"
  elif [[ $(<"$f") != "$1" ]]; then echo "$1" >"$f"; fi
}

install_tweaks() {
  snapshot
  put /etc/sysctl.d/99-memory.conf < <(
    echo "$TAG"
    emit sysctl
  )
  put /etc/tmpfiles.d/zswap.conf < <(
    echo "$TAG"
    emit sysfs
  )

  # Slice bounds mirrored from /usr/lib/systemd/system/*.slice.d/override.conf so the box is
  # reproducible from this script alone; /etc drop-ins win for the same keys.
  # Nothing in oomd bounds RAM (it reacts to PSI and swap fractions), so MemoryMax= on the root
  # slice is the ceiling that stops a RAM hog filling the machine; MemoryHigh= is the throttle
  # band where reclaim goes aggressive and pages spill to zswap and then to swap. Percentages
  # track installed RAM, so one default holds on a 32GB host and on a small VM.
  put /etc/systemd/system/-.slice.d/99-zswap-tweaks.conf <<EOF
$TAG
[Slice]
ManagedOOMSwap=kill
MemoryHigh=94%
MemoryMax=96.5%
EOF

  # oomd picks swap candidates by swap usage across the session tree and only honours
  # ManagedOOMPreference= on them when the cgroup is root-owned, so none is set here.
  put /etc/systemd/system/user.slice.d/99-zswap-tweaks.conf <<EOF
$TAG
[Slice]
ManagedOOMSwap=kill
EOF

  # A boundary on the container itself would be capped by its ancestors' memory.low=0
  # (cgroup-v2 "Reclaim Protection"), so the protection sits on the per-user slice.
  put "/etc/systemd/system/user-$uid.slice.d/99-strata-memprotect.conf" <<EOF
$TAG
[Slice]
MemoryLow=$MEMLOW
EOF

  if ((changed)); then systemctl daemon-reload; fi
  sysctl -p /etc/sysctl.d/99-memory.conf >/dev/null
  systemd-tmpfiles --create /etc/tmpfiles.d/zswap.conf
  set_memlow "$(numfmt --from=iec "$MEMLOW")"

  echo
  grep -r . /sys/module/zswap/parameters/ | sed 's|/sys/module/zswap/parameters/||'
}

uninstall() {
  local u f p units
  # Swapfile .swap/.mount units are generated per path, so find them by their tag, not by name.
  mapfile -t units < <(grep -lxF -- "$TAG" /etc/systemd/system/*.swap /etc/systemd/system/*.mount 2>/dev/null || true)
  for u in "${units[@]}"; do
    [[ $u == *.swap ]] || continue # a .mount only mirrors a mount that predates us: never stop it
    f=$(sed -n 's/^What=//p' "$u")
    systemctl disable --now "${u##*/}" # also runs swapoff; failure aborts before we delete anything
    if [[ $(blkid -p -o value -s TYPE "$f" 2>/dev/null) == swap ]]; then
      rm -f "$f"
      echo "removed   $f"
    fi
  done
  rm -f -- "${managed[@]}" "${units[@]}"
  for p in "${managed[@]}"; do
    if [[ ${p%/*} == *.slice.d ]]; then rmdir "${p%/*}" 2>/dev/null || true; fi
  done
  systemctl daemon-reload

  if [[ -r $state ]]; then
    restore_snapshot
  else warn "uninstall: no snapshot at $state; live values stay until the next boot"; fi

  # Re-apply whichever sysctl files remain (distro ones and anything we never owned).
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors (not fatal)"
  set_memlow 0
  echo "uninstalled"
}

# swap_bytes RAM_BYTES [SIZE]: SIZE if given, else min(SWAP_PCT% of RAM, SWAP_MAX); MiB-aligned.
swap_bytes() {
  local b max
  if [[ -n ${2:-} ]]; then
    b=$(numfmt --from=iec "$2")
  else
    b=$(($1 * SWAP_PCT / 100))
    max=$(numfmt --from=iec "$SWAP_MAX")
    if ((b > max)); then b=$max; fi
  fi
  echo $((b / MIB * MIB))
}

# mkswapfile FILE BYTES FSTYPE: preallocate and format; removes the partial file on any failure
# so a re-run starts clean instead of tripping the "exists and is not swap" guard.
mkswapfile() {
  local file=$1 bytes=$2 fstype=$3 avail
  avail=$(df --output=avail -B1 -- "$(dirname -- "$file")" | tail -n1)
  ((avail > bytes)) || die "not enough free space for $((bytes / MIB))M on ${file%/*}"
  if ! {
    (
      umask 077
      : >"$file"
    ) &&                                                  # swapon rejects world-readable files
      { [[ $fstype != btrfs ]] || chattr +C "$file"; } && # NOCOW (also stops compression); only legal while empty
      fallocate -l "$bytes" "$file" &&                    # no holes: swapon refuses sparse files
      mkswap -q "$file"
  }; then
    rm -f "$file"
    die "could not create $file"
  fi
  echo "created   $file ($((bytes / MIB))M on $fstype)"
}

# mount_unit DIR FSTYPE: pin DIR's mount in a unit, but only when DIR is its own mount point
# that nothing else defines (not fstab, not an existing unit, not the root fs). The swapfile
# then orders after exactly this mount; otherwise RequiresMountsFor= on the swap unit suffices.
mount_unit() {
  local dir=$1 fstype=$2 unit frag uuid fsroot opts=noatime
  if [[ $dir == / ]] || ! mountpoint -q "$dir"; then return 0; fi
  unit=$(systemd-escape -p --suffix=mount "$dir")
  frag=$(systemctl show -P FragmentPath "$unit")
  if [[ -n $frag && $frag != "/etc/systemd/system/$unit" ]]; then
    echo "skip      $unit (already defined by $frag)"
    return 0
  fi
  read -r uuid fsroot < <(findmnt -no UUID,FSROOT --mountpoint "$dir")
  if [[ -z $uuid ]]; then
    warn "skip      $unit (no filesystem UUID)"
    return 0
  fi
  if [[ $fstype == btrfs && $fsroot != / ]]; then opts+=",subvol=$fsroot"; fi
  put "/etc/systemd/system/$unit" <<EOF
$TAG
[Unit]
Description=Swap directory $dir

[Mount]
What=/dev/disk/by-uuid/$uuid
Where=$dir
Type=$fstype
Options=$opts
EOF
}

swapfile() {
  local file dir fstype bytes unit
  file=$(realpath -m -- "$1")
  [[ $file != *[[:space:]]* ]] || die "$file: whitespace in the path is not supported"
  dir=$(dirname -- "$file")
  [[ -d $dir ]] || die "$dir: no such directory"
  fstype=$(findmnt -no FSTYPE -T "$dir")
  case $fstype in
  btrfs | xfs | ext4) ;;
  *) die "$fstype: not supported for a swapfile (btrfs, xfs or ext4 only)" ;;
  esac
  bytes=$(swap_bytes "$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)" "${2:-}")
  ((bytes >= MIB)) || die "swapfile size must be at least 1M"

  if [[ -e $file ]]; then
    # Only ever recreate something that is already a swap area; never clobber a user's file.
    [[ $(blkid -p -o value -s TYPE "$file" 2>/dev/null) == swap ]] || die "$file exists and is not a swapfile; refusing to touch it"
    if (($(stat -c %s "$file") == bytes)); then
      echo "unchanged $file"
    else
      echo "resizing  $file"
      if swapon --noheadings --show=NAME | grep -qxF -- "$file"; then swapoff "$file"; fi
      rm -f "$file"
    fi
  fi
  if [[ ! -e $file ]]; then mkswapfile "$file" "$bytes" "$fstype"; fi

  unit=$(systemd-escape -p --suffix=swap "$file")
  mount_unit "$dir" "$fstype"
  put "/etc/systemd/system/$unit" <<EOF
$TAG
[Unit]
Description=Swapfile $file
RequiresMountsFor=$dir

[Swap]
What=$file

[Install]
WantedBy=swap.target
EOF
  if ((changed)); then systemctl daemon-reload; fi
  systemctl enable --now "$unit"
  swapon --show
}

# The one runnable check: the only non-trivial arithmetic in here.
selftest() {
  local g=$((1 << 30))
  [[ $(swap_bytes $((8 * g))) == $((2 * g)) ]] || die "selftest: 8G RAM should give 2G"
  [[ $(swap_bytes $((128 * g))) == $((16 * g)) ]] || die "selftest: 128G RAM should cap at 16G"
  [[ $(swap_bytes 0 3G) == $((3 * g)) ]] || die "selftest: explicit --size should win"
  [[ $(swap_bytes $((g + 1))) == $((g / 4 / MIB * MIB)) ]] || die "selftest: result must be MiB-aligned"
  known sysctl vm.swappiness || die "selftest: allowlist should accept a table knob"
  ! known sysctl vm.nope || die "selftest: allowlist should reject an unknown knob"
  echo "selftest ok"
}

main() {
  local args=("$@") action='' file='' size=''
  set_action() {
    [[ -z $action ]] || usage
    action=$1
  }
  while (($#)); do
    case $1 in
    --install | --uninstall) set_action "${1#--}" ;;
    --swapfile)
      (($# > 1)) || usage
      set_action swapfile
      file=$2
      shift
      ;;
    --size)
      (($# > 1)) || usage
      size=$2
      shift
      ;;
    --selftest)
      selftest
      return
      ;;
    *) usage ;;
    esac
    shift
  done
  [[ -n $action ]] || usage

  ((EUID == 0)) || exec sudo -- "$0" "${args[@]}"

  # The snapshot lives in the invoking user's home, not root's.
  owner=${SUDO_USER:-root}
  uid=$(id -u "$owner")
  state=$(getent passwd "$owner" | cut -d: -f6)/.local/share/zswap-tweaks-orig.txt
  # Static files this script owns (swapfile units are found by TAG instead).
  managed=(
    /etc/sysctl.d/99-memory.conf
    /etc/tmpfiles.d/zswap.conf
    /etc/systemd/system/-.slice.d/99-zswap-tweaks.conf
    /etc/systemd/system/user.slice.d/99-zswap-tweaks.conf
    "/etc/systemd/system/user-$uid.slice.d/99-strata-memprotect.conf"
  )

  case $action in
  install) install_tweaks ;;
  uninstall) uninstall ;;
  swapfile) swapfile "$file" "$size" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
