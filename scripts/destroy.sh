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
SUB_OVERRIDE=''

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - delete the lab resource group and stop the Azure meter.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} [options]

${C_BOLD}OPTIONS${C_RESET}
    -y, --yes                Skip the "type the resource group name" prompt.
                             For CI and for people who are very sure.
    --resource-group <name>  Delete this group instead of AZ_RESOURCE_GROUP.
    --subscription <id>      Delete from this subscription. Overrides both
                             AZ_SUBSCRIPTION_ID and the id derived from
                             generated/outputs.json. The active az default is
                             never used - see WHICH SUBSCRIPTION below.
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

${C_BOLD}WHICH SUBSCRIPTION${C_RESET}
    Never the ambient ${C_BOLD}az account${C_RESET} default - that is global state that drifts
    and would aim this delete at whatever happens to be current. The
    subscription is pinned explicitly, in order: --subscription, then
    AZ_SUBSCRIPTION_ID, then the subscription generated/outputs.json was
    deployed into. A configured id that disagrees with the deployed one is a
    stop, not a guess; if none can be established, ${SCRIPT_NAME} refuses.

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
        --subscription)     SUB_OVERRIDE="${2:-}"; [[ -n "$SUB_OVERRIDE" ]] || die "--subscription needs a value"; shift 2 ;;
        --subscription=*)   SUB_OVERRIDE="${1#*=}"; shift ;;
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

# --------------------------------------------------------------------------
# Which subscription - and it is NEVER the ambient `az account` default
#
# The active subscription is global, mutable state: an `az login` in another
# window, or a teammate's `az account set`, silently repoints it. Deleting "the
# resource group in whatever subscription happens to be current" is how you wipe
# the wrong group, or fail to find yours and then purge names elsewhere. So the
# subscription is pinned explicitly and passed on every az call with
# --subscription; we never run `az account set`.
#
# Order: --subscription (a deliberate human override), then the subscription the
# deployment recorded in generated/outputs.json, then a configured
# AZ_SUBSCRIPTION_ID. We never use the ambient `az account` default.
#
# The recorded id is derived by collecting the subscription component of EVERY
# /subscriptions/<guid>/ resource id in outputs.json, case-folding, and requiring
# exactly ONE distinct, well-formed GUID. When outputs.json is present it is
# authoritative and must verify cleanly: unreadable, no jq, no resource id, a
# malformed/non-GUID component, or two different subscriptions (an A+B document)
# are each a STOP -- we never fall through to a configured or ambient id, because
# that is how a stale AZ_SUBSCRIPTION_ID deletes a same-named group in the wrong
# subscription, and a first-id-wins guess would rubber-stamp an ambiguous file.
# --subscription is the one documented escape: it is honoured even when
# outputs.json cannot be verified, but never silently -- the reason is warned.
lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }   # case-fold a guid
is_guid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# classify_recorded_sub - inspect EVERY /subscriptions/<id>/ resource id in
# generated/outputs.json and echo exactly one of:
#   ok <guid>        one distinct, well-formed subscription across all ids
#   none             no resource id names a subscription
#   malformed        a /subscriptions/ id whose component is not a GUID
#   conflict <a> <b> two or more distinct subscriptions were recorded
# It never guesses a winner; case is folded before comparison.
classify_recorded_sub() {
    local raw line lcl guid='' extras='' malformed=0
    raw="$(jq -r '[ .. | strings | select(startswith("/subscriptions/")) | split("/") | (.[2] // "") ] | unique | .[]' "$OUTPUTS_JSON" 2>/dev/null)" \
        || { printf 'malformed'; return 0; }
    [[ -n "$raw" ]] || { printf 'none'; return 0; }
    while IFS= read -r line; do
        [[ -n "$line" ]] || { malformed=1; continue; }
        lcl="$(lc "$line")"
        if is_guid "$lcl"; then
            if [[ -z "$guid" ]]; then guid="$lcl"
            elif [[ " $guid $extras " != *" $lcl "* ]]; then extras="${extras:+$extras }$lcl"; fi
        else
            malformed=1
        fi
    done <<< "$raw"
    if [[ -n "$extras" ]]; then printf 'conflict %s' "$guid $extras"; return 0; fi
    if [[ "$malformed" -eq 1 ]]; then printf 'malformed'; return 0; fi
    [[ -n "$guid" ]] || { printf 'none'; return 0; }
    printf 'ok %s' "$guid"
}

