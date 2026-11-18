#!/usr/bin/env bash
# zswap-tweaks.sh: memory tuning for a zswap + big-resident-model workstation. Idempotent.
#
#   --install          apply the sysctl / sysfs / systemd tweaks (original values snapshotted first)
#   --uninstall        remove everything this script manages, including swapfiles it created
#                      (never ones it merely adopted), and restore the snapshot
#   --swapfile FILE    create FILE as swap (btrfs/xfs/ext4 aware) and activate it with a systemd
#                      .swap unit. --size SIZE (e.g. 8G) overrides min(25% of RAM, 16G).
#   --yes              answer yes to prompts (masking uresourced)
#
# `--selftest` checks the size arithmetic and file-ownership helpers and needs no root. Sourcing
# this file defines the functions without running anything.
set -euo pipefail
shopt -s inherit_errexit

readonly TAG='# Managed by zswap-tweaks.sh'                # first line of every unit/conf we own
readonly OWNED_TAG='# Swapfile created by zswap-tweaks.sh' # in a .swap unit iff we created the file
readonly SWAP_PCT=25 SWAP_MAX=16G MIB=1048576

# zswap pool cap. This box: ~21GB weights + ~3GB runtime leaves ~6GB for the desktop, so the
# default 20% cap (6GB) could eat all of it. 10% (3GB) holds ~9GB of pages at 3:1 and the
# shrinker pushes the rest to swap. accept_threshold and shrinker are already kernel defaults.
readonly POOL_PCT=10

# memory.low for the session slice. strata runs rootless in this UID's tree and maps a large
# resident arena into the GPU. memory.low only biases reclaim (it never pins a page), and the
# kernel ignores it when nothing unprotected is reclaimable, so keep it well below usable RAM
# (22G is ~73% of 30GB). MemoryMin= would make the pages exclusive and cause constant OOMs, so
# it stays unset. The arena's real guarantee is mlock/GTT, not a cgroup limit.
readonly MEMLOW=22G

# Ceiling for the whole user.slice (a cgroup that really has memory.max; the root cgroup does
# not). No MemoryHigh=: it would throttle the biggest allocator (strata) well before any danger.
readonly USER_MEMMAX=97%

# uresourced (Fedora/Bazzite) rewrites MemoryLow/MemoryMin/CPUWeight/IOWeight on the active
# user's slice at every session change; its set-property files outrank our drop-ins.
readonly URES=uresourced.service
readonly URES_MARK=/var/lib/zswap-tweaks/uresourced-masked # exists iff we masked it

# Static files this script owns. install_tweaks writes through these names and `managed` (built
# in init_identity) feeds uninstall and the snapshot check, so each path is spelled once. The
# slice files are named override.conf on purpose: a same-named /etc drop-in fully replaces the
# vendor one in /usr/lib. Swapfile units are found by TAG instead.
readonly SYSCTL_CONF=/etc/sysctl.d/99-memory.conf
readonly TMPFILES_CONF=/etc/tmpfiles.d/zswap.conf
readonly ROOT_SLICE_CONF=/etc/systemd/system/-.slice.d/override.conf
readonly USERS_SLICE_CONF=/etc/systemd/system/user.slice.d/override.conf

# Columns: kind, key, value, upstream default (the default only seeds the snapshot when an
# older run already applied the tweaks). Compressor belongs on the kernel cmdline:
# zswap.compressor=zstd.
#  - min_ttl_ms is MGLRU's thrash guard. If the working set cannot be kept for that long, the
#    kernel OOM killer may fire, and the victim would be strata. Drop the row if that worries you.
tweaks=(
  "sysctl vm.swappiness                                     60         60"
  "sysctl vm.vfs_cache_pressure                             50         100"
  "sysctl vm.page-cluster                                   0          3"
  "sysctl vm.watermark_scale_factor                         125        10"
  "sysctl vm.max_map_count                                  1048576    65530"
  # "sysfs  /sys/kernel/mm/lru_gen/min_ttl_ms                 300        300"
  "sysfs  /sys/module/zswap/parameters/max_pool_percent     $POOL_PCT  20"
  "sysfs  /sys/kernel/mm/transparent_hugepage/enabled       madvise    always"
)

changed=0 # set by put() whenever it rewrites a file; gates daemon-reload
assume_yes=0
# Filled in by init_identity (needs root, so not at source time).
owner='' uid='' state='' user_slice_conf=''
managed=()

warn() { echo "$*" >&2; }
die() {
  warn "$*"
  exit 1
}
usage() { die "usage: ${0##*/} --install | --uninstall | --swapfile FILE [--size SIZE] [--yes]"; }

# ours PATH: a regular file whose first line is our tag. Everything we edit or delete passes this.
ours() { [[ -f $1 && $(head -n1 -- "$1") == "$TAG" ]]; }

# confirm PROMPT: yes under --yes; no without a terminal (never block a pipe or cron).
confirm() {
  local ans
  if ((assume_yes)); then return 0; fi
  [[ -t 0 ]] || return 1
  read -r -p "$1 [y/N] " ans
  [[ $ans == [yY]* ]]
}

