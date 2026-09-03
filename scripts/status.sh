#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# status.sh - what is deployed, what state it is in, and roughly what it costs.
#
# Three sections:
#   1. Local     - the Oracle container, generated/ and out/ artefacts
#   2. Azure     - every resource in the group, with power/availability state
#   3. Cost      - an estimate per day, and optionally the real billed figure
#
# THE COST FIGURES ARE AN ESTIMATE. They come from a small table of
# approximate pay-as-you-go list prices held in this script, not from the
# Azure pricing API, and they ignore your discounts, reservations, egress and
# storage growth. Use them to decide whether to run destroy.sh tonight, not to
# forecast a budget. --actual queries the real consumption API instead, which
# lags by 8-24 hours and needs a subscription that exposes it.
#
# Part of the Contoso Store Oracle -> Azure Database for PostgreSQL lab.
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED='';   C_GREEN=''; C_YELLOW=''
    C_BLUE='';  C_CYAN=''
fi

hdr()  { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
info() { printf '  %s[ .. ]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  {
    printf '\n%s%sstatus failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
SHOW_ACTUAL=0
LOCAL_ONLY=0
AZURE_ONLY=0
RG_OVERRIDE=''
# Set when a check finds something that will silently ruin a conversion run
# rather than merely costing money. Turns the exit code non-zero at the end.
PREREQ_FAIL=0

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - show what is deployed and roughly what it costs per day.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} [options]

${C_BOLD}OPTIONS${C_RESET}
    --actual                 Also query the Azure consumption API for what has
                             actually been billed this month. Billing data lags
                             8-24 hours and some subscription types (CSP, some
                             EA) do not expose it at all.
    --local                  Only the local Docker/artefact section.
    --azure                  Only the Azure section.
    --resource-group <name>  Inspect this group instead of AZ_RESOURCE_GROUP.
    -h, --help               Show this help and exit.

${C_BOLD}ABOUT THE COST NUMBERS${C_RESET}
    Estimates from a built-in table of approximate pay-as-you-go list prices.
    They ignore discounts, reservations, egress and storage growth, and they
    are not a billing source. They exist to answer one question:
    ${C_BOLD}"is it worth running destroy.sh before I close the laptop?"${C_RESET}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --actual)           SHOW_ACTUAL=1; shift ;;
        --local)            LOCAL_ONLY=1; shift ;;
        --azure)            AZURE_ONLY=1; shift ;;
        --resource-group)   RG_OVERRIDE="${2:-}"; [[ -n "$RG_OVERRIDE" ]] || die "--resource-group needs a value"; shift 2 ;;
        --resource-group=*) RG_OVERRIDE="${1#*=}"; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Bash sources .env directly, so `FOO=two words` is not an assignment: it sets
    # FOO=two and then tries to run `words`. The resulting "words: command not
    # found" tells the reader nothing at all. Name the offending line instead.
    lint_env_file() {
        local bad
        bad="$(grep -nE "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^\"'#[:space:]]*[[:space:]]+[^[:space:]#]" "$1" 2>/dev/null || true)"
        [[ -n "$bad" ]] || return 0
        printf '\n%s%sCannot read %s - unquoted value(s) containing spaces:%s\n' "$C_BOLD" "$C_RED" "$1" "$C_RESET" >&2
        printf '%s\n' "$bad" | sed 's/^/  line /' >&2
        printf '%sfix:%s wrap each value in single quotes, e.g.  %s\n\n' \
            "$C_BOLD" "$C_RESET" "FOUNDRY_RBAC_ROLE='Foundry User'" >&2
        return 1
    }
    lint_env_file "$ENV_FILE" || exit 2
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
else
    warn ".env not found; falling back to defaults and command-line values"
fi

PREFIX="${AZ_PREFIX:-o2p}"
RG="${RG_OVERRIDE:-${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}}"
CONTAINER="${ORACLE_CONTAINER_NAME:-o2p-oracle}"
OUTPUTS="${REPO_ROOT}/generated/outputs.json"

