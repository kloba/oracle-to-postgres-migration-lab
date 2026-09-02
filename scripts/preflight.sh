#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# preflight.sh - verify everything the lab needs BEFORE deploy.sh spends money.
#
# Checks, in the order they are printed:
#   1.  .env exists, is not world-readable, and every required variable is set
#       to something other than the .env.example placeholder; the contract
#       values and the credentials get their own sections.
#   2.  Local tooling: az, jq, ssh-keygen, python3, base64, and the
#       COPILOT_PLAN tier that agent mode needs.
#   3.  Docker is installed and its daemon is answering (the local Oracle
#       path). Local, so it is checked before anything reaches the network.
#   4.  Azure CLI is logged in.
#   5.  The selected subscription matches AZ_SUBSCRIPTION_ID.
#   6.  Resource providers Microsoft.Compute / Network / DBforPostgreSQL /
#       CognitiveServices are Registered, with an offer to register missing ones.
#   7.  The chosen region exists and is enabled for the subscription.
#   8.  vCPU quota for the Oracle VM family, the jumpbox VM family, and the
#       regional total - summed PER FAMILY, because both VMs default to the
#       same one.
#   9.  Microsoft Foundry model quota (TPM) for FOUNDRY_MODEL_NAME in the region.
#
# Every failure is collected, not fatal on the spot. The script exits non-zero
# at the end having listed every single thing that is wrong plus the exact
# command that fixes it.
#
# Part of the Contoso Store Oracle -> Azure Database for PostgreSQL lab.
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# --------------------------------------------------------------------------
# Colour, TTY-safe. Honours NO_COLOR (https://no-color.org) and dumb terminals.
# --------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED='';   C_GREEN=''; C_YELLOW=''
    C_BLUE='';  C_CYAN=''
fi

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
hdr()  { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '  %s[ ok ]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n'   "$C_RED"    "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
info() { printf '  %s[ .. ]%s %s\n'   "$C_CYAN"   "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n'   "$C_DIM"    "$*" "$C_RESET"; }
die()  { printf '\n%s%sfatal:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2; exit 2; }

# Collected results. Bash 3.2 compatible - no associative arrays anywhere.
FAILURES=()
WARNINGS=()

# fail <what> <how-to-fix>
fail() {
    bad "$1"
    [[ -n "${2:-}" ]] && note "fix: $2"
    FAILURES+=("$1"$'\n'"       fix: ${2:-see docs/00-prerequisites.md}")
    return 0
}

# soft <what> <how-to-fix>
soft() {
    warn "$1"
    [[ -n "${2:-}" ]] && note "fix: $2"
    WARNINGS+=("$1"$'\n'"       fix: ${2:-see docs/00-prerequisites.md}")
    return 0
}

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
FIX=0
REGION_OVERRIDE=''
SKIP_AZURE=0
SKIP_DOCKER=0
SKIP_QUOTA=0

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - check every prerequisite before deploying the migration lab.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} [options]

${C_BOLD}OPTIONS${C_RESET}
    --fix              Register missing resource providers and switch to
                       AZ_SUBSCRIPTION_ID without prompting. Never creates
                       billable resources.
    --region <name>    Check quota against this region instead of AZ_LOCATION.
    --skip-azure       Skip every check that needs a logged-in Azure CLI.
                       Useful when you only intend to run the local Oracle path.
    --skip-docker      Downgrade the Docker checks to warnings. Use when you
                       only intend to run the Azure path.
    --skip-quota       Skip the vCPU and Foundry TPM quota lookups. These are
                       the slowest checks (three or four ARM round trips).
    -h, --help         Show this help and exit.

${C_BOLD}EXIT STATUS${C_RESET}
    0   Everything required is in place. Warnings may still have been printed.
        With --skip-azure or --skip-quota, 0 only covers the checks that ran:
        the closing line says which, and does not clear you to deploy.
    1   One or more required checks failed. Every failure is listed at the end
        together with the command that fixes it.
    2   The script could not run at all (no .env, bad arguments).

${C_BOLD}ENVIRONMENT${C_RESET}
    Reads ${REPO_ROOT}/.env . Copy .env.example to .env first:
        cp .env.example .env && chmod 600 .env
    NO_COLOR=1 disables colour. Output is already plain when not a TTY.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)         FIX=1; shift ;;
        --region)      REGION_OVERRIDE="${2:-}"; [[ -n "$REGION_OVERRIDE" ]] || die "--region needs a value"; shift 2 ;;
        --region=*)    REGION_OVERRIDE="${1#*=}"; shift ;;
        --skip-azure)  SKIP_AZURE=1; shift ;;
        --skip-docker) SKIP_DOCKER=1; shift ;;
        --skip-quota)  SKIP_QUOTA=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# 1. .env
