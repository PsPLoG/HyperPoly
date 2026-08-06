#!/bin/bash
# Collect read-only diagnostics for HyperPoly audio-stack recovery work.
# This script does not stop, restart, signal, or modify any service.

set -u
umask 077

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-/tmp/hyperpoly-audio-diagnostics-${TIMESTAMP_UTC}}"
ARCHIVE_PATH="${OUTPUT_DIR}.tar.gz"

mkdir -p "$OUTPUT_DIR"

log() {
    printf '%s\n' "$*"
}

capture() {
    local name="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
        local status=$?
        printf '\n[exit_status=%s]\n' "$status"
        return 0
    } >"$OUTPUT_DIR/${name}.txt" 2>&1
}

capture_shell() {
    local name="$1"
    shift
    local command_text="$*"
    {
        printf '$ %s\n\n' "$command_text"
        /bin/sh -c "$command_text"
        local status=$?
        printf '\n[exit_status=%s]\n' "$status"
        return 0
    } >"$OUTPUT_DIR/${name}.txt" 2>&1
}

capture_if_available() {
    local name="$1"
    local command_name="$2"
    shift 2

    if command -v "$command_name" >/dev/null 2>&1; then
        capture "$name" "$command_name" "$@"
    else
        printf 'command not available: %s\n' "$command_name" \
            >"$OUTPUT_DIR/${name}.txt"
    fi
}

capture_file() {
    local name="$1"
    local path="$2"

    {
        printf 'path: %s\n\n' "$path"
        if [ -r "$path" ]; then
            cat "$path"
        else
            printf 'not readable or not present\n'
        fi
    } >"$OUTPUT_DIR/${name}.txt" 2>&1
}

capture_unit() {
    local unit="$1"
    local safe_name
    safe_name="$(printf '%s' "$unit" | tr '/@.' '____')"

    capture "systemctl_status_${safe_name}" systemctl status "$unit" --no-pager -l
    capture "systemctl_cat_${safe_name}" systemctl cat "$unit" --no-pager
    capture "systemctl_show_${safe_name}" systemctl show "$unit" \
        -p Id \
        -p Names \
        -p LoadState \
        -p ActiveState \
        -p SubState \
        -p Result \
        -p FragmentPath \
        -p DropInPaths \
        -p ExecStart \
        -p ExecStop \
        -p User \
        -p Group \
        -p WorkingDirectory \
        -p Environment \
        -p Restart \
        -p RestartUSec \
        -p NRestarts \
        -p StartLimitIntervalUSec \
        -p StartLimitBurst \
        -p OOMPolicy \
        -p OOMScoreAdjust \
        -p KillMode \
        -p TimeoutStartUSec \
        -p TimeoutStopUSec \
        -p After \
        -p Before \
        -p Requires \
        -p Wants \
        -p PartOf \
        -p BindsTo
}

log "Collecting diagnostics into: $OUTPUT_DIR"

cat >"$OUTPUT_DIR/collector.txt" <<EOF_COLLECTOR
script=${SCRIPT_NAME}
timestamp_utc=${TIMESTAMP_UTC}
output_dir=${OUTPUT_DIR}
effective_uid=$(id -u)
effective_user=$(id -un 2>/dev/null || true)
EOF_COLLECTOR

capture "date_local" date --iso-8601=seconds
capture "date_utc" date -u --iso-8601=seconds
capture "uname" uname -a
capture_if_available "hostnamectl" hostnamectl
capture "uptime" uptime
capture_file "os_release" /etc/os-release
capture_file "kernel_cmdline" /proc/cmdline
capture_file "mounts" /proc/mounts

capture_if_available "lscpu" lscpu
capture_if_available "free" free -h
capture_file "meminfo" /proc/meminfo
capture_if_available "df" df -hT
capture_if_available "lsblk" lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
capture_if_available "findmnt" findmnt
capture_shell "cpu_governor_and_frequency" \
    'for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo "== $cpu =="; for f in cpufreq/scaling_governor cpufreq/scaling_cur_freq cpufreq/scaling_min_freq cpufreq/scaling_max_freq; do test -r "$cpu/$f" && printf "%s=" "$f" && cat "$cpu/$f"; done; done'
