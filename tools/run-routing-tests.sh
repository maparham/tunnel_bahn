#!/usr/bin/env bash
# run-routing-tests.sh — autonomous routing regression suite for TunnelBahn
#
# Usage:
#   ./tools/run-routing-tests.sh [ProtonProfileName]
#
# Requirements:
#   - TunnelBahn is already running
#   - The profile exists and has been imported with a valid keypair
#
# What it tests (4 scenarios × 2 probes each):
#   Scenario A: fullTunnel  + enforceFilter=false  → in-CIDR: reachable;  out-of-CIDR: VPN IP
#   Scenario B: fullTunnel  + enforceFilter=true   → in-CIDR: reachable;  out-of-CIDR: REAL IP (filter excludes dest)
#   Scenario C: appTunnel   + enforceFilter=false  → in-CIDR: reachable;  out-of-CIDR: VPN IP (Terminal routed)
#   Scenario D: appTunnel   + enforceFilter=true   → in-CIDR: reachable;  out-of-CIDR: REAL IP (filter excludes dest)
#
# Both probes return the caller's public IP, so the result is directly comparable
# against REAL_IP / VPN_IP. The in-CIDR probe target is resolved at runtime and
# pinned into the destination filter; the out-of-CIDR target is assumed not to
# be in any of the user's bulk/domain rules (the URL handler's setDestinationCIDRs
# only replaces customRules and preserves bulk/domain rules, so a "single-IP"
# filter is impossible to guarantee from here).
#
# Routed app:  com.apple.Terminal (the shell running this script)
# In-CIDR probe:     https://api.ipify.org  (IP added to filter at runtime)
# Out-of-CIDR probe: https://ifconfig.me    (must NOT be in user's bulk/domain rules)

set -euo pipefail

PROFILE="${1:-Proton}"
ROUTED_APP="com.apple.Terminal"
PROBE_IN_CIDR="https://api.ipify.org"
PROBE_OUT_CIDR="https://ifconfig.me"
SETTLE_CONNECT=10 # initial sleep after connect URL before we start polling
WAIT_BUDGET=45    # total budget for wait_for_connected. Covers two slow paths:
                  # (1) filter-shape transitions need 10-20s to push /32 routes for domain-resolved
                  #     IPs into the routing table.
                  # (2) cold-start after a SIGKILL of the extensions — systemextensionsd may need
                  #     20-30s to respawn them before the connect URL can do anything meaningful.
PROBE_TIMEOUT=5   # per-probe ceiling; longer than this = scenario failure, not a slow upstream

# Colours
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

