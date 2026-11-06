#!/usr/bin/env bash
# fragwatch.sh - watch free-memory fragmentation and proactive compaction live
# Usage: ./fragwatch.sh [interval_s]     (no root needed; Ctrl+C to stop)
#
# score    share of free memory NOT in free 2 MiB blocks (what proactive
#          compaction looks at; it starts above 100-proactiveness+10 and stops
#          at 100-proactiveness)
# kswapd   R = reclaiming right now (proactive compaction pauses meanwhile)
# migr/s   pages moved per second by compaction (the cost side)
# thp/s    THP faults that got / did not get a huge page per second

iv="${1:-5}"
p="$(sysctl -n vm.compaction_proactiveness)"
lo=$((100 - p)); lw=$((lo / 2)); (( lw > 10 )) && lw=10; hi=$((lo + lw)); (( hi > 100 )) && hi=100
echo "compaction_proactiveness=$p: compacts when score > $hi, stops at <= $lo (only while kswapd is idle)"

vm() { awk -v k="$1" '$1 == k { print $2 }' /proc/vmstat; }
frag() {
	awk '/zone/ { for (i = 5; i <= NF; i++) { o = i - 5; f += $i * 2^o; if (o >= 9) s += $i * 2^o } }
	     END { printf "%.1f %.0f %.0f", f ? (f - s) * 100 / f : 0, f * 4 / 1024, s * 4 / 1024 }' /proc/buddyinfo
}
kswapd_state() {
	local pid; pid="$(pgrep -x kswapd0 | head -1)"
	[[ -n "$pid" ]] && awk '{ print $3 }' "/proc/$pid/stat" || echo "?"
}

printf '%-8s %6s %9s %11s %6s %8s %7s %7s\n' time score "free MiB" "2MiB-blk MiB" kswapd "migr/s" "thp/s" "fallb/s"
m0=$(vm pgmigrate_success); a0=$(vm thp_fault_alloc); f0=$(vm thp_fault_fallback)
while sleep "$iv"; do
	read -r sc fr bl <<<"$(frag)"
	m1=$(vm pgmigrate_success); a1=$(vm thp_fault_alloc); f1=$(vm thp_fault_fallback)
	printf '%-8s %6s %9s %11s %6s %8d %7d %7d\n' "$(date +%T)" "$sc" "$fr" "$bl" "$(kswapd_state)" \
		$(( (m1 - m0) / iv )) $(( (a1 - a0) / iv )) $(( (f1 - f0) / iv ))
	m0=$m1; a0=$a1; f0=$f1
done