capture_shell "thermal_zones" \
    'for zone in /sys/class/thermal/thermal_zone*; do test -d "$zone" || continue; echo "== $zone =="; test -r "$zone/type" && cat "$zone/type"; test -r "$zone/temp" && cat "$zone/temp"; done'

capture "systemctl_failed" systemctl --failed --no-pager
capture "systemctl_service_units" systemctl list-units --type=service --all --no-pager
capture "systemctl_service_unit_files" systemctl list-unit-files --type=service --no-pager
capture_shell "audio_related_units" \
    "systemctl list-unit-files --type=service --no-pager | grep -Ei 'ingen|polyui|jack|audio|update|usb|panel' || true"

for unit in ingen.service polyui.service jack.service jackd.service; do
    if systemctl show "$unit" >/dev/null 2>&1; then
        capture_unit "$unit"
    fi
done

capture "processes" ps -eF
capture "threads_scheduler" ps -eLo pid,ppid,tid,cls,rtprio,pri,ni,psr,pcpu,pmem,rss,vsz,stat,comm,args
capture_shell "audio_processes" \
    "pgrep -a -f 'jack|ingen|polyui|show_widget|digit_ui|python' || true"
capture_shell "process_cgroups" \
    "for p in \$(pgrep -f 'jack|ingen|polyui|show_widget|digit_ui' 2>/dev/null); do echo \"== PID \$p ==\"; cat /proc/\$p/cgroup 2>/dev/null || true; cat /proc/\$p/limits 2>/dev/null || true; done"
capture_shell "shell_limits" 'ulimit -a'

capture_if_available "dpkg_audio_packages" dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n'
capture_shell "filtered_dpkg_audio_packages" \
    "dpkg-query -W -f='\${binary:Package}\t\${Version}\t\${db:Status-Abbrev}\\n' 2>/dev/null | grep -Ei 'poly|ingen|jack|lv2|nam|convo|reverb|frontend' || true"

capture_if_available "jack_lsp_connections" jack_lsp -c
capture_if_available "jack_lsp_properties" jack_lsp -A -c -l -p -t
capture_if_available "jack_cpu_load" jack_cpu_load
capture_shell "jack_process_arguments" \
    "pgrep -a -f 'jackd|jackdbus' || true"

capture_shell "ingen_socket" \
    "ls -l /tmp/ingen.sock 2>&1 || true; stat /tmp/ingen.sock 2>&1 || true"
capture_if_available "unix_sockets" ss -xap

capture "journal_ingen_polyui" journalctl -b -u ingen.service -u polyui.service --no-pager -n 2000
capture_shell "journal_audio_failures" \
    "journalctl -b --no-pager 2>/dev/null | grep -Ei 'jack|xrun|zombie|ingen|polyui|lv2|nam|convo|reverb|segfault|abort|oom|killed process|thermal|throttl' | tail -n 4000 || true"
capture_shell "kernel_audio_failures" \
    "dmesg 2>&1 | grep -Ei 'oom|killed process|segfault|thermal|throttl|usb|snd|audio' | tail -n 2000 || true"
capture_if_available "coredumpctl_list" coredumpctl list --no-pager

capture_shell "updater_inventory" \
    "systemctl list-unit-files --no-pager 2>/dev/null | grep -Ei 'update|usb|panel' || true; find /usb_flash -maxdepth 2 -type f -printf '%p\\t%s bytes\\n' 2>/dev/null | sort || true"
capture_shell "persistent_state_inventory" \
    "find /pedal_state -maxdepth 2 -type f -printf '%p\\t%s bytes\\n' 2>/dev/null | sort || true"

{
    printf 'collection_completed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'archive_path=%s\n' "$ARCHIVE_PATH"
    printf 'note=Run as root on a lab device for complete journal, dmesg, unit, and process details.\n'
} >"$OUTPUT_DIR/manifest.txt"

if command -v tar >/dev/null 2>&1; then
    tar -C "$(dirname "$OUTPUT_DIR")" -czf "$ARCHIVE_PATH" "$(basename "$OUTPUT_DIR")"
    log "Archive created: $ARCHIVE_PATH"
else
    log "tar is unavailable; directory was collected without an archive"
fi

log "Collection complete"