log_section() { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $*"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
log_info()    { echo "[info]  $*"; }
log_ok()      { echo "${GREEN}[✓]${NC}     $*"; }
log_fail()    { echo "${RED}[✗]${NC}     $*"; }
log_warn()    { echo "${YELLOW}[warn]${NC}  $*"; }

# ── URL helpers ───────────────────────────────────────────────────────────────

url_encode() { python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"; }

_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
TUNNELBAHN_APP=$(find "$_DERIVED" -name "TunnelBahn.app" -not -path "*/SourcePackages/*" -maxdepth 6 2>/dev/null | head -1)

open_url() {
    log_info "→ $1"
    if [[ -n "$TUNNELBAHN_APP" ]]; then
        open -a "$TUNNELBAHN_APP" "$1"
    else
        open "$1"
    fi
}

# ── VPN connection waiting ────────────────────────────────────────────────────

wait_for_connected() {
    local label="$1"
    # Proton's WG handshake completes in ~1-2s, but route propagation to user-space
    # (and DNS reconfiguration in full_tunnel mode) needs a few more seconds before
    # an external curl can reach a destination via the tunnel. ${SETTLE_CONNECT}s
    # settle then one tight 5s probe — if it still fails, the scenario is broken.
    log_info "Settling for VPN handshake ($label) — up to ${WAIT_BUDGET}s..."
    sleep "$SETTLE_CONNECT"
    # The filter-shape transition needs to: re-resolve domain names, push /32
    # routes into the system routing table, then traffic to in-filter IPs can
    # actually flow. We poll until either we see a response or the budget
    # expires. The body must be a VPN IP (not REAL_IP) to confirm tunnel routing
    # is in place — otherwise we'd accept a partial-routing state.
    local deadline=$((SECONDS + WAIT_BUDGET - SETTLE_CONNECT))
    local body
    while (( SECONDS < deadline )); do
        body=$(curl --silent --max-time 4 "$PROBE_IN_CIDR" 2>/dev/null)
        if [[ -n "$body" && "$body" != "$REAL_IP" ]]; then
            log_ok "VPN reachable (in-CIDR probe returned: $body)"
            return 0
        fi
        sleep 1
    done
    log_fail "VPN did not become reachable within ${WAIT_BUDGET}s"
    return 1
}

disconnect_vpn() {
    # Fire disconnect, then sleep just long enough for NEPacketTunnelProvider to
    # tear down before the next connect. Proton tears down fast — 3s is plenty.
    open_url 'tunnelbahn://test?disconnect=1' 2>/dev/null || true
    sleep 3
}

# Hard-reset the network extensions. Between scenarios, the extensions can get
# stuck in a half-applied state where new connect URLs don't actually trigger
# fresh route/proxy reconfiguration. SIGKILL forces a clean re-spawn the next
# time the host app fires a connect URL. Requires sudo (extensions run as root).
# After kill, systemextensionsd needs ~5s to recognize the death; the cold start
# itself can take another 20s, which is absorbed by WAIT_BUDGET.
reset_extensions() {
    log_info "Resetting extensions (hard kill)..."
    local ne_pid pp_pid
    ne_pid=$(pgrep com.tunnelbahn.mac.networkextension 2>/dev/null || true)
    pp_pid=$(pgrep com.tunnelbahn.mac.transparentproxy 2>/dev/null || true)
    if [[ -n "$ne_pid" || -n "$pp_pid" ]]; then
        sudo /usr/local/bin/tunnelbahn-reset-extensions 2>/dev/null || true
        sleep 4
    fi
}

# ── Probe helpers ─────────────────────────────────────────────────────────────

# probe <probe-url>
# Single 5s curl. If Proton can't deliver a response in 5s the scenario is broken;
# don't pad with retries that mask routing/filter bugs as "intermittent network."
# Script must run from a shell whose parent app is on the per-app routing list.
probe() {
    local probe_url="$1"
    local result
    result=$(curl --silent --max-time "$PROBE_TIMEOUT" "$probe_url" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    echo "TIMEOUT"
}

# probe_shell <probe-url>  — alias kept for baseline (disconnected) checks
probe_shell() { probe "$1"; }

# is_probe_failure <result> — true if a probe result is a sentinel/empty, not a real IP.
# TIMEOUT (and empty) must be treated as failure everywhere a probe result is
# consumed; otherwise TIMEOUT == TIMEOUT comparisons report PASS on black-holed
# routing.
is_probe_failure() {
    [[ -z "$1" || "$1" == "TIMEOUT" || "$1" == "FAILED" || "$1" == "EMPTY" ]]
}

# ── Baseline: measure REAL IP before connecting ───────────────────────────────

log_section "Baseline — disconnected real IP"
disconnect_vpn
REAL_IP=$(probe_shell "$PROBE_OUT_CIDR")
if is_probe_failure "$REAL_IP"; then
    log_fail "Could not determine real IP (got: ${REAL_IP:-<empty>}); aborting"
    exit 1
fi
log_ok "Real (non-VPN) IP = $REAL_IP"

# ── Provision test rules ──────────────────────────────────────────────────────
#
# Important: this script does NOT touch the destination CIDR list. The CIDR list
# (custom + bulk + domain rules) is the user's responsibility — it must already
# include api.ipify.org's resolved IPs and exclude ifconfig.me's IP for the
# filter=true scenarios to behave as expected. We tried injecting our own CIDRs,
# but switching the filter on in-place causes the app to rebuild routes for ~10s
# during which our injected destinations are unreachable, breaking the test.
#
# What we DO provision: a single per-app rule for com.apple.Terminal (the parent
# of this script's curl flows), so app_tunnel mode intercepts our probes.

log_section "Provisioning test rules"

ENCODED_PROFILE=$(url_encode "$PROFILE")

# Save user's routing toggles. We deliberately do NOT call setAppRules —
# replaceAll() would clobber the rest of the user's per-app routing list.
# Terminal must already be on the list (with action=routeVPN) for the
# app_tunnel scenarios to intercept this script's curl flows.
open_url "tunnelbahn://test?saveSnapshot=user_backup"
sleep 2

# Establish VPN_IP via full tunnel without filtering (ground truth)
log_section "Ground truth — fullTunnel + no filter (establishing VPN exit IP)"
open_url "tunnelbahn://test?routingMode=full_tunnel&enforceDestinationFiltering=false&connect=${ENCODED_PROFILE}"
VPN_IP="FAILED"
if wait_for_connected "ground-truth"; then
    sleep 2
    VPN_IP=$(probe_shell "$PROBE_OUT_CIDR")
    log_ok "VPN exit IP = $VPN_IP"
fi
# No disconnect here either — Scenario A starts in the same mode/filter, so the
# next connect URL is a no-op for the state machine.

if is_probe_failure "$VPN_IP" || [[ "$VPN_IP" == "$REAL_IP" ]]; then
    log_fail "Could not establish VPN exit IP (got: ${VPN_IP:-<empty>}). Cannot run scenarios."
    # Non-destructive early exit: restore toggles only, leave provisioned rules
    # in place so the user can inspect them.
    open_url "tunnelbahn://test?restoreSnapshot=user_backup"
    exit 1
fi

# Track pass/fail counts
PASS=0; FAIL=0
declare -a RESULTS=()

run_scenario() {
    local label="$1"
    local mode="$2"            # full_tunnel | app_tunnel
    local enforce="$3"         # true | false
    local probe_in_expect="$4" # VPN_IP | REAL_IP | BLOCKED
    local probe_out_expect="$5"

    log_section "Scenario $label — routingMode=$mode enforceFilter=$enforce"
    log_info "Expected: in-CIDR=$probe_in_expect  out-of-CIDR=$probe_out_expect"

    # Hard-reset extensions so this scenario starts from a clean state — avoids
    # the "half-applied transition" failure mode where the proxy keeps stale
    # routing decisions from the previous scenario.
    reset_extensions

    open_url "tunnelbahn://test?routingMode=${mode}&enforceDestinationFiltering=${enforce}&connect=${ENCODED_PROFILE}"

    if ! wait_for_connected "Scenario $label"; then
        log_fail "Scenario $label: VPN never connected — skipping probes"
        RESULTS+=("$label: SKIP (no connect)")
        (( FAIL++ )) || true
        disconnect_vpn
        return
    fi

    # In-CIDR probe
    log_info "Probing in-CIDR ($PROBE_IN_CIDR)..."
    local ip_in
    ip_in=$(probe "$PROBE_IN_CIDR")
    log_info "  in-CIDR result: $ip_in"

    # Out-of-CIDR probe
    log_info "Probing out-of-CIDR ($PROBE_OUT_CIDR)..."
    local ip_out
    ip_out=$(probe "$PROBE_OUT_CIDR")
    log_info "  out-of-CIDR result: $ip_out"

    # Evaluate in-CIDR expectation
    local in_pass=false out_pass=false
    # A TIMEOUT/empty probe can never satisfy an IP expectation — even if the
    # reference IP is somehow a sentinel too, sentinel == sentinel must not PASS.
    case "$probe_in_expect" in
        VPN_IP)   ! is_probe_failure "$ip_in" && [[ "$ip_in" == "$VPN_IP" ]] && in_pass=true ;;
        REAL_IP)  ! is_probe_failure "$ip_in" && [[ "$ip_in" == "$REAL_IP" ]] && in_pass=true ;;
        BLOCKED)  is_probe_failure "$ip_in" && in_pass=true ;;
        ANY_IP)   ! is_probe_failure "$ip_in" && in_pass=true ;;
    esac
    case "$probe_out_expect" in
        VPN_IP)   ! is_probe_failure "$ip_out" && [[ "$ip_out" == "$VPN_IP" ]] && out_pass=true ;;
        REAL_IP)  ! is_probe_failure "$ip_out" && [[ "$ip_out" == "$REAL_IP" ]] && out_pass=true ;;
        BLOCKED)  is_probe_failure "$ip_out" && out_pass=true ;;
        ANY_IP)   ! is_probe_failure "$ip_out" && out_pass=true ;;
    esac

    local overall_pass=false
    $in_pass && $out_pass && overall_pass=true

    if $in_pass; then
        log_ok  "  in-CIDR  ($probe_in_expect):  $ip_in"
    else
        log_fail "  in-CIDR  (expected $probe_in_expect, got $ip_in)"
    fi
    if $out_pass; then
        log_ok  "  out-CIDR ($probe_out_expect): $ip_out"
    else
        log_fail "  out-CIDR (expected $probe_out_expect, got $ip_out)"
    fi

    if $overall_pass; then
        log_ok "Scenario $label: PASS"
        RESULTS+=("$label ($mode + filter=$enforce): PASS  [in=$ip_in  out=$ip_out]")
        (( PASS++ )) || true
    else
        log_fail "Scenario $label: FAIL"
        RESULTS+=("$label ($mode + filter=$enforce): FAIL  [in=$ip_in (exp $probe_in_expect)  out=$ip_out (exp $probe_out_expect)]")
        (( FAIL++ )) || true
    fi

    # Intentionally NO disconnect here. Each scenario fires connectProfileForTest
    # with the new mode/filter, which re-applies in-place. Disconnect→reconnect
    # forces the app to rebuild all destination-filter routes from scratch (~10s
    # of unreachability while routes propagate). Letting the app swap state
    # in-place is dramatically faster and matches how the UI toggles work.
}

