#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# destroy.sh - delete the lab's resource group and stop the meter.
#
# THIS IS THE MONEY-SAVING SCRIPT. Run it whenever you stop working. The lab
# runs an Oracle VM, a jumpbox, two PostgreSQL flexible servers and a Bastion
# host; left running overnight it is not a rounding error.
#
# Deleting the resource group is irreversible. The script therefore:
#   - shows you exactly what is in the group before touching anything,
#   - makes you TYPE THE RESOURCE GROUP NAME to confirm (unless --yes),
#   - remembers the Key Vault and Foundry account names first, because both
#     are soft-deleted rather than removed and will block the next deploy
#     with "name already in use" until they are purged.
#
# Part of the Contoso Store Oracle -> Azure Database for PostgreSQL lab.
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_REDBG=$'\033[41m\033[97m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED='';   C_GREEN=''; C_YELLOW=''
    C_CYAN='';  C_REDBG=''
fi

ok()   { printf '  %s[ ok ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
info() { printf '  %s[ .. ]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  {
    printf '\n%s%sdestroy failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
ASSUME_YES=0
NO_WAIT=0
# Purge by default. Key Vault and Cognitive Services accounts are soft-deleted,
# not deleted, so leaving them behind reserves the names and makes the NEXT
# deploy.sh fail with "FlagMustBeSetForRestore" / "name already in use" against
# a resource the reader cannot see in the portal. This was found by actually
# doing it: destroy, then redeploy, and the Foundry account blocked it.
#
# The whole cost story of this lab is "destroy it at night, redeploy tomorrow",
# so a default that quietly breaks redeploy is the wrong default. --no-purge is
# there for the rare case where you want the name held.
PURGE=1
RG_OVERRIDE=''

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - delete the lab resource group and stop the Azure meter.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} [options]

${C_BOLD}OPTIONS${C_RESET}
    -y, --yes                Skip the "type the resource group name" prompt.
                             For CI and for people who are very sure.
    --resource-group <name>  Delete this group instead of AZ_RESOURCE_GROUP.
    --no-wait                Start the delete and return immediately. The
                             group still disappears; you just stop watching.
    --no-purge               Leave the soft-deleted Key Vault and Microsoft
                             Foundry account in place. Only do this if you
                             want the names held; it makes the next deploy
                             fail until they are purged or they expire.
    --purge                  Accepted and ignored. Purging is the default now;
                             the flag is kept so older instructions still work.
    -h, --help               Show this help and exit.

${C_BOLD}WHY PURGING IS THE DEFAULT${C_RESET}
    Key Vault and Cognitive Services (Foundry) accounts are ${C_BOLD}soft-deleted${C_RESET},
    not deleted. The names stay reserved for 7-90 days, and the next
    deploy.sh fails with a confusing "name is already in use" or
    "FlagMustBeSetForRestore" that has no visible resource behind it.
    Since this lab is built to be destroyed nightly and redeployed, that
    default would break the normal loop. Purging is therefore on by default.

${C_BOLD}WHAT THIS DOES NOT TOUCH${C_RESET}
    Your local Docker container, ./generated, ./out, or .env. Only Azure.

${C_BOLD}EXIT STATUS${C_RESET}
    0  The group was deleted, or did not exist to begin with.
    1  Something went wrong. Resources may still be billing - check the portal.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)           ASSUME_YES=1; shift ;;
        --no-wait)          NO_WAIT=1; shift ;;
        --purge)            PURGE=1; shift ;;
        --no-purge)         PURGE=0; shift ;;
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
elif [[ -z "$RG_OVERRIDE" ]]; then
    die ".env not found at ${ENV_FILE} and --resource-group was not given" \
        "cp '${REPO_ROOT}/.env.example' '${ENV_FILE}', or run: ${SCRIPT_NAME} --resource-group <name>"
fi

have az || die "az CLI not installed" "brew install azure-cli"
az account show >/dev/null 2>&1 || die "Azure CLI is not logged in" "az login"

RG="${RG_OVERRIDE:-${AZ_RESOURCE_GROUP:-}}"
[[ -n "$RG" ]] || die "no resource group name" "set AZ_RESOURCE_GROUP in ${ENV_FILE}, or pass --resource-group <name>"

SUB_NAME="$(az account show --query name -o tsv 2>/dev/null || echo '?')"
SUB_ID="$(az account show --query id -o tsv 2>/dev/null || echo '?')"