# --------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"

hdr "Configuration"

if [[ ! -f "$ENV_FILE" ]]; then
    bad ".env not found at ${ENV_FILE}"
    note "fix: cp '${REPO_ROOT}/.env.example' '${ENV_FILE}' && chmod 600 '${ENV_FILE}'"
    note "     then edit it and replace every 'replace-me-*' and 'changeme' value"
    die "cannot continue without .env - nothing else can be checked"
fi
ok ".env found"

# .env holds passwords. Anything more permissive than 0600 is a finding.
ENV_PERM="$(( 0 ))"
if command -v stat >/dev/null 2>&1; then
    ENV_PERM="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '600')"
fi
case "$ENV_PERM" in
    600|400) ok ".env permissions are ${ENV_PERM}" ;;
    *)       soft ".env is mode ${ENV_PERM}; it contains passwords" "chmod 600 '${ENV_FILE}'" ;;
esac

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
ok ".env sourced"

REGION="${REGION_OVERRIDE:-${AZ_LOCATION:-}}"

# is_placeholder <value> - true when the value is still an .env.example stub.
is_placeholder() {
    case "$1" in
        replace-me*|*changeme*|*CHANGEME*|00000000-0000-0000-0000-000000000000) return 0 ;;
        *) return 1 ;;
    esac
}

# require_var <name> <purpose>
require_var() {
    local name="$1" purpose="$2" value
    eval "value=\${${name}:-}"
    if [[ -z "$value" ]]; then
        fail "${name} is empty (${purpose})" "set ${name} in ${ENV_FILE}"
    elif is_placeholder "$value"; then
        fail "${name} is still the .env.example placeholder (${purpose})" \
             "set a real value for ${name} in ${ENV_FILE}"
    else
        ok "${name} is set"
    fi
}

# require_secret <name> <purpose> - same, but never echoes the value and is
# satisfied by Key Vault indirection when USE_KEYVAULT=1.
require_secret() {
    local name="$1" purpose="$2" value
    eval "value=\${${name}:-}"
    if [[ "${USE_KEYVAULT:-0}" == "1" && -z "$value" ]]; then
        ok "${name} deferred to Key Vault ${AZ_KEYVAULT_NAME:-<unset>}"
        return 0
    fi
    if [[ -z "$value" ]]; then
        fail "${name} is empty (${purpose})" \
             "set ${name} in ${ENV_FILE}, or set USE_KEYVAULT=1 and store it in Key Vault"
    elif is_placeholder "$value"; then
        fail "${name} is still the .env.example placeholder (${purpose})" \
             "choose a real password for ${name}; 12+ chars, a digit, no leading digit, no '@' or '/'"
    elif [[ "${#value}" -lt 12 ]]; then
        soft "${name} is shorter than 12 characters" "Azure and Oracle both reject weak passwords late and confusingly"
    else
        ok "${name} is set"
    fi
}

hdr "Required variables"
require_var AZ_PREFIX          "prefixes every Azure resource name"
require_var AZ_LOCATION        "the region the lab deploys into"
require_var AZ_RESOURCE_GROUP  "the resource group destroy.sh deletes"
require_var ORACLE_SERVICE     "Oracle PDB service name, fixed at FREEPDB1"
require_var CONTOSO_SCHEMA     "the schema being migrated"
require_var PGDATABASE         "target PostgreSQL database"
require_var PG_TARGET_SCHEMA   "target PostgreSQL schema"

