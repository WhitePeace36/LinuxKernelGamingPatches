#!/usr/bin/env bash
# memdiff.sh - snapshot memory-stall counters before and after a gaming session
# Usage: ./memdiff.sh [label]      (press Enter when the session is over)
set -euo pipefail

label="${1:-run}"
keys='allocstall_|pgscan_direct|pgscan_direct_throttle|pgscan_kswapd|pgsteal_kswapd|kswapd_low_wmark_hit_quickly|compact_stall|compact_fail|compact_daemon_wake|pgmigrate_success|thp_fault_alloc|thp_fault_fallback|workingset_refault_file|workingset_activate_file|pgmajfault|pswpin|pswpout'

snap() {
	grep -E "^($keys)" /proc/vmstat
	awk '{ split($5, t, "="); print "psi_mem_" $1 "_us", t[2] }' /proc/pressure/memory
}

before=$(snap)
start=$(date +%s)
echo "[$label] counters saved. Play now, press Enter when done."
read -r _
after=$(snap)
mins=$(( ($(date +%s) - start) / 60 ))

echo
echo "== $label: $(uname -r), ${mins} min =="
printf 'sysctl: defrag_mode=%s scale=%s boost=%s proactiveness=%s\n' \
	"$(sysctl -n vm.defrag_mode 2>/dev/null || echo n/a)" \
	"$(sysctl -n vm.watermark_scale_factor)" \
	"$(sysctl -n vm.watermark_boost_factor)" \
	"$(sysctl -n vm.compaction_proactiveness)"
printf 'thp: %s | defrag: %s | ttm.low_latency_alloc: %s\n' \
	"$(grep -o '\[[a-z+]*\]' /sys/kernel/mm/transparent_hugepage/enabled)" \
	"$(grep -o '\[[a-z+]*\]' /sys/kernel/mm/transparent_hugepage/defrag)" \
	"$(cat /sys/module/ttm/parameters/low_latency_alloc 2>/dev/null || echo n/a)"
echo
join <(sort <<<"$before") <(sort <<<"$after") |
	awk '{ d = $3 - $2; printf "%-30s %12d\n", $1, d }' |
	tee "memdiff-${label}-$(date +%H%M).txt"