OUTPUTS_JSON="${REPO_ROOT}/generated/outputs.json"
SUB_FROM_OUT=''
if [[ -f "$OUTPUTS_JSON" ]]; then
    out_reason=''
    if [[ ! -r "$OUTPUTS_JSON" ]]; then
        out_reason="generated/outputs.json exists but is not readable"
    elif ! have jq; then
        out_reason="generated/outputs.json exists but jq is not installed, so its subscription cannot be verified"
    else
        cls="$(classify_recorded_sub)"
        case "$cls" in
            "ok "*)       SUB_FROM_OUT="${cls#ok }" ;;
            "conflict "*) out_reason="generated/outputs.json records more than one subscription (${cls#conflict }); its recorded identity is ambiguous" ;;
            malformed)    out_reason="generated/outputs.json records a malformed (non-GUID) subscription id" ;;
            *)            out_reason="generated/outputs.json contains no /subscriptions/<id> resource id to anchor the subscription" ;;
        esac
    fi
    if [[ -n "$out_reason" ]]; then
        if [[ -n "$SUB_OVERRIDE" ]]; then
            warn "$out_reason"
            note "using the subscription you passed with --subscription (${SUB_OVERRIDE}); not deriving one from outputs.json."
        else
            die "$out_reason" \
                "pass --subscription <id> after confirming which subscription the lab is in, or
       repair/remove generated/outputs.json and re-deploy. Refusing to delete without a
       single, verified recorded subscription."
        fi
    fi
fi
SUB_FROM_ENV="${AZ_SUBSCRIPTION_ID:-}"
[[ "$SUB_FROM_ENV" == "00000000-0000-0000-0000-000000000000" ]] && SUB_FROM_ENV=''

# A configured id that disagrees with a verified recorded one is a stop;
# --subscription is the deliberate override and wins (warned, never silent).
if [[ -n "$SUB_FROM_OUT" ]]; then
    if [[ -n "$SUB_OVERRIDE" && "$(lc "$SUB_OVERRIDE")" != "$SUB_FROM_OUT" ]]; then
        warn "--subscription ${SUB_OVERRIDE} differs from the deployed subscription ${SUB_FROM_OUT} (generated/outputs.json)"
        note "proceeding with the id you passed explicitly; Ctrl-C now if that is not what you meant."
    elif [[ -z "$SUB_OVERRIDE" && -n "$SUB_FROM_ENV" && "$(lc "$SUB_FROM_ENV")" != "$SUB_FROM_OUT" ]]; then
        die "generated/outputs.json was deployed in subscription ${SUB_FROM_OUT}, not AZ_SUBSCRIPTION_ID (${SUB_FROM_ENV})" \
            "reconcile them before destroying anything - refusing to delete in a subscription you did not configure.
       fix AZ_SUBSCRIPTION_ID in ${ENV_FILE}, or pass --subscription <id>."
    fi
fi

# Never the ambient default: --subscription, then the verified recorded id, then
# a configured AZ_SUBSCRIPTION_ID. If none is set we refuse.
SUBSCRIPTION="${SUB_OVERRIDE:-${SUB_FROM_OUT:-$SUB_FROM_ENV}}"
[[ -n "$SUBSCRIPTION" ]] || die "cannot establish which subscription '${RG}' lives in" \
    "the active az subscription is not trusted here. Set AZ_SUBSCRIPTION_ID in ${ENV_FILE},
       deploy so generated/outputs.json exists, or pass --subscription <id>.
       Refusing to list or delete a resource group in whichever subscription happens to be active."
# Non-empty by construction, so plain "${SUB_ARGS[@]}" is safe under set -u.
SUB_ARGS=(--subscription "$SUBSCRIPTION")

SUB_NAME="$(az account show "${SUB_ARGS[@]}" --query name -o tsv 2>/dev/null || echo '?')"

# --------------------------------------------------------------------------
# Banner
# --------------------------------------------------------------------------
printf '\n'
printf '%s%s                                                                    %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '%s%s   DESTROY - this permanently deletes an Azure resource group        %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '%s%s                                                                    %s\n' "$C_BOLD" "$C_REDBG" "$C_RESET"
printf '\n'
printf '  %-16s %s%s%s\n' "subscription" "$C_BOLD" "$SUB_NAME" "$C_RESET"
printf '  %-16s %s\n'     ""             "$C_DIM$SUBSCRIPTION$C_RESET"
printf '  %-16s %s%s%s\n' "resource group" "$C_BOLD$C_RED" "$RG" "$C_RESET"
printf '\n'

if ! az group show "${SUB_ARGS[@]}" --name "$RG" -o none 2>/dev/null; then
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
RG_LOCATION="$(az group show "${SUB_ARGS[@]}" --name "$RG" --query location -o tsv 2>/dev/null || echo "${AZ_LOCATION:-}")"
KV_NAMES=''
CS_NAMES=''
RES_COUNT=0