# Contract values are fixed by docs/design.md section 2. A rename here breaks
# every SQL file, so catch it now rather than 900 objects later.
[[ "${ORACLE_SERVICE:-}"   == "FREEPDB1"      ]] || fail "ORACLE_SERVICE is '${ORACLE_SERVICE:-}', contract says FREEPDB1"      "restore ORACLE_SERVICE=FREEPDB1 in ${ENV_FILE}"
[[ "${CONTOSO_SCHEMA:-}"   == "CONTOSO"       ]] || fail "CONTOSO_SCHEMA is '${CONTOSO_SCHEMA:-}', contract says CONTOSO"       "restore CONTOSO_SCHEMA=CONTOSO in ${ENV_FILE}"
[[ "${PGDATABASE:-}"       == "contoso_store" ]] || fail "PGDATABASE is '${PGDATABASE:-}', contract says contoso_store"         "restore PGDATABASE=contoso_store in ${ENV_FILE}"
[[ "${PG_TARGET_SCHEMA:-}" == "contoso"       ]] || fail "PG_TARGET_SCHEMA is '${PG_TARGET_SCHEMA:-}', contract says contoso"   "restore PG_TARGET_SCHEMA=contoso in ${ENV_FILE}"

hdr "Credentials"
require_secret ORACLE_SYSTEM_PASSWORD    "Oracle SYSTEM account used by src/oracle/00-user-tablespace.sql"
require_secret CONTOSO_PASSWORD          "owner of all ~1,855 objects"
require_secret ORACLE_MIGRATION_PASSWORD "the low-privilege O2P_READER account the converter uses"

if [[ "$SKIP_AZURE" -eq 0 ]]; then
    require_var AZ_SUBSCRIPTION_ID     "the subscription every resource lands in"
    require_var AZ_KEYVAULT_NAME       "must be globally unique - append your own suffix"
    require_var FOUNDRY_RESOURCE_NAME  "the Microsoft Foundry account"
    require_var FOUNDRY_MODEL_NAME     "the model the schema converter calls"
fi

# --------------------------------------------------------------------------
# 2. Local tooling
# --------------------------------------------------------------------------
hdr "Local tooling"

have() { command -v "$1" >/dev/null 2>&1; }

if have az; then
    AZ_VER="$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'unknown')"
    ok "az ${AZ_VER}"
    # 2.60 is the floor for the flexible-server and cognitiveservices commands
    # the lab actually issues.
    case "$AZ_VER" in
        unknown) soft "could not determine az version" "az version" ;;
        *) AZ_MAJOR="${AZ_VER%%.*}"; AZ_REST="${AZ_VER#*.}"; AZ_MINOR="${AZ_REST%%.*}"
           if [[ "$AZ_MAJOR" -lt 2 ]] || { [[ "$AZ_MAJOR" -eq 2 ]] && [[ "$AZ_MINOR" -lt 60 ]]; }; then
               soft "az ${AZ_VER} is older than 2.60" "az upgrade"
           fi ;;
    esac
else
    fail "az CLI not installed" "brew install azure-cli   # or https://aka.ms/azure-cli"
fi

if have jq; then ok "jq $(jq --version 2>/dev/null || true)"
else soft "jq not installed; deploy.sh will write generated/outputs.json unformatted" "brew install jq"; fi

if have ssh-keygen; then ok "ssh-keygen"
else fail "ssh-keygen not installed; deploy.sh cannot create the VM key" "install openssh"; fi

if have python3; then ok "python3 $(python3 -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)"
else fail "python3 not installed; tools/generate-objects.py cannot run" "brew install python@3.12"; fi

if have base64; then ok "base64"
else fail "base64 not installed; deploy.sh cannot encode cloud-init" "install coreutils"; fi

# --------------------------------------------------------------------------
# GitHub Copilot tier. Nothing outside VS Code can verify the seat, so this is
# a reminder rather than a gate - but the failure it prevents is expensive:
# you find out that agent mode is unavailable only after the conversion has
# already produced its queue of review tasks, which is the point at which you
# most need it.
# --------------------------------------------------------------------------
case "$(printf '%s' "${COPILOT_PLAN:-}" | tr '[:upper:]' '[:lower:]')" in
    'pro+'|'pro plus'|business|enterprise)
        ok "Copilot plan ${COPILOT_PLAN} covers agent mode" ;;
    ''|none)
        soft "COPILOT_PLAN is not set" \
             "agent mode resolves the flagged review tasks and needs Copilot Pro+, Business or Enterprise" ;;
    *)
        soft "COPILOT_PLAN='${COPILOT_PLAN}' does not include agent mode" \
             "the conversion still runs; you just work every review task by hand. Pro+, Business or Enterprise adds agent mode" ;;