# put PATH < content: install stdin at PATH iff it differs. Never pipe into it (subshell
# would lose `changed`); use a heredoc or `< <(...)`. Refuses to overwrite files that aren't ours.
put() {
  local path=$1 content
  content=$(cat)
  if [[ -e $path ]] && ! ours "$path"; then die "refusing to overwrite $path (not managed by ${0##*/})"; fi
  if [[ -e $path && $(<"$path") == "$content" ]]; then
    echo "unchanged $path"
  else
    printf '%s\n' "$content" | install -D -m 644 /dev/stdin "$path"
    echo "updated   $path"
    changed=1
  fi
}

# init_identity: who we are tuning for. The snapshot lives in the invoking user's home, not root's.
init_identity() {
  owner=${SUDO_USER:-root}
  uid=$(id -u "$owner")
  state=$(getent passwd "$owner" | cut -d: -f6)/.local/share/zswap-tweaks-orig.txt
  user_slice_conf=/etc/systemd/system/user-$uid.slice.d/override.conf
  managed=("$SYSCTL_CONF" "$TMPFILES_CONF" "$ROOT_SLICE_CONF" "$USERS_SLICE_CONF" "$user_slice_conf")
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
    if ours "$p"; then seeded=1; fi
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

# disable_uresourced: mask the daemon that keeps resetting MemoryLow (asks first).
disable_uresourced() {
  [[ $(systemctl show -P LoadState "$URES") == loaded ]] || return 0 # absent or already masked
  warn "$URES resets MemoryLow on user-$uid.slice at every session change, undoing our protection."
  if ! confirm "Mask $URES (you lose its 500 CPU/IO weights and 250M MemoryMin)?"; then
    warn "skipped: MemoryLow will be reset to 0 at your next session change (use --yes to force)"
    return 0
  fi
  systemctl mask --now "$URES"
  install -d -m 755 "${URES_MARK%/*}"
  : >"$URES_MARK"
  changed=1
}

# clear_memlow_override: a set-property file in system.control outranks our /etc drop-in.
clear_memlow_override() {
  local f=/etc/systemd/system.control/user-$uid.slice.d/50-MemoryLow.conf
  if [[ -e $f ]]; then
    rm -f -- "$f"
    echo "removed   $f (it outranked our MemoryLow)"
    changed=1
  fi
}

install_tweaks() {
  snapshot
  put "$SYSCTL_CONF" < <(
    echo "$TAG"
    emit sysctl
  )
  put "$TMPFILES_CONF" < <(
    echo "$TAG"
    emit sysfs
  )

  # The root cgroup has no memory.high/memory.max, so limits on -.slice do nothing: it only
  # carries the oomd policy. oomd reacts to PSI and swap fractions, not to RAM size.
  put "$ROOT_SLICE_CONF" <<EOF
$TAG
[Slice]
ManagedOOMSwap=kill
EOF

  # oomd picks swap candidates by swap usage across the session tree and only honours
  # ManagedOOMPreference= on them when the cgroup is root-owned, so none is set here.
  put "$USERS_SLICE_CONF" <<EOF
$TAG
[Slice]
ManagedOOMSwap=kill
MemoryMax=$USER_MEMMAX
EOF

  # A boundary on the container itself would be capped by its ancestors' memory.low=0
  # (cgroup-v2 "Reclaim Protection"), so the protection sits on the per-user slice.
  put "$user_slice_conf" <<EOF
$TAG
[Slice]
MemoryLow=$MEMLOW
EOF

  disable_uresourced
  clear_memlow_override

  if ((changed)); then systemctl daemon-reload; fi
  sysctl -p "$SYSCTL_CONF" >/dev/null
  systemd-tmpfiles --create "$TMPFILES_CONF"
  set_memlow "$(numfmt --from=iec "$MEMLOW")"

  echo
  grep -r . /sys/module/zswap/parameters/ | sed 's|/sys/module/zswap/parameters/||'
}

# tagged_units: the .swap/.mount units we wrote. Units are generated per path, so find them by
# their first-line tag, not by name.
tagged_units() {
  local u
  for u in /etc/systemd/system/*.swap /etc/systemd/system/*.mount; do
    if ours "$u"; then echo "$u"; fi
  done
}

# check_swapoff_fits: swapoff reads every swapped page back into RAM; refuse when that cannot fit
# (plus a 2GiB margin), since the OOM killer would pick the biggest process.
check_swapoff_fits() {
  local used_kb avail_kb
  read -r used_kb avail_kb < <(awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {f=$2} /^MemAvailable:/ {a=$2} END {print t-f, a}' /proc/meminfo)
  ((used_kb * 1024 < avail_kb * 1024 - 2048 * MIB)) ||
    die "swap in use ($((used_kb / 1024))M) may not fit in available RAM ($((avail_kb / 1024))M); free memory first"
}

uninstall() {
  local u f p units=()
  mapfile -t units < <(tagged_units)
  for u in "${units[@]}"; do
    [[ $u == *.swap ]] || continue # a .mount only mirrors a mount that predates us: never stop it
    f=$(sed -n 's/^What=//p' "$u")
    check_swapoff_fits
    systemctl disable --now "${u##*/}" # also runs swapoff; failure aborts before we delete anything
    # Delete the file only if we created it; an adopted swapfile keeps its data.
    if grep -qxF -- "$OWNED_TAG" "$u" && [[ $(blkid -p -o value -s TYPE "$f" 2>/dev/null) == swap ]]; then
      rm -f -- "$f"
      echo "removed   $f"
    else
      echo "kept      $f (not created by this script)"
    fi
  done
  rm -f -- "${units[@]}"

  for p in "${managed[@]}"; do
    if ours "$p"; then
      rm -f -- "$p"
      echo "removed   $p"
    elif [[ -e $p ]]; then
      warn "leaving   $p (not managed by ${0##*/})"
    fi
    if [[ ${p%/*} == *.slice.d ]]; then rmdir "${p%/*}" 2>/dev/null || true; fi
  done
  systemctl daemon-reload

  if [[ -r $state ]]; then
    restore_snapshot
  else warn "uninstall: no snapshot at $state; live values stay until the next boot"; fi

  # Re-apply whichever sysctl files remain (distro ones and anything we never owned).
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported errors (not fatal)"
  if [[ -e $URES_MARK ]]; then
    systemctl unmask "$URES"
    rm -f -- "$URES_MARK"
    echo "unmasked  $URES"
  fi
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
# that nothing else defines (not fstab, not an existing unit of someone else's, not the root fs).
# The swapfile then orders after exactly this mount; otherwise RequiresMountsFor= on the swap
# unit suffices.
mount_unit() {
  local dir=$1 fstype=$2 unit frag uuid fsroot opts=noatime
  if [[ $dir == / ]] || ! mountpoint -q "$dir"; then return 0; fi
  unit=$(systemd-escape -p --suffix=mount "$dir")
  frag=$(systemctl show -P FragmentPath "$unit")
  if [[ -n $frag ]] && { [[ $frag != "/etc/systemd/system/$unit" ]] || ! ours "$frag"; }; then
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
  local file dir fstype bytes unit unit_path existed=0 owned=0
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

  # We own the file iff an earlier run created it (marked in its unit) or we create it below.
  unit=$(systemd-escape -p --suffix=swap "$file")
  unit_path=/etc/systemd/system/$unit
  if grep -qxF -- "$OWNED_TAG" "$unit_path" 2>/dev/null; then owned=1; fi

  if [[ -e $file ]]; then
    existed=1
    # Only ever recreate something that is already a swap area; never clobber a user's file.
    [[ $(blkid -p -o value -s TYPE "$file" 2>/dev/null) == swap ]] || die "$file exists and is not a swapfile; refusing to touch it"
    if (($(stat -c %s "$file") == bytes)); then
      echo "unchanged $file"
    else
      echo "resizing  $file"
      if swapon --noheadings --show=NAME | grep -qxF -- "$file"; then
        check_swapoff_fits
        swapoff "$file"
      fi
      rm -f "$file"
    fi
  fi
  if [[ ! -e $file ]]; then
    mkswapfile "$file" "$bytes" "$fstype"
    if ((! existed)); then owned=1; fi
  fi

  mount_unit "$dir" "$fstype"
  put "$unit_path" < <(
    echo "$TAG"
    if ((owned)); then echo "$OWNED_TAG"; fi
    cat <<EOF
[Unit]
Description=Swapfile $file
RequiresMountsFor=$dir

[Swap]
What=$file

[Install]
WantedBy=swap.target
EOF
  )
  if ((changed)); then systemctl daemon-reload; fi
  systemctl enable --now "$unit"
  swapon --show
}

# The runnable checks: the size arithmetic, the allowlist and the ownership helpers.
selftest() {
  local g=$((1 << 30)) t
  [[ $(swap_bytes $((8 * g))) == $((2 * g)) ]] || die "selftest: 8G RAM should give 2G"
  [[ $(swap_bytes $((128 * g))) == $((16 * g)) ]] || die "selftest: 128G RAM should cap at 16G"
  [[ $(swap_bytes 0 3G) == $((3 * g)) ]] || die "selftest: explicit --size should win"
  [[ $(swap_bytes $((g + 1))) == $((g / 4 / MIB * MIB)) ]] || die "selftest: result must be MiB-aligned"
  known sysctl vm.swappiness || die "selftest: allowlist should accept a table knob"
  ! known sysctl vm.nope || die "selftest: allowlist should reject an unknown knob"
  t=$(mktemp)
  printf '%s\nbody\n' "$TAG" >"$t"
  ours "$t" || die "selftest: tagged file should be ours"
  printf 'x\n%s\n' "$TAG" >"$t"
  ! ours "$t" || die "selftest: tag on a later line must not count"
  rm -f "$t"
  ! ours /nonexistent/zswap-tweaks || die "selftest: a missing file is not ours"
  ! confirm "x" </dev/null || die "selftest: confirm must say no without a terminal"
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
    --yes) assume_yes=1 ;;
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
  init_identity

  case $action in
  install) install_tweaks ;;
  uninstall) uninstall ;;
  swapfile) swapfile "$file" "$size" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