# ── Run scenarios ─────────────────────────────────────────────────────────────
# Both probes return the caller's public IP, so we can discriminate VPN vs REAL
# directly. In-CIDR (api.ipify.org) is pinned into the filter at provisioning time,
# so it always returns VPN_IP when the tunnel is up. Out-of-CIDR (ifconfig.me) is
# assumed NOT to be in any of the user's bulk/domain rules.

#   A: fullTunnel  + filter=false → tunnel is default route, no destination gating.
#      Both probes egress via VPN.
run_scenario "A" "full_tunnel" "false" "VPN_IP" "VPN_IP"

#   B: fullTunnel  + filter=true  → tunnel is default route, but filter narrows egress.
#      In-CIDR (ipify, pinned in filter) → VPN_IP.
#      Out-of-CIDR (ifconfig.me, not in filter) → REAL_IP via host stack.
run_scenario "B" "full_tunnel" "true"  "VPN_IP" "REAL_IP"

#   C: appTunnel   + filter=false → only Terminal flows intercepted; no destination gating.
#      Both probes (Terminal-spawned) go via tunnel → VPN_IP.
run_scenario "C" "app_tunnel"  "false" "VPN_IP" "VPN_IP"

#   D: appTunnel   + filter=true  → Terminal intercepted AND filter narrows egress.
#      In-CIDR (ipify, pinned in filter) → intercepted and tunneled → VPN_IP.
#      Out-of-CIDR (ifconfig.me, not in filter) → bypassed → REAL_IP.
run_scenario "D" "app_tunnel"  "true"  "VPN_IP" "REAL_IP"

# ── Restore user snapshot ─────────────────────────────────────────────────────

log_section "Restoring user snapshot"
open_url "tunnelbahn://test?restoreSnapshot=user_backup"
sleep 0.5
log_warn "Routing toggles restored."

# ── Summary ───────────────────────────────────────────────────────────────────

log_section "Summary  (REAL=$REAL_IP  VPN=$VPN_IP)"
for r in "${RESULTS[@]}"; do
    if [[ "$r" == *PASS* ]]; then
        echo "  ${GREEN}✓${NC} $r"
    else
        echo "  ${RED}✗${NC} $r"
    fi
done
echo
echo "  Total: ${PASS} passed, ${FAIL} failed"
echo
log_info "Full APPSPLIT logs:"
echo "  log stream --predicate 'subsystem == \"com.tunnelbahn.mac\" OR subsystem == \"com.tunnelbahn.mac.transparentproxy\"' | grep APPSPLIT"