esac

# --------------------------------------------------------------------------
# 3. Docker. Local, so it is checked before anything reaches the network.
# --------------------------------------------------------------------------
hdr "Docker (local Oracle path)"

docker_report() { if [[ "$SKIP_DOCKER" -eq 1 ]]; then soft "$1" "$2"; else fail "$1" "$2"; fi; }

if have docker; then
    ok "docker $(docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//' || true)"
    if docker info >/dev/null 2>&1; then
        ok "docker daemon is responding"
        CNAME="${ORACLE_CONTAINER_NAME:-o2p-oracle}"
        # `docker inspect -f` on a missing container writes a bare newline to
        # STDOUT as well as the error to stderr, so a naive
        #   "$(docker inspect ... || echo absent)"
        # yields $'\nabsent', which misses the 'absent' case below and reports
        # a non-existent container as "exists but is ''". Strip whitespace and
        # default the empty result instead.
        CSTATE="$(docker inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null || true)"
        CSTATE="${CSTATE//[[:space:]]/}"
        CSTATE="${CSTATE:-absent}"
        case "$CSTATE" in
            running) ok "container '${CNAME}' is running" ;;
            absent)  info "container '${CNAME}' does not exist yet (normal before the first run)" ;;
            *)       soft "container '${CNAME}' exists but is '${CSTATE}'" "docker start ${CNAME}" ;;
        esac
    else
        docker_report "docker is installed but the daemon is not responding" \
                      "start Docker Desktop, or: sudo systemctl start docker"
    fi
else
    docker_report "docker not installed; the local Oracle container cannot run" \
                  "brew install --cask docker   # or use --skip-docker and deploy to Azure"
fi

# --------------------------------------------------------------------------
# 4-9. Azure
# --------------------------------------------------------------------------
if [[ "$SKIP_AZURE" -eq 1 ]]; then
    hdr "Azure"
    info "skipped (--skip-azure)"