if [[ -n "${AZ_SUBSCRIPTION_ID:-}" && "$AZ_SUBSCRIPTION_ID" != "00000000-0000-0000-0000-000000000000" \
      && "$SUB_ID" != "$AZ_SUBSCRIPTION_ID" ]]; then
    die "the selected subscription (${SUB_ID}) is not AZ_SUBSCRIPTION_ID (${AZ_SUBSCRIPTION_ID})" \
        "az account set --subscription ${AZ_SUBSCRIPTION_ID}
       Refusing to delete a resource group in a subscription you did not configure."
fi

# --------------------------------------------------------------------------
# Banner
# --------------------------------------------------------------------------
printf '\n'
printf '%s%s                                                                    %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '%s%s   DESTROY - this permanently deletes an Azure resource group        %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '%s%s                                                                    %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '\n'
printf '  %-16s %s%s%s\n' "subscription" "$C_BOLD" "$SUB_NAME" "$C_RESET"
printf '  %-16s %s\n'     ""             "$C_DIM$SUB_ID$C_RESET"
printf '  %-16s %s%s%s\n' "resource group" "$C_BOLD$C_RED" "$RG" "$C_RESET"
printf '\n'

if ! az group show --name "$RG" -o none 2>/dev/null; then
    printf '  %s%sResource group "%s" does not exist.%s\n' "$C_BOLD" "$C_GREEN" "$RG" "$C_RESET"
    printf '  %sNothing to delete, nothing is billing.%s\n\n' "$C_DIM" "$C_RESET"
    if [[ "$PURGE" -eq 1 ]]; then
        printf '  %s--purge given; still checking for soft-deleted vaults and Foundry accounts.%s\n\n' "$C_DIM" "$C_RESET"
    else
        exit 0
    fi
fi

# --------------------------------------------------------------------------
# Inventory. Remember the soft-delete-prone names before they vanish.
# --------------------------------------------------------------------------
RG_LOCATION="$(az group show --name "$RG" --query location -o tsv 2>/dev/null || echo "${AZ_LOCATION:-}")"
KV_NAMES=''
CS_NAMES=''
RES_COUNT=0

if az group show --name "$RG" -o none 2>/dev/null; then
    printf '  %sContents:%s\n' "$C_BOLD" "$C_RESET"
    if have jq; then
        RES_JSON="$(az resource list --resource-group "$RG" -o json 2>/dev/null || echo '[]')"
        RES_COUNT="$(printf '%s' "$RES_JSON" | jq 'length')"
        printf '%s' "$RES_JSON" \
        | jq -r 'group_by(.type)[] | "\(length)\t\(.[0].type)"' \
        | sort -rn \
        | while IFS=$'\t' read -r N T; do printf '    %3s x %s\n' "$N" "${T#Microsoft.}"; done
        KV_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.KeyVault/vaults")       | .name')"
        CS_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.CognitiveServices/accounts") | .name')"
    else
        az resource list --resource-group "$RG" --query '[].{name:name,type:type}' -o tsv 2>/dev/null | sed 's/^/    /'
        RES_COUNT="$(az resource list --resource-group "$RG" --query 'length(@)' -o tsv 2>/dev/null || echo 0)"
        KV_NAMES="$(az keyvault list --resource-group "$RG" --query '[].name' -o tsv 2>/dev/null || true)"
        CS_NAMES="$(az cognitiveservices account list --resource-group "$RG" --query '[].name' -o tsv 2>/dev/null || true)"
    fi
    printf '\n    %s%s resource(s) will be deleted. This cannot be undone.%s\n\n' "$C_BOLD" "$RES_COUNT" "$C_RESET"
fi

