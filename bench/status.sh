#!/bin/bash
# status.sh RUN [SINCE] : one line per machine of the run RUN (start.sh's NAME): blocks done, the last log line, checks,
# core dumps since SINCE ("YYYY-MM-DD HH:MM", default: today 00:00). HOSTS overrides the machines.
RUN=${1:?usage: status.sh RUN [SINCE]} SINCE=${2:-$(date +%F) 00:00}
for h in ${HOSTS:-t550 xps chromebook t460s t490 samsung-i5 p14s}; do
    printf '%-11s ' $h
    timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=6 root@$h "RUN='$RUN' SINCE='$SINCE' bash -s" <<'EOF' 2>&1 | tail -1 || echo unreachable
R=/root/abnight/$RUN; [ -d ${R}b ] && R=${R}b; cd $R 2>/dev/null || { echo no run; exit; }
printf "hyp=%s stock=%s %s | " $(ls hypoland-[0-9]*.txt 2>/dev/null | grep -vc startup) $(ls hyprland-[0-9]*.txt 2>/dev/null | grep -vc startup) "$([ -e done ] && echo DONE)"
for c in hypoland-check.txt hyprland-check.txt; do [ -e $c ] && printf "%s %s/%s " ${c%%-*} $(grep -c ^PASS $c) $(grep -c ^FAIL $c); done
printf "cores=%s | " "$(coredumpctl list --since "$SINCE" --no-legend 2>/dev/null | awk '{print $(NF-1)}' | xargs -r -n1 basename | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
tail -1 log | cut -c12-110
EOF
done