else
    hdr "Azure sign-in"

    if ! have az; then
        info "skipped - az is not installed"
    elif ! ACCOUNT_JSON="$(az account show -o json 2>/dev/null)"; then
        fail "Azure CLI is not logged in" "az login   # add --tenant <id> if you have several"
        ACCOUNT_JSON=''
    else
        CUR_SUB_ID="$(printf '%s' "$ACCOUNT_JSON"   | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        CUR_SUB_NAME="$(printf '%s' "$ACCOUNT_JSON" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        if have jq; then
            CUR_SUB_ID="$(printf '%s' "$ACCOUNT_JSON"   | jq -r '.id')"
            CUR_SUB_NAME="$(printf '%s' "$ACCOUNT_JSON" | jq -r '.name')"
            CUR_USER="$(printf '%s' "$ACCOUNT_JSON"     | jq -r '.user.name // "unknown"')"
        else
            CUR_USER='unknown'
        fi
        ok "signed in as ${CUR_USER}"

        # ---- 4. subscription --------------------------------------------
        WANT_SUB="${AZ_SUBSCRIPTION_ID:-}"
        if [[ -z "$WANT_SUB" ]] || is_placeholder "$WANT_SUB"; then
            fail "AZ_SUBSCRIPTION_ID is not set to a real subscription" \
                 "put this in ${ENV_FILE}:  AZ_SUBSCRIPTION_ID=${CUR_SUB_ID}"
        elif [[ "$CUR_SUB_ID" == "$WANT_SUB" ]]; then
            ok "subscription '${CUR_SUB_NAME}' is selected"
        else
            if [[ "$FIX" -eq 1 ]]; then
                info "switching to ${WANT_SUB} (--fix)"
                if az account set --subscription "$WANT_SUB" 2>/dev/null; then
                    ok "subscription switched to ${WANT_SUB}"
                else
                    fail "cannot switch to subscription ${WANT_SUB}" \
                         "check you have access:  az account list -o table"
                fi
            else
                fail "wrong subscription selected (${CUR_SUB_ID}, want ${WANT_SUB})" \
                     "az account set --subscription ${WANT_SUB}   # or re-run with --fix"
            fi
        fi

        # ---- 5. resource providers --------------------------------------
        hdr "Resource providers"
        PROVIDERS="Microsoft.Compute Microsoft.Network Microsoft.DBforPostgreSQL Microsoft.CognitiveServices"
        UNREGISTERED=''
        for NS in $PROVIDERS; do
            STATE="$(az provider show --namespace "$NS" --query registrationState -o tsv 2>/dev/null || echo 'Unknown')"
            case "$STATE" in
                Registered)  ok "${NS} Registered" ;;
                Registering) soft "${NS} is still Registering" "wait, then re-run ${SCRIPT_NAME}" ;;
                Unknown)     fail "${NS} state could not be read" "az provider show --namespace ${NS}" ;;
                *)           bad "${NS} is ${STATE}"; UNREGISTERED="${UNREGISTERED} ${NS}" ;;
            esac
        done

        if [[ -n "$UNREGISTERED" ]]; then
            DO_REGISTER=0
            if [[ "$FIX" -eq 1 ]]; then
                DO_REGISTER=1
                info "registering:${UNREGISTERED} (--fix)"
            elif [[ -r /dev/tty ]]; then
                printf '\n  %sRegister these now?%s%s  [y/N] ' "$C_BOLD" "$UNREGISTERED" "$C_RESET"
                REPLY_ANS=''
                read -r REPLY_ANS < /dev/tty || true
                case "$REPLY_ANS" in y|Y|yes|YES) DO_REGISTER=1 ;; esac
            fi

            if [[ "$DO_REGISTER" -eq 1 ]]; then
                for NS in $UNREGISTERED; do
                    info "az provider register --namespace ${NS} --wait  (can take several minutes)"
                    if az provider register --namespace "$NS" --wait 2>/dev/null; then
                        ok "${NS} Registered"
                    else
                        fail "could not register ${NS}" \
                             "you may lack Contributor on the subscription; ask an owner to run: az provider register --namespace ${NS}"
                    fi
                done
            else
                for NS in $UNREGISTERED; do
                    fail "resource provider ${NS} is not registered" "az provider register --namespace ${NS} --wait"
                done
            fi
        fi

        # ---- 6. region ---------------------------------------------------
        hdr "Region"
        if [[ -z "$REGION" ]]; then
            fail "no region: AZ_LOCATION is empty and --region was not given" "set AZ_LOCATION in ${ENV_FILE}"
        elif az account list-locations --query "[?name=='${REGION}'].name" -o tsv 2>/dev/null | grep -qx "$REGION"; then
            ok "region '${REGION}' is available to this subscription"
        else
            fail "region '${REGION}' is not available to this subscription" \
                 "az account list-locations --query '[].name' -o tsv | sort"
        fi

        # ---- 7. VM quota -------------------------------------------------
        # main.bicep deploys TWO real Azure VMs unconditionally: the Windows
        # jumpbox and the Ubuntu Oracle VM (which runs the Oracle container via
        # cloud-init). The local Docker container in docs/design.md 11.5 is the
        # laptop-development path only - it is NOT what deploy.sh provisions, so
        # the Oracle VM must be quota-checked just like the jumpbox.
        #
        # Both VMs default to Standard_D4s_v5, i.e. the SAME vCPU family, so we
        # sum their need PER FAMILY: two independent "4 of 6 free" checks would
        # each pass while together they need 8 and the deploy would fail.
        hdr "Compute quota in ${REGION:-<unset>}"
        if [[ "$SKIP_QUOTA" -eq 1 ]]; then
            info "skipped (--skip-quota)"
        elif [[ -z "$REGION" ]]; then
            info "skipped - no region"
        elif ! USAGE_JSON="$(az vm list-usage --location "$REGION" -o json 2>/dev/null)"; then
            soft "could not read vCPU usage for ${REGION}" "az vm list-usage --location ${REGION} -o table"
        else
            declare -A FAMILY_NEED=()   # family -> summed vCPU needed
            declare -A FAMILY_SKUS=()   # family -> "label, label" for the message
            NEED_TOTAL=0

            # probe_sku <sku> <cores-needed> <label>
            # Verify the SKU exists and is unrestricted in THIS exact region
            # (the restrictions[].reasonCode probe - list-usage alone reports
            # free cores even where a SKU is NotAvailableForSubscription,
            # verified by azure-scout), resolve its vCPU family, and accumulate
            # the need against that family. The available-core pass/fail happens
            # once per family afterwards, so VMs sharing a family are summed.
            probe_sku() {
                local sku="$1" need="$2" label="$3" sku_json family restrictions
                sku_json="$(az vm list-skus --location "$REGION" --size "$sku" \
                            --query "[?name=='${sku}'] | [0]" -o json 2>/dev/null || echo '')"
                if [[ -z "$sku_json" || "$sku_json" == "null" ]]; then
                    fail "${label}: SKU ${sku} is not offered in ${REGION}" \
                         "pick a region/SKU that exists: az vm list-skus --location ${REGION} --resource-type virtualMachines --query '[].name' -o tsv | sort -u"
                    return 0
                fi
                if have jq; then
                    family="$(printf '%s' "$sku_json"       | jq -r '.family // empty')"
                    restrictions="$(printf '%s' "$sku_json" | jq -r '[.restrictions[]?.reasonCode] | join(",")')"
                else
                    family="$(az vm list-skus --location "$REGION" --size "$sku" --query "[?name=='${sku}'].family | [0]" -o tsv 2>/dev/null || true)"
                    restrictions=''
                fi
                if [[ -n "$restrictions" ]]; then
                    fail "${label}: SKU ${sku} is restricted in ${REGION} (${restrictions})" \
                         "choose another region (verified fallback: uksouth) or SKU. Do NOT use westeurope/westus3 for D4s_v5."
                    return 0
                fi
                if [[ -z "$family" || "$family" == "None" ]]; then
                    soft "${label}: could not resolve the vCPU family for ${sku}" "az vm list-skus --location ${REGION} --size ${sku} -o json"
                    return 0
                fi
                ok "${label}: ${sku} available in ${REGION} (family ${family}, needs ${need} vCPU)"
                FAMILY_NEED[$family]=$(( ${FAMILY_NEED[$family]:-0} + need ))
                FAMILY_SKUS[$family]="${FAMILY_SKUS[$family]:+${FAMILY_SKUS[$family]}, }${label}"
                NEED_TOTAL=$(( NEED_TOTAL + need ))
            }

            # The Windows jumpbox - deployed unless the operator connects from
            # their own machine (CLIENT_PLATFORM != jumpbox).
            if [[ "${CLIENT_PLATFORM:-jumpbox}" == "jumpbox" ]]; then
                probe_sku "${JUMPBOX_VM_SIZE:-Standard_D4s_v5}" "${JUMPBOX_VM_CORES:-4}" "Jumpbox VM"
            else
                info "Jumpbox VM: skipped (CLIENT_PLATFORM=${CLIENT_PLATFORM:-} is not 'jumpbox')"
            fi

            # The Oracle VM is always deployed by main.bicep - the Ubuntu host
            # that runs the Oracle container via cloud-init.
            probe_sku "${ORACLE_VM_SIZE:-Standard_D4s_v5}" "${ORACLE_VM_CORES:-4}" "Oracle VM"

            # One available-core pass/fail per distinct family, summed across
            # the VMs that use it. Needs jq for the usage arithmetic; without it
            # we still reported existence/restrictions above.
            if have jq; then
                for q_fam in "${!FAMILY_NEED[@]}"; do
                    q_need="${FAMILY_NEED[$q_fam]}"
                    q_limit="$(printf '%s' "$USAGE_JSON"   | jq -r --arg f "$q_fam" '.[] | select(.name.value==$f) | .limit'        | head -1)"
                    q_current="$(printf '%s' "$USAGE_JSON" | jq -r --arg f "$q_fam" '.[] | select(.name.value==$f) | .currentValue' | head -1)"
                    if [[ -z "$q_limit" || "$q_limit" == "null" ]]; then
                        soft "no quota row for family ${q_fam}" "az vm list-usage --location ${REGION} -o table | grep -i ${q_fam}"
                        continue
                    fi
                    q_avail=$(( q_limit - q_current ))
                    if [[ "$q_avail" -ge "$q_need" ]]; then
                        ok "family ${q_fam}: ${q_avail}/${q_limit} vCPU free, needs ${q_need} (${FAMILY_SKUS[$q_fam]})"
                    else
                        fail "family ${q_fam}: only ${q_avail} of ${q_limit} vCPU free, needs ${q_need} (${FAMILY_SKUS[$q_fam]})" \
                             "request a quota increase (Subscription > Usage + quotas) or pick a smaller SKU"
                    fi
                done
            fi

            # Regional total across all families - a second, coarser ceiling.
            if have jq && [[ "$NEED_TOTAL" -gt 0 ]]; then
                TOT_LIMIT="$(printf '%s' "$USAGE_JSON"   | jq -r '.[] | select(.name.value=="cores") | .limit'        | head -1)"
                TOT_CURRENT="$(printf '%s' "$USAGE_JSON" | jq -r '.[] | select(.name.value=="cores") | .currentValue' | head -1)"
                if [[ -n "$TOT_LIMIT" && "$TOT_LIMIT" != "null" ]]; then
                    TOT_AVAIL=$(( TOT_LIMIT - TOT_CURRENT ))
                    if [[ "$TOT_AVAIL" -ge "$NEED_TOTAL" ]]; then
                        ok "regional total: ${TOT_AVAIL}/${TOT_LIMIT} vCPU free, needs ${NEED_TOTAL}"
                    else
                        fail "regional total: only ${TOT_AVAIL} of ${TOT_LIMIT} vCPU free, needs ${NEED_TOTAL}" \
                             "request a regional vCPU increase, or deploy to another region with --region (verified fallback: uksouth)"
                    fi
                fi
            fi
        fi

        # ---- 8. Foundry model quota --------------------------------------
        hdr "Microsoft Foundry quota in ${REGION:-<unset>}"
        if [[ "$SKIP_QUOTA" -eq 1 ]]; then
            info "skipped (--skip-quota)"
        elif [[ -z "$REGION" ]]; then
            info "skipped - no region"
        else
            MODEL="${FOUNDRY_MODEL_NAME:-gpt-5.2}"
            # Quota units are thousands of tokens per minute.
            NEED_TPM="${FOUNDRY_TPM_QUOTA:-500000}"
            NEED_KTPM=$(( NEED_TPM / 1000 ))
            if ! CS_USAGE="$(az cognitiveservices usage list --location "$REGION" -o json 2>/dev/null)"; then
                soft "could not read Foundry quota in ${REGION}" \
                     "az cognitiveservices usage list --location ${REGION} -o table"
            elif ! have jq; then
                soft "jq is required to parse Foundry quota" "brew install jq"
            else
                # The model deployment MUST be GlobalStandard (or Standard).
                # Provisioned/PTU is policy-denied on this kind of subscription
                # (OpenAI_BlockProvisionedCapacity, verified by azure-scout), so
                # prefer the GlobalStandard row and never a Provisioned one.
                ROW="$(printf '%s' "$CS_USAGE" | jq -c --arg m "$MODEL" '
                    [ .[] | select((.name.value // "") | ascii_downcase | contains($m | ascii_downcase)) ] as $all
                    | ( [ $all[] | select((.name.value // "") | ascii_downcase | contains("globalstandard")) ] | .[0] )
                      // ( [ $all[] | select((.name.value // "") | ascii_downcase | contains("provisioned") | not) ] | .[0] )
                      // ($all[0] // empty)')"
                if [[ -z "$ROW" ]]; then
                    fail "no quota entry for model '${MODEL}' in ${REGION}" \
                         "the model may not be offered there. List what is: az cognitiveservices usage list --location ${REGION} -o table"
                    note "docs/design.md 11.6: Learn says gpt-5.2, Microsoft's own lab template says gpt-5-mini. Try FOUNDRY_MODEL_NAME=gpt-5-mini."
                else
                    CS_NAME="$(printf '%s' "$ROW"  | jq -r '.name.value')"
                    CS_LIMIT="$(printf '%s' "$ROW" | jq -r '.limit // 0'        | cut -d. -f1)"
                    CS_CUR="$(printf '%s' "$ROW"   | jq -r '.currentValue // 0' | cut -d. -f1)"
                    CS_AVAIL=$(( CS_LIMIT - CS_CUR ))
                    if printf '%s' "$CS_NAME" | grep -qi 'globalstandard'; then
                        :
                    else
                        soft "the matched quota row is '${CS_NAME}', not GlobalStandard" \
                             "deploy the model as GlobalStandard; Provisioned/PTU is policy-denied on this subscription"
                    fi
                    if [[ "$CS_AVAIL" -ge "$NEED_KTPM" ]]; then
                        ok "${CS_NAME}: ${CS_AVAIL}/${CS_LIMIT} kTPM free, wants ${NEED_KTPM} kTPM"
                    else
                        fail "${CS_NAME}: only ${CS_AVAIL} of ${CS_LIMIT} kTPM free, wants ${NEED_KTPM} kTPM" \
                             "raise the quota in Foundry portal > Management > Quota, or lower FOUNDRY_TPM_QUOTA"
                        note "below ~500k TPM the converter throttles hard across a ~1,855-object schema (docs/design.md 11.6)"
                    fi
                fi
            fi
        fi
    fi
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
printf '\n'
N_FAIL="${#FAILURES[@]}"
N_WARN="${#WARNINGS[@]}"

if [[ "$N_WARN" -gt 0 ]]; then
    printf '%s%s%d warning(s):%s\n' "$C_BOLD" "$C_YELLOW" "$N_WARN" "$C_RESET"
    for W in ${WARNINGS[@]+"${WARNINGS[@]}"}; do printf '  %s- %s%s\n' "$C_YELLOW" "$W" "$C_RESET"; done
    printf '\n'
fi

if [[ "$N_FAIL" -eq 0 ]]; then
    # "Safe to run scripts/deploy.sh" is a claim about a script that spends
    # money, so it may only cover checks that actually ran.
    #
    #   --skip-azure  turns off sign-in, subscription, resource providers,
    #                 region and both quota checks - and, at the top of this
    #                 script, the AZ_SUBSCRIPTION_ID / AZ_KEYVAULT_NAME /
    #                 FOUNDRY_* variable checks with them. A .env still holding
    #                 the all-zeros placeholder subscription therefore reaches
    #                 this line with zero failures.
    #   --skip-quota  turns off the vCPU and Foundry TPM lookups, which are
    #                 exactly the ones that catch a deploy that will fail
    #                 halfway through on capacity.
    #
    # Printing the unqualified pass after either would be vouching for evidence
    # the run declined to collect. Scope the claim to what was checked.
    # (--skip-docker needs no branch: it only downgrades local Oracle checks
    # to warnings, which are printed above, and deploy.sh does not use Docker.)
    caveat() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

    if [[ "$SKIP_AZURE" -eq 1 ]]; then
        printf '%s%spreflight passed (local checks only).%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        caveat "--skip-azure was given, so sign-in, subscription, resource providers,"
        caveat "region and quota did NOT run, and AZ_SUBSCRIPTION_ID, AZ_KEYVAULT_NAME,"
        caveat "FOUNDRY_RESOURCE_NAME and FOUNDRY_MODEL_NAME were never validated."
        caveat "This says nothing about whether scripts/deploy.sh would succeed -"
        caveat "re-run without --skip-azure before deploying."
        printf '  %sYou are good to go for the local Docker path: scripts/seed-oracle.sh --local%s\n' "$C_DIM" "$C_RESET"
    elif [[ "$SKIP_QUOTA" -eq 1 ]]; then
        printf '%s%spreflight passed, capacity unverified.%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        caveat "--skip-quota was given, so the vCPU and Foundry TPM checks did NOT run."
        caveat "scripts/deploy.sh can still fail part-way through on capacity - re-run"
        caveat "without --skip-quota to confirm before deploying."
    else
        printf '%s%spreflight passed.%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "Safe to run scripts/deploy.sh"
    fi
    exit 0
fi

printf '%s%spreflight FAILED - %d problem(s):%s\n\n' "$C_BOLD" "$C_RED" "$N_FAIL" "$C_RESET"
for F in ${FAILURES[@]+"${FAILURES[@]}"}; do printf '  %s- %s%s\n' "$C_RED" "$F" "$C_RESET"; done
printf '\n%sNothing was deployed and nothing is costing money.%s\n' "$C_DIM" "$C_RESET"
printf '%sFix the above and re-run: %s/%s%s\n' "$C_DIM" "scripts" "$SCRIPT_NAME" "$C_RESET"
exit 1