# --------------------------------------------------------------------------
# 1. Local
# --------------------------------------------------------------------------
if [[ "$AZURE_ONLY" -eq 0 ]]; then
    hdr "Local"

    if have docker && docker info >/dev/null 2>&1; then
        FOUND_C=''
        for NAME in "$CONTAINER" oracle-lab; do
            if docker inspect -f '{{.State.Status}}' "$NAME" >/dev/null 2>&1; then FOUND_C="$NAME"; break; fi
        done
        if [[ -n "$FOUND_C" ]]; then
            CSTATE="$(docker inspect -f '{{.State.Status}}' "$FOUND_C")"
            CSINCE="$(docker inspect -f '{{.State.StartedAt}}' "$FOUND_C" 2>/dev/null | cut -c1-19 | tr 'T' ' ')"
            CIMAGE="$(docker inspect -f '{{.Config.Image}}' "$FOUND_C" 2>/dev/null || echo '?')"
            case "$CSTATE" in
                running) ok "container ${FOUND_C} running since ${CSINCE}Z" ;;
                *)       warn "container ${FOUND_C} is ${CSTATE}" ; note "docker start ${FOUND_C}" ;;
            esac
            note "image ${CIMAGE}"
            note "costs nothing but your laptop's fan"
        else
            info "no Oracle container (looked for '${CONTAINER}' and 'oracle-lab')"
            note "docs/02-seed-oracle.md has the docker run command"
        fi
    elif have docker; then
        warn "docker is installed but the daemon is not responding"
    else
        info "docker not installed"
    fi

    GEN_DIR="${GEN_OUTPUT_DIR:-${REPO_ROOT}/generated}"
    case "$GEN_DIR" in ./*) GEN_DIR="${REPO_ROOT}/${GEN_DIR#./}" ;; esac
    if [[ -d "$GEN_DIR" ]]; then
        GEN_N="$(find "$GEN_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$GEN_N" -gt 0 ]]; then ok "generated/ holds ${GEN_N} .sql file(s)"
        else info "generated/ has no SQL yet"; note "scripts/seed-oracle.sh runs tools/generate-objects.py for you"; fi
    else
        info "generated/ does not exist yet"
    fi

    if [[ -f "$OUTPUTS" ]]; then
        ok "generated/outputs.json present ($(date -r "$OUTPUTS" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
    elif [[ -f "${OUTPUTS}.stale" ]]; then
        info "outputs.json.stale present - the last deployment was destroyed"
    else
        info "no generated/outputs.json - nothing has been deployed from this checkout"
    fi

    LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/logs}"
    case "$LOG_DIR" in ./*) LOG_DIR="${REPO_ROOT}/${LOG_DIR#./}" ;; esac
    if [[ -d "$LOG_DIR" ]]; then
        LAST_RUN="$(find "$LOG_DIR" -maxdepth 1 -type d -name 'seed-*' 2>/dev/null | LC_ALL=C sort | tail -1)"
        [[ -n "$LAST_RUN" ]] && info "last seed run: $(basename "$LAST_RUN")"
    fi
fi

[[ "$LOCAL_ONLY" -eq 1 ]] && { printf '\n'; exit 0; }

# --------------------------------------------------------------------------
# 2. Azure
# --------------------------------------------------------------------------
hdr "Azure"

have az || die "az CLI not installed" "brew install azure-cli"
if ! az account show >/dev/null 2>&1; then
    warn "Azure CLI is not logged in"
    note "az login"
    printf '\n'
    exit 0
fi

SUB_NAME="$(az account show --query name -o tsv 2>/dev/null || echo '?')"
printf '  %-18s %s\n' "subscription" "$SUB_NAME"
printf '  %-18s %s\n' "resource group" "$RG"

if ! az group show --name "$RG" -o none 2>/dev/null; then
    printf '\n  %s%sNothing is deployed.%s Resource group "%s" does not exist.\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET" "$RG"
    printf '  %sAzure cost right now: %s0.00/day%s\n' "$C_DIM" "\$" "$C_RESET"
    printf '\n  Deploy with: %sscripts/deploy.sh%s\n\n' "$C_BOLD" "$C_RESET"
    exit 0
fi

have jq || die "jq is required to summarise resources" "brew install jq"

RG_LOC="$(az group show --name "$RG" --query location -o tsv 2>/dev/null || echo '?')"
printf '  %-18s %s\n' "location" "$RG_LOC"

RES_JSON="$(az resource list --resource-group "$RG" -o json 2>/dev/null || echo '[]')"
RES_N="$(printf '%s' "$RES_JSON" | jq 'length')"
printf '  %-18s %s\n' "resources" "$RES_N"

if [[ "$RES_N" -eq 0 ]]; then
    warn "the group exists but is empty"
    note "a deployment may have failed, or destroy.sh was interrupted"
fi

# ---- virtual machines ----------------------------------------------------
VM_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.Compute/virtualMachines") | .name')"
if [[ -n "$VM_NAMES" ]]; then
    printf '\n  %sVirtual machines%s\n' "$C_BOLD" "$C_RESET"
    for VM in $VM_NAMES; do
        VM_SIZE="$(az vm show --resource-group "$RG" --name "$VM" --query hardwareProfile.vmSize -o tsv 2>/dev/null || echo '?')"
        VM_STATE="$(az vm get-instance-view --resource-group "$RG" --name "$VM" \
                    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null || echo '?')"
        case "$VM_STATE" in
            'VM running')      MARK="$C_YELLOW" ;;
            'VM deallocated')  MARK="$C_GREEN"  ;;
            *)                 MARK="$C_DIM"    ;;
        esac
        printf '    %-30s %-20s %s%s%s\n' "$VM" "$VM_SIZE" "$MARK" "$VM_STATE" "$C_RESET"
    done
    note "a deallocated VM costs nothing for compute; its disk still bills"
fi

# ---- PostgreSQL ----------------------------------------------------------
PG_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.DBforPostgreSQL/flexibleServers") | .name')"
if [[ -n "$PG_NAMES" ]]; then
    printf '\n  %sPostgreSQL flexible servers%s\n' "$C_BOLD" "$C_RESET"
    for PG in $PG_NAMES; do
        PG_JSON="$(az postgres flexible-server show --resource-group "$RG" --name "$PG" -o json 2>/dev/null || echo '{}')"
        PG_SKU="$(printf '%s' "$PG_JSON" | jq -r '.sku.name // "?"')"
        PG_VER="$(printf '%s' "$PG_JSON" | jq -r '.version // "?"')"
        PG_STATE="$(printf '%s' "$PG_JSON" | jq -r '.state // "?"')"
        PG_STORE="$(printf '%s' "$PG_JSON" | jq -r '.storage.storageSizeGb // "?"')"
        case "$PG_STATE" in
            Ready)   MARK="$C_YELLOW" ;;
            Stopped) MARK="$C_GREEN"  ;;
            *)       MARK="$C_DIM"    ;;
        esac
        printf '    %-30s %-18s PG%-4s %4sGB  %s%s%s\n' "$PG" "$PG_SKU" "$PG_VER" "$PG_STORE" "$MARK" "$PG_STATE" "$C_RESET"

        # The two extension gotchas from docs/design.md 11.2. Cheap to check,
        # and both fail silently at conversion time rather than loudly here.
        # PG_REQUIRED_EXTENSIONS in .env carries the full allowlist; these four
        # are the ones whose absence is not merely inconvenient.
        EXT="$(az postgres flexible-server parameter show --resource-group "$RG" --server-name "$PG" \
               --name azure.extensions --query value -o tsv 2>/dev/null || true)"
        if [[ -n "$EXT" ]]; then
            MISSING_EXT=''
            for WANT in plpgsql_check dblink orafce pg_partman; do
                printf '%s' "$EXT" | tr ',' '\n' | grep -qix "$WANT" || MISSING_EXT="${MISSING_EXT}${WANT} "
            done
            if [[ -n "$MISSING_EXT" ]]; then
                printf '      %snot allowlisted: %s%s\n' "$C_RED" "$MISSING_EXT" "$C_RESET"
                printf '      %splpgsql_check is FAIL-OPEN: without it the converter skips its deeper%s\n' "$C_DIM" "$C_RESET"
                printf '      %svalidation with no error and no warning in the report.%s\n' "$C_DIM" "$C_RESET"
                # This is the one thing in the whole lab that is worth failing
                # a status report over: a conversion run started without
                # plpgsql_check produces a clean-looking report that was never
                # checked, and it cannot be retro-fixed afterwards.
                case "$MISSING_EXT" in *plpgsql_check*) PREREQ_FAIL=1 ;; esac
            else
                printf '      %sazure.extensions covers the four the lab needs%s\n' "$C_DIM" "$C_RESET"
            fi
        fi

        # Allowlisted is not the same as LOADED. shared_preload_libraries is a
        # static parameter, so writing it leaves isConfigPendingRestart = true
        # until the server is restarted -- and ARM has no restart verb, so a
        # deployment alone never clears it. Until then plpgsql_check is
        # configured but not in memory, and because it fails OPEN the converter
        # skips its deeper validation with nothing in the report to say so.
        # Checking only azure.extensions would report all-clear on exactly that.
        PENDING="$(az postgres flexible-server parameter show --resource-group "$RG" \
                     --server-name "$PG" --name shared_preload_libraries \
                     --query isConfigPendingRestart -o tsv 2>/dev/null || true)"
        if [[ "$PENDING" == "true" || "$PENDING" == "True" ]]; then
            printf '      %sshared_preload_libraries is PENDING RESTART - not yet loaded%s\n' "$C_RED" "$C_RESET"
            printf '      %splpgsql_check is allowlisted but not in memory, and it fails OPEN.%s\n' "$C_DIM" "$C_RESET"
            printf '      %sfix: az postgres flexible-server restart -g %s -n %s%s\n' "$C_DIM" "$RG" "$PG" "$C_RESET"
            PREREQ_FAIL=1
        elif [[ -n "$PENDING" ]]; then
            printf '      %sshared_preload_libraries is loaded (no restart pending)%s\n' "$C_DIM" "$C_RESET"
        fi
    done
    note "a stopped flexible server still bills for storage, and auto-restarts after 7 days"
fi

# ---- Foundry -------------------------------------------------------------
CS_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.CognitiveServices/accounts") | .name')"
if [[ -n "$CS_NAMES" ]]; then
    printf '\n  %sMicrosoft Foundry%s\n' "$C_BOLD" "$C_RESET"
    for CS in $CS_NAMES; do
        CS_EP="$(az cognitiveservices account show --resource-group "$RG" --name "$CS" --query properties.endpoint -o tsv 2>/dev/null || echo '?')"
        printf '    %-30s %s\n' "$CS" "$CS_EP"
        az cognitiveservices account deployment list --resource-group "$RG" --name "$CS" -o json 2>/dev/null \
        | jq -r '.[] | "      \(.name)\t\(.properties.model.name // "?")\t\(.sku.capacity // "?")"' 2>/dev/null \
        | while IFS=$'\t' read -r D M CAP; do
            printf '      %-28s %-16s %s kTPM\n' "$D" "$M" "$CAP"
          done
    done
    note "Foundry bills per token, not per hour - an idle deployment is nearly free"
fi

# ---- Bastion -------------------------------------------------------------
BAS_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.Network/bastionHosts") | .name')"
if [[ -n "$BAS_NAMES" ]]; then
    printf '\n  %sBastion%s\n' "$C_BOLD" "$C_RESET"
    for B in $BAS_NAMES; do
        # One JSON call rather than two tsv ones, because `-o tsv` cannot
        # express the difference between `false` and "the property was not in
        # the response": both arrive as an empty string with exit status 0.
        # az omits enableTunneling entirely on some CLI/API-version pairs, so
        # the old `|| echo '?'` fallback never fired for an absent property and
        # an unreported value was reported to the user as a disabled one.
        B_JSON="$(az network bastion show --resource-group "$RG" --name "$B" -o json 2>/dev/null || echo '{}')"
        B_SKU="$(printf '%s' "$B_JSON" | jq -r '.sku.name // "?"')"
        # tostring, not `// empty`: jq's // operator treats `false` as absent
        # too, which would reintroduce exactly the conflation being fixed.
        # Yields the strings "true", "false" or "null".
        B_TUN="$(printf '%s' "$B_JSON" | jq -r '.enableTunneling | tostring')"
        case "$B_TUN" in
            true|True|TRUE)
                printf '    %-30s %-12s tunneling=true\n' "$B" "$B_SKU"
                ;;
            false|False|FALSE)
                # Only assert the consequence when the value is literally false.
                printf '    %-30s %-12s tunneling=false\n' "$B" "$B_SKU"
                printf '      %snative tunneling is off; connect.sh cannot open a tunnel%s\n' "$C_RED" "$C_RESET"
                printf '      %saz network bastion update --name %s --resource-group %s --enable-tunneling true%s\n' \
                    "$C_DIM" "$B" "$RG" "$C_RESET"
                ;;
            *)
                printf '    %-30s %-12s tunneling=%s\n' "$B" "$B_SKU" "(not reported)"
                printf '      %saz did not report enableTunneling for this host. That is CLI and%s\n' "$C_DIM" "$C_RESET"
                printf '      %sAPI-version dependent and does not mean tunneling is off - it may well%s\n' "$C_DIM" "$C_RESET"
                printf '      %swork. The real test is:  scripts/connect.sh oracle-azure --tunnel-only%s\n' "$C_DIM" "$C_RESET"
                ;;
        esac
    done
    note "Bastion bills per hour whether or not anyone connects - it is the quiet expensive one"
fi

# ---- everything else -----------------------------------------------------
printf '\n  %sAll resource types%s\n' "$C_BOLD" "$C_RESET"
printf '%s' "$RES_JSON" | jq -r 'group_by(.type)[] | "\(length)\t\(.[0].type)"' | sort -rn \
| while IFS=$'\t' read -r N T; do printf '    %3s x %s\n' "$N" "${T#Microsoft.}"; done

# --------------------------------------------------------------------------
# 3. Cost
# --------------------------------------------------------------------------
hdr "Estimated cost"

# rate_per_day <sku-or-type> -> approximate USD/day, pay-as-you-go list price.
# Deliberately coarse and deliberately in one place so it is easy to correct.
rate_per_day() {
    case "$1" in
        Standard_E2s_v5)   echo 3.4  ;;
        Standard_E4s_v5)   echo 6.7  ;;
        Standard_E8s_v5)   echo 13.4 ;;
        Standard_D2s_v5)   echo 2.4  ;;
        Standard_D4s_v5)   echo 4.7  ;;
        Standard_D8s_v5)   echo 9.4  ;;
        Standard_B2ms)     echo 2.0  ;;
        Standard_D2ads_v5) echo 2.3  ;;
        # The lab deploys Bastion Standard, not Basic: Basic rejects
        # enableTunneling and `az network bastion tunnel` is load-bearing here.
        # Standard is roughly half again as expensive and cannot be stopped,
        # only deleted - so pricing them the same understated the one line most
        # likely to surprise somebody.
        bastion_Standard)  echo 6.96 ;;
        bastion_Basic)     echo 4.56 ;;
        pg_burstable)      echo 0.9  ;;
        pg_generalpurpose) echo 4.1  ;;
        pg_memoryoptimized) echo 7.0 ;;
        managed_disk)      echo 0.4  ;;
        public_ip)         echo 0.12 ;;
        *)                 echo 0    ;;
    esac
}

TOTAL_DAY=0
COST_LINES=''
add_cost() {
    local label="$1" rate="$2"
    TOTAL_DAY="$(awk -v a="$TOTAL_DAY" -v b="$rate" 'BEGIN{printf "%.2f", a+b}')"
    COST_LINES="${COST_LINES}$(printf '    %-40s $%6.2f' "$label" "$rate")"$'\n'
}

for VM in $VM_NAMES; do
    VM_SIZE="$(az vm show --resource-group "$RG" --name "$VM" --query hardwareProfile.vmSize -o tsv 2>/dev/null || echo '?')"
    VM_STATE="$(az vm get-instance-view --resource-group "$RG" --name "$VM" \
                --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null || echo '?')"
    if [[ "$VM_STATE" == "VM running" ]]; then
        add_cost "vm ${VM} (${VM_SIZE}, running)" "$(rate_per_day "$VM_SIZE")"
    else
        add_cost "vm ${VM} (${VM_SIZE}, ${VM_STATE:-off}) disk only" "$(rate_per_day managed_disk)"
    fi
done

for PG in $PG_NAMES; do
    PG_SKU="$(az postgres flexible-server show --resource-group "$RG" --name "$PG" --query sku.tier -o tsv 2>/dev/null || echo '?')"
    case "$PG_SKU" in
        Burstable)        add_cost "postgres ${PG} (Burstable)"         "$(rate_per_day pg_burstable)" ;;
        GeneralPurpose)   add_cost "postgres ${PG} (GeneralPurpose)"    "$(rate_per_day pg_generalpurpose)" ;;
        MemoryOptimized)  add_cost "postgres ${PG} (MemoryOptimized)"   "$(rate_per_day pg_memoryoptimized)" ;;
        *)                add_cost "postgres ${PG} (${PG_SKU})"         "$(rate_per_day pg_generalpurpose)" ;;
    esac
done

for B in $BAS_NAMES; do
    B_SKU="$(az network bastion show --resource-group "$RG" --name "$B" --query 'sku.name' -o tsv 2>/dev/null || echo 'Standard')"
    add_cost "bastion ${B} (${B_SKU})" "$(rate_per_day "bastion_${B_SKU}")"
done

IP_N="$(printf '%s' "$RES_JSON" | jq '[.[] | select(.type=="Microsoft.Network/publicIPAddresses")] | length')"
if [[ "$IP_N" -gt 0 ]]; then
    add_cost "${IP_N} x public IP" "$(awk -v n="$IP_N" -v r="$(rate_per_day public_ip)" 'BEGIN{printf "%.2f", n*r}')"
fi

if [[ -n "$COST_LINES" ]]; then
    printf '%s' "$COST_LINES"
    printf '    %s\n' "---------------------------------------- -------"
    printf '    %s%-40s $%6.2f / day%s\n' "$C_BOLD" "estimated total" "$TOTAL_DAY" "$C_RESET"
    MONTH="$(awk -v d="$TOTAL_DAY" 'BEGIN{printf "%.0f", d*30}')"
    printf '    %s%-40s $%6s / 30 days%s\n' "$C_DIM" "if left running" "$MONTH" "$C_RESET"
else
    printf '    %snothing billable found%s\n' "$C_DIM" "$C_RESET"
fi

printf '\n  %sEstimate only.%s Approximate pay-as-you-go list prices from a table inside\n' "$C_YELLOW" "$C_RESET"
printf '  this script. Ignores discounts, reservations, egress, storage growth and\n'
printf '  Foundry token charges. Not a billing source.\n'

# ---- actual --------------------------------------------------------------
if [[ "$SHOW_ACTUAL" -eq 1 ]]; then
    hdr "Actual billed cost (month to date)"
    info "querying the consumption API - this is slow and lags 8-24 hours"
    FROM="$(date -u +%Y-%m-01)"
    TO="$(date -u +%Y-%m-%d)"
    if USAGE="$(az consumption usage list --start-date "$FROM" --end-date "$TO" \
                --query "[?contains(instanceId, '/resourceGroups/${RG}/')].{c:pretaxCost,n:instanceName}" \
                -o json 2>/dev/null)"; then
        if [[ "$(printf '%s' "$USAGE" | jq 'length')" -gt 0 ]]; then
            printf '%s' "$USAGE" | jq -r 'group_by(.n)[] | "\(.[0].n)\t\([.[].c | tonumber] | add)"' \
            | sort -t"$(printf '\t')" -k2 -rn \
            | while IFS=$'\t' read -r N C; do printf '    %-40s $%8.2f\n' "$N" "$C"; done
            TOT="$(printf '%s' "$USAGE" | jq '[.[].c | tonumber] | add')"
            printf '    %s\n' "---------------------------------------- ---------"
            printf '    %s%-40s $%8.2f%s   (%s to %s)\n' "$C_BOLD" "total" "$TOT" "$C_RESET" "$FROM" "$TO"
        else
            info "no usage records yet for ${RG}"
            note "billing data appears 8-24 hours after the resources are created"
        fi
    else
        warn "the consumption API is not available on this subscription"
        note "common for CSP and some EA subscriptions; use Cost Management in the portal"
    fi
fi

# --------------------------------------------------------------------------
printf '\n'
if [[ "$RES_N" -gt 0 ]]; then
    printf '%s%sResources are running and billing.%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf 'Stop the meter when you are done:  %sscripts/destroy.sh%s\n\n' "$C_BOLD" "$C_RESET"
fi

# Exit codes
#   0  everything checked is in order (warnings may still have printed)
#   1  a fail-open prerequisite is missing - see the message
#   2  the script could not run at all (bad arguments, no .env)
if [[ "$PREREQ_FAIL" -ne 0 ]]; then
    printf '%s%splpgsql_check is not in the azure.extensions allowlist.%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
    printf 'Fix it BEFORE your first conversion run. The tool skips its deeper validation\n'
    printf 'silently when the extension is absent, so a report produced now is worthless\n'
    printf 'and cannot be re-validated afterwards - you would have to convert again.\n\n'
    printf '  az postgres flexible-server parameter set --resource-group %s \\\n' "$RG"
    printf '    --server-name <server> --name azure.extensions \\\n'
    printf '    --value "%s"\n\n' "${PG_REQUIRED_EXTENSIONS:-orafce,uuid-ossp,pgcrypto,pg_trgm,postgis,postgis_topology,postgis_tiger_geocoder,pg_partman,pg_stat_statements,plpgsql_check,dblink}"
    printf 'Then set shared_preload_libraries to "%s" and restart the server.\n\n' \
        "${PG_PRELOAD_LIBRARIES:-pg_partman_bgw,pg_stat_statements,plpgsql_check}"
    exit 1
fi