# --------------------------------------------------------------------------
# Confirm - type the resource group name
# --------------------------------------------------------------------------
if [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "--yes given, skipping confirmation"
elif [[ "$RES_COUNT" -eq 0 ]] && ! az group show --name "$RG" -o none 2>/dev/null; then
    :   # group is already gone; --purge path only
else
    [[ -r /dev/tty ]] || die "not a TTY, so the confirmation prompt cannot be shown" \
        "re-run with --yes if you really mean it"
    printf '  %sType the resource group name to confirm deletion.%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s(anything else aborts)%s\n\n' "$C_DIM" "$C_RESET"
    printf '  %s> %s' "$C_BOLD$C_RED" "$C_RESET"
    TYPED=''
    read -r TYPED < /dev/tty || true
    if [[ "$TYPED" != "$RG" ]]; then
        printf '\n  %s%sAborted.%s Nothing was deleted.\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        printf '  %syou typed "%s", expected "%s"%s\n\n' "$C_DIM" "$TYPED" "$RG" "$C_RESET"
        exit 0
    fi
    printf '\n'
fi

# --------------------------------------------------------------------------
# Delete
# --------------------------------------------------------------------------
if az group show --name "$RG" -o none 2>/dev/null; then
    START_TS="$(date +%s)"
    if [[ "$NO_WAIT" -eq 1 ]]; then
        info "deleting ${RG} (--no-wait)"
        az group delete --name "$RG" --yes --no-wait \
            || die "could not start deletion of ${RG}" \
                   "check for resource locks: az lock list --resource-group '${RG}' -o table"
        ok "deletion started; it continues in Azure after this script exits"
        note "watch it with: az group show --name '${RG}' --query properties.provisioningState -o tsv"
    else
        info "deleting ${RG} - this usually takes 5-15 minutes"
        note "Bastion and the flexible servers are the slow ones. Ctrl-C stops watching, not deleting."
        az group delete --name "$RG" --yes \
            || die "deletion of ${RG} failed or was interrupted" \
                   "the most common cause is a resource lock: az lock list --resource-group '${RG}' -o table
       then: az lock delete --name <lock> --resource-group '${RG}'"
        ELAPSED=$(( $(date +%s) - START_TS ))
        ok "resource group ${RG} deleted in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
    fi
fi

# --------------------------------------------------------------------------
# Purge soft-deleted Key Vault and Foundry accounts
# --------------------------------------------------------------------------
if [[ "$PURGE" -eq 1 ]]; then
    printf '\n  %sPurging soft-deleted resources%s\n' "$C_BOLD" "$C_RESET"

    [[ -n "$KV_NAMES" ]] || KV_NAMES="${AZ_KEYVAULT_NAME:-}"
    [[ -n "$CS_NAMES" ]] || CS_NAMES="${FOUNDRY_RESOURCE_NAME:-}"

    for KV in $KV_NAMES; do
        [[ -n "$KV" ]] || continue
        if az keyvault show-deleted --name "$KV" -o none 2>/dev/null; then
            info "purging Key Vault ${KV}"
            if az keyvault purge --name "$KV" ${RG_LOCATION:+--location "$RG_LOCATION"} -o none 2>/dev/null; then
                ok "Key Vault ${KV} purged"
            else
                warn "could not purge Key Vault ${KV}"
                note "the vault may have purge protection enabled, which cannot be bypassed;"
                note "you will need a different AZ_KEYVAULT_NAME on the next deploy"
            fi
        else
            ok "Key Vault ${KV} is not in the soft-delete state"
        fi
    done

    for CS in $CS_NAMES; do
        [[ -n "$CS" ]] || continue
        if [[ -z "$RG_LOCATION" ]]; then
            warn "cannot purge Foundry account ${CS}: unknown location"
            note "az cognitiveservices account purge --name ${CS} --resource-group ${RG} --location <region>"
            continue
        fi
        info "purging Foundry / Cognitive Services account ${CS}"
        if az cognitiveservices account purge --name "$CS" --resource-group "$RG" \
               --location "$RG_LOCATION" -o none 2>/dev/null; then
            ok "Foundry account ${CS} purged"
        else
            warn "could not purge ${CS} (it may already be gone)"
            note "az cognitiveservices account list-deleted -o table   # to check"
        fi
    done
fi

# --------------------------------------------------------------------------
# Tidy local pointers to resources that no longer exist
# --------------------------------------------------------------------------
OUTPUTS_JSON="${REPO_ROOT}/generated/outputs.json"
if [[ -f "$OUTPUTS_JSON" ]] && [[ "$NO_WAIT" -eq 0 ]]; then
    mv "$OUTPUTS_JSON" "${OUTPUTS_JSON}.stale" 2>/dev/null \
        && note "generated/outputs.json now points at nothing; renamed to outputs.json.stale"
fi

printf '\n%s%sThe meter is off.%s No Azure resources remain in %s.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$RG"
printf '%sYour local Docker container, ./generated and .env were not touched.%s\n' "$C_DIM" "$C_RESET"
printf 'Redeploy any time with: %sscripts/deploy.sh%s\n\n' "$C_BOLD" "$C_RESET"
