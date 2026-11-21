#!/bin/bash
# <xbar.title>tunlock</xbar.title>
# <xbar.desc>Mode switch and status for tunlock</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
T=/usr/local/bin/tunlock
st=$("$T" status --porcelain 2>/dev/null)
get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<< "$st"; }
verdict=$(get verdict)
case $verdict in
  protected) echo ":lock.shield.fill: | sfcolor=#2e9e44" ;;
  blocked) echo ":lock.trianglebadge.exclamationmark: | sfcolor=#d98c00" ;;
  direct) echo ":lock.open:" ;;
  *) echo ":exclamationmark.triangle.fill: | sfcolor=#d0312d" ;;
esac
echo "---"
echo "Status: ${verdict:-unknown}"
reason=$(get reason)
[[ -z $reason || $reason == ok || $reason == off ]] || echo "Reason: $reason"
echo "SSH: $(get ssh) $(get ssh_endpoint)"
ok=$( [[ $(get egress_ok) == 1 ]] && echo verified || echo "not verified")
echo "Egress: $(get egress_ip) ($ok, expected $(get expected))"
echo "PF: phase $(get phase), $(get pf_rules) rules"
echo "---"
# Without the sudoers entry, sudo asks for a password in Terminal.
term=true
[[ -e /etc/sudoers.d/tunlock ]] && term=false
echo "Protected mode | bash=$T param1=protect terminal=$term refresh=true"
echo "Direct internet | bash=$T param1=direct terminal=$term refresh=true"
echo "---"
echo "Run leak test… | bash=/usr/bin/sudo param1=$T param2=test terminal=true"