if az group show "${SUB_ARGS[@]}" --name "$RG" -o none 2>/dev/null; then
    printf '  %sContents:%s\n' "$C_BOLD" "$C_RESET"
    if have jq; then
        RES_JSON="$(az resource list "${SUB_ARGS[@]}" --resource-group "$RG" -o json 2>/dev/null || echo '[]')"
        RES_COUNT="$(printf '%s' "$RES_JSON" | jq 'length')"
        printf '%s' "$RES_JSON" \
        | jq -r 'group_by(.type)[] | "\(length)\t\(.[0].type)"' \
        | sort -rn \
        | while IFS=$'\t' read -r N T; do printf '    %3s x %s\n' "$N" "${T#Microsoft.}"; done
        KV_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.KeyVault/vaults")       | .name')"
        CS_NAMES="$(printf '%s' "$RES_JSON" | jq -r '.[] | select(.type=="Microsoft.CognitiveServices/accounts") | .name')"
    else
        az resource list "${SUB_ARGS[@]}" --resource-group "$RG" --query '[].{name:name,type:type}' -o tsv 2>/dev/null | sed 's/^/    /'
        RES_COUNT="$(az resource list "${SUB_ARGS[@]}" --resource-group "$RG" --query 'length(@)' -o tsv 2>/dev/null || echo 0)"
        KV_NAMES="$(az keyvault list "${SUB_ARGS[@]}" --resource-group "$RG" --query '[].name' -o tsv 2>/dev/null || true)"
        CS_NAMES="$(az cognitiveservices account list "${SUB_ARGS[@]}" --resource-group "$RG" --query '[].name' -o tsv 2>/dev/null || true)"
    fi
    printf '\n    %s%s resource(s) will be deleted. This cannot be undone.%s\n\n' "$C_BOLD" "$RES_COUNT" "$C_RESET"
fi

# --------------------------------------------------------------------------
# The conversion artefacts go with the VM
#
# The extension writes its reports, its converted DDL and -- the part you will
# want and cannot rebuild -- internal/logs/conversion.log to
# ~/.github/postgres-migrations/ on the Oracle VM. Deleting the resource group
# deletes all of it.
#
# This is not hypothetical. A run on 2026-09-04 was torn down with only three
# summary files preserved; when Microsoft asked for the conversion directory
# days later, the logs and the per-object failure reasons no longer existed
# anywhere. Nothing in this script warned about it, so nothing stopped it.
#
# Cheap to avoid: one tarball, seconds to collect.
# --------------------------------------------------------------------------
if [[ "$RES_COUNT" -gt 0 ]] && ! compgen -G "${REPO_ROOT}/out/conversion-artifacts-*.tar.gz" >/dev/null 2>&1; then
    printf '    %s%sNo conversion artefacts have been collected from this deployment.%s\n' \
        "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '    %sIf you ran a conversion, its logs and converted DDL live only on the Oracle VM\n' "$C_DIM"
    printf '    and are about to be deleted with it. To keep them:%s\n\n' "$C_RESET"
    printf '        %sscripts/collect-conversion-artifacts.sh%s\n\n' "$C_BOLD" "$C_RESET"
fi

# --------------------------------------------------------------------------
# Confirm - type the resource group name
# --------------------------------------------------------------------------
if [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "--yes given, skipping confirmation"
elif [[ "$RES_COUNT" -eq 0 ]] && ! az group show "${SUB_ARGS[@]}" --name "$RG" -o none 2>/dev/null; then
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
if az group show "${SUB_ARGS[@]}" --name "$RG" -o none 2>/dev/null; then
    START_TS="$(date +%s)"
    if [[ "$NO_WAIT" -eq 1 ]]; then
        info "deleting ${RG} (--no-wait)"
        az group delete "${SUB_ARGS[@]}" --name "$RG" --yes --no-wait \
            || die "could not start deletion of ${RG}" \
                   "check for resource locks: az lock list --resource-group '${RG}' -o table"
        ok "deletion started; it continues in Azure after this script exits"
        note "watch it with: az group show --name '${RG}' --query properties.provisioningState -o tsv"
    else
        info "deleting ${RG} - this usually takes 5-15 minutes"
        note "Bastion and the flexible servers are the slow ones. Ctrl-C stops watching, not deleting."
        az group delete "${SUB_ARGS[@]}" --name "$RG" --yes \
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
        if az keyvault show-deleted "${SUB_ARGS[@]}" --name "$KV" -o none 2>/dev/null; then
            info "purging Key Vault ${KV}"
            if az keyvault purge "${SUB_ARGS[@]}" --name "$KV" ${RG_LOCATION:+--location "$RG_LOCATION"} -o none 2>/dev/null; then
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
        if az cognitiveservices account purge "${SUB_ARGS[@]}" --name "$CS" --resource-group "$RG" \
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
# OUTPUTS_JSON was resolved up front (see "Which subscription").
if [[ -f "$OUTPUTS_JSON" ]] && [[ "$NO_WAIT" -eq 0 ]]; then
    mv "$OUTPUTS_JSON" "${OUTPUTS_JSON}.stale" 2>/dev/null \
        && note "generated/outputs.json now points at nothing; renamed to outputs.json.stale"
fi

printf '\n%s%sThe meter is off.%s No Azure resources remain in %s.\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$RG"
printf '%sYour local Docker container, ./generated and .env were not touched.%s\n' "$C_DIM" "$C_RESET"
printf 'Redeploy any time with: %sscripts/deploy.sh%s\n\n' "$C_BOLD" "$C_RESET"
