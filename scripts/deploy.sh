#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# deploy.sh - stand up the Azure side of the Contoso Store migration lab.
#
#   .env  ->  preflight  ->  SSH key  ->  cloud-init (base64, password
#   templated in)  ->  az deployment sub create  ->  generated/outputs.json
#
# The deployment is subscription-scoped so the template can create the
# resource group itself; if infra/ turns out to be a resource-group-scoped
# template this script detects that and falls back to `az deployment group
# create` after creating the group.
#
# Nothing secret is ever written to generated/outputs.json, echoed to the
# terminal, or passed on an `az` command line where `ps` could read it.
# Secrets go into a 0600 parameters file in a private temp directory that is
# removed on exit, including on failure.
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
    printf '\n%s%sdeploy failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
WHAT_IF=0
REGION_OVERRIDE=''
SKIP_PREFLIGHT=0
ASSUME_YES=0
DEPLOY_NAME=''
TEMPLATE_OVERRIDE=''

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - deploy the Azure resources for the migration lab.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} [options]

${C_BOLD}OPTIONS${C_RESET}
    --what-if          Preview the change with 'az deployment sub what-if'.
                       Creates nothing and costs nothing. Always do this first.
    --region <name>    Deploy to this region instead of AZ_LOCATION.
    --name <name>      Deployment name. Default: <prefix>-deploy-<timestamp>.
    --template <path>  Bicep or ARM template to deploy.
                       Default: the first of infra/main.bicep, infra/main.json.
    --skip-preflight   Do not run scripts/preflight.sh first. You are on your
                       own; most deployment failures are preflight failures
                       that surfaced twenty minutes late.
    -y, --yes          Do not ask for confirmation before deploying.
    -h, --help         Show this help and exit.

${C_BOLD}OUTPUT${C_RESET}
    On success, prints a connection table and writes every non-secret template
    output to ${C_DIM}generated/outputs.json${C_RESET}. connect.sh, status.sh and
    seed-oracle.sh --azure all read that file.

${C_BOLD}COST${C_RESET}
    This script creates billable resources. When you are done for the day:
        ${C_BOLD}scripts/destroy.sh${C_RESET}
    Check what is running and roughly what it costs with scripts/status.sh.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --what-if)        WHAT_IF=1; shift ;;
        --region)         REGION_OVERRIDE="${2:-}"; [[ -n "$REGION_OVERRIDE" ]] || die "--region needs a value"; shift 2 ;;
        --region=*)       REGION_OVERRIDE="${1#*=}"; shift ;;
        --name)           DEPLOY_NAME="${2:-}"; [[ -n "$DEPLOY_NAME" ]] || die "--name needs a value"; shift 2 ;;
        --name=*)         DEPLOY_NAME="${1#*=}"; shift ;;
        --template)       TEMPLATE_OVERRIDE="${2:-}"; [[ -n "$TEMPLATE_OVERRIDE" ]] || die "--template needs a value"; shift 2 ;;
        --template=*)     TEMPLATE_OVERRIDE="${1#*=}"; shift ;;
        --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
[[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}" \
    "cp '${REPO_ROOT}/.env.example' '${ENV_FILE}' && chmod 600 '${ENV_FILE}' && \$EDITOR '${ENV_FILE}'"

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

have az || die "az CLI not installed" "brew install azure-cli   # or https://aka.ms/azure-cli"

REGION="${REGION_OVERRIDE:-${AZ_LOCATION:-}}"
[[ -n "$REGION" ]] || die "no region: AZ_LOCATION is empty and --region was not given" \
    "set AZ_LOCATION in ${ENV_FILE}, or pass --region swedencentral"

PREFIX="${AZ_PREFIX:-o2p}"
RG="${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}"
GEN_DIR="${REPO_ROOT}/generated"
OUTPUTS_JSON="${GEN_DIR}/outputs.json"
[[ -n "$DEPLOY_NAME" ]] || DEPLOY_NAME="${PREFIX}-deploy-$(date -u +%Y%m%d-%H%M%S)"

# --------------------------------------------------------------------------
# Locate the template
# --------------------------------------------------------------------------
TEMPLATE=''
if [[ -n "$TEMPLATE_OVERRIDE" ]]; then
    TEMPLATE="$TEMPLATE_OVERRIDE"
    [[ -f "$TEMPLATE" ]] || die "template not found: ${TEMPLATE}"
else
    for CANDIDATE in "${REPO_ROOT}/infra/main.bicep" "${REPO_ROOT}/infra/main.json" \
                     "${REPO_ROOT}/infra/azuredeploy.bicep" "${REPO_ROOT}/infra/azuredeploy.json"; do
        if [[ -f "$CANDIDATE" ]]; then TEMPLATE="$CANDIDATE"; break; fi
    done
    [[ -n "$TEMPLATE" ]] || die "no template found in ${REPO_ROOT}/infra" \
        "infra/ is owned by the Bicep author; expected infra/main.bicep. Pass --template <path> to override."
fi

hdr "Contoso Store migration lab - deploy"
printf '  %-22s %s\n' "template"        "${TEMPLATE#"$REPO_ROOT"/}"
printf '  %-22s %s\n' "region"          "$REGION"
printf '  %-22s %s\n' "resource group"  "$RG"
printf '  %-22s %s\n' "deployment name" "$DEPLOY_NAME"
printf '  %-22s %s\n' "mode"            "$( [[ "$WHAT_IF" -eq 1 ]] && echo 'what-if (no changes)' || echo 'CREATE - this costs money' )"

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
if [[ "$SKIP_PREFLIGHT" -eq 1 ]]; then
    hdr "Preflight"
    warn "skipped (--skip-preflight)"
else
    hdr "Preflight"
    PF_ARGS=(--region "$REGION" --skip-docker)
    if ! "${SCRIPT_DIR}/preflight.sh" "${PF_ARGS[@]}"; then
        die "preflight failed - see the list above" \
            "fix each item, then re-run ${SCRIPT_NAME}. Nothing has been deployed."
    fi
fi

# --------------------------------------------------------------------------
# SSH key
# --------------------------------------------------------------------------
hdr "SSH key"
SSH_KEY="${SSH_KEY_PATH:-${GEN_DIR}/ssh/${PREFIX}-lab_ed25519}"
SSH_PUB="${SSH_KEY}.pub"

if [[ -f "$SSH_PUB" ]]; then
    ok "using existing key ${SSH_PUB#"$REPO_ROOT"/}"
else
    have ssh-keygen || die "ssh-keygen not installed" "install openssh"
    mkdir -p "$(dirname "$SSH_KEY")"
    chmod 700 "$(dirname "$SSH_KEY")"
    info "generating ed25519 key pair (no passphrase - this is a throwaway lab key)"
    ssh-keygen -t ed25519 -N '' -C "${PREFIX}-migration-lab" -f "$SSH_KEY" >/dev/null 2>&1 \
        || die "ssh-keygen failed" "check you can write to $(dirname "$SSH_KEY")"
    chmod 600 "$SSH_KEY"
    ok "created ${SSH_PUB#"$REPO_ROOT"/}"
    note "generated/ is gitignored; this key never reaches the public repo"
fi
SSH_PUB_KEY="$(cat "$SSH_PUB")"

# --------------------------------------------------------------------------
# Secrets: from .env, or from Key Vault when USE_KEYVAULT=1
# --------------------------------------------------------------------------
# kv_or_env <env-var-name> <keyvault-secret-var-name>
kv_or_env() {
    local var="$1" kvvar="$2" value kvname secret
    eval "value=\${${var}:-}"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
    if [[ "${USE_KEYVAULT:-0}" != "1" ]]; then return 0; fi
    eval "secret=\${${kvvar}:-}"
    kvname="${AZ_KEYVAULT_NAME:-}"
    [[ -n "$kvname" && -n "$secret" ]] || return 0
    az keyvault secret show --vault-name "$kvname" --name "$secret" --query value -o tsv 2>/dev/null || true
}

ORACLE_SYSTEM_PW="$(kv_or_env ORACLE_SYSTEM_PASSWORD    KV_SECRET_ORACLE_SYSTEM_PASSWORD)"
CONTOSO_PW="$(kv_or_env       CONTOSO_PASSWORD          KV_SECRET_CONTOSO_PASSWORD)"
ORACLE_READER_PW="$(kv_or_env ORACLE_MIGRATION_PASSWORD KV_SECRET_ORACLE_MIGRATION_PASSWORD)"
PG_PW="$(kv_or_env            PGPASSWORD                KV_SECRET_PG_PASSWORD)"
SCRATCH_PG_PW="$(kv_or_env    SCRATCH_PGPASSWORD        KV_SECRET_SCRATCH_PG_PASSWORD)"
JUMPBOX_PW="$(kv_or_env       JUMPBOX_ADMIN_PASSWORD    KV_SECRET_JUMPBOX_ADMIN_PASSWORD)"

[[ -n "$ORACLE_SYSTEM_PW" ]] || die "no Oracle SYSTEM password" \
    "set ORACLE_SYSTEM_PASSWORD in ${ENV_FILE}, or USE_KEYVAULT=1 with the secret in ${AZ_KEYVAULT_NAME:-your vault}"
[[ -n "$CONTOSO_PW" ]] || die "no CONTOSO schema password" \
    "set CONTOSO_PASSWORD in ${ENV_FILE}, or USE_KEYVAULT=1 with the secret in ${AZ_KEYVAULT_NAME:-your vault}"

# --------------------------------------------------------------------------
# cloud-init: template the passwords in, then base64
# --------------------------------------------------------------------------
hdr "cloud-init"
CLOUD_INIT=''
# scripts/cloud-init/oracle-vm.yaml is the real document; the rest are names
# earlier drafts of the layout used and are kept so an older checkout still
# deploys. Order matters: first match wins.
for CANDIDATE in "${REPO_ROOT}/scripts/cloud-init/oracle-vm.yaml" \
                 "${REPO_ROOT}/scripts/cloud-init-oracle.yaml" "${REPO_ROOT}/scripts/cloud-init/oracle.yaml" \
                 "${REPO_ROOT}/infra/cloud-init-oracle.yaml"   "${REPO_ROOT}/infra/cloud-init-oracle.yml" \
                 "${REPO_ROOT}/infra/cloud-init.yaml"          "${REPO_ROOT}/infra/cloud-init.yml"; do
    if [[ -f "$CANDIDATE" ]]; then CLOUD_INIT="$CANDIDATE"; break; fi
done

CLOUD_INIT_B64=''
if [[ -z "$CLOUD_INIT" ]]; then
    warn "no cloud-init file found - the VM will come up bare and Oracle must be installed by hand"
    note "looked for: scripts/cloud-init/oracle-vm.yaml, scripts/cloud-init-oracle.yaml, infra/cloud-init*.yaml"
else
    CI_BODY="$(cat "$CLOUD_INIT")"
    # Pure-bash substitution. The passwords never touch a temp file, a command
    # line, or sed (where '&' and '/' in a password would corrupt the output).
    CI_BODY="${CI_BODY//__ORACLE_SYSTEM_PASSWORD__/$ORACLE_SYSTEM_PW}"
    CI_BODY="${CI_BODY//__ORACLE_PASSWORD__/$ORACLE_SYSTEM_PW}"
    CI_BODY="${CI_BODY//__CONTOSO_PASSWORD__/$CONTOSO_PW}"
    CI_BODY="${CI_BODY//__ORACLE_MIGRATION_PASSWORD__/$ORACLE_READER_PW}"
    CI_BODY="${CI_BODY//__ORACLE_IMAGE__/${ORACLE_IMAGE:-container-registry.oracle.com/database/free:latest}}"
    CI_BODY="${CI_BODY//__ORACLE_CONTAINER_NAME__/${ORACLE_CONTAINER_NAME:-o2p-oracle}}"
    CI_BODY="${CI_BODY//__ORACLE_SERVICE__/${ORACLE_SERVICE:-FREEPDB1}}"
    CI_BODY="${CI_BODY//__ORACLE_PORT__/${ORACLE_PORT:-1521}}"
    CI_BODY="${CI_BODY//__CONTOSO_SCHEMA__/${CONTOSO_SCHEMA:-CONTOSO}}"
    CI_BODY="${CI_BODY//__ORACLE_MIGRATION_USER__/${ORACLE_MIGRATION_USER:-O2P_READER}}"
    CI_BODY="${CI_BODY//__SSH_PUBLIC_KEY__/$SSH_PUB_KEY}"

    if printf '%s' "$CI_BODY" | grep -q '__[A-Z_]\{3,\}__'; then
        warn "cloud-init still contains unsubstituted __TOKENS__:"
        printf '%s' "$CI_BODY" | grep -o '__[A-Z_]\{3,\}__' | sort -u | sed 's/^/           /'
        note "deploy.sh substitutes the token names listed in its source; ask the infra author to align"
    fi

    # GNU base64 wraps at 76 columns, BSD base64 does not. tr makes both agree.
    #
    # Azure caps osProfile.customData at 87380 base64 characters, and this
    # cloud-init is well past that uncompressed - it carries the whole of
    # install-oracle.sh inline. cloud-init sniffs the gzip magic bytes and
    # inflates user-data itself, so gzip-then-base64 is the documented way out
    # and costs nothing on the VM side. Roughly a 5x reduction here.
    CLOUD_INIT_B64="$(printf '%s\n' "$CI_BODY" | gzip -9 -n | base64 | tr -d '\n')"
    CI_RAW_LEN="$(printf '%s\n' "$CI_BODY" | base64 | tr -d '\n' | wc -c | tr -d ' ')"

    # Fail here, with the real numbers, rather than 8 minutes into a deployment
    # with ARM's "InvalidParameter ... maximum length of 87380 characters".
    CI_MAX=87380
    if [[ "${#CLOUD_INIT_B64}" -gt "$CI_MAX" ]]; then
        die "cloud-init is ${#CLOUD_INIT_B64} base64 chars even gzipped; Azure allows ${CI_MAX}" \
            "trim ${CLOUD_INIT#"$REPO_ROOT"/}, or have it curl install-oracle.sh from the repo at
       first boot instead of carrying it inline."
    fi
    ok "${CLOUD_INIT#"$REPO_ROOT"/} rendered, gzipped and base64-encoded"
    note "${CI_RAW_LEN} chars raw -> ${#CLOUD_INIT_B64} gzipped (Azure limit ${CI_MAX})"
fi

# --------------------------------------------------------------------------
# Work out which parameters the template actually declares.
#
# This is deliberately defensive: infra/ is written by a different author and
# `az deployment` fails hard on an unexpected parameter. We send only what the
# template asks for, and we say so plainly when it asks for something we have
# no value for.
# --------------------------------------------------------------------------
hdr "Template parameters"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/o2p-deploy.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

COMPILED="${TMP_DIR}/template.json"
case "$TEMPLATE" in
    *.bicep)
        az bicep build --file "$TEMPLATE" --outfile "$COMPILED" >/dev/null 2>&1 \
            || die "bicep build failed for ${TEMPLATE}" \
                   "az bicep build --file '${TEMPLATE}'   # to see the compiler errors" ;;
    *) cp "$TEMPLATE" "$COMPILED" ;;
esac

DECLARED=''
REQUIRED=''
SCOPE='subscription'
have jq || die "jq is required to deploy" \
    "brew install jq

  deploy.sh reads the template's own parameter list and sends only the
  parameters it declares - it offers several alternative names for the same
  concept (resourceGroupName / rgName, prefix / namePrefix / resourcePrefix).
  Without jq it cannot tell which the template wants and would send all of
  them, which ARM rejects."
DECLARED="$(jq -r '.parameters // {} | keys[]' "$COMPILED" 2>/dev/null || true)"
REQUIRED="$(jq -r '.parameters // {} | to_entries[] | select(.value | has("defaultValue") | not) | .key' "$COMPILED" 2>/dev/null || true)"
if ! jq -r '."$schema"' "$COMPILED" 2>/dev/null | grep -qi 'subscriptionDeploymentTemplate'; then
    SCOPE='group'
fi
ok "template scope: ${SCOPE}"

declares() { printf '%s\n' "$DECLARED" | grep -qx "$1"; }

# Assemble the parameters object. Values are written to a 0600 file rather
# than passed as `--parameters key=value`, so no password appears in `ps`.
PARAM_FILE="${TMP_DIR}/params.json"
( umask 077; : > "$PARAM_FILE" )

PARAM_BODY=''
SENT_NAMES=''
# add_param <name> <json-encoded-value> <is-secret>
add_param() {
    local name="$1" json="$2" secret="${3:-0}"
    declares "$name" || return 0
    [[ -n "$PARAM_BODY" ]] && PARAM_BODY="${PARAM_BODY},"
    PARAM_BODY="${PARAM_BODY}\"${name}\":{\"value\":${json}}"
    SENT_NAMES="${SENT_NAMES}${name} "
    if [[ "$secret" == "1" ]]; then
        printf '  %-28s %s<redacted>%s\n' "$name" "$C_DIM" "$C_RESET"
    fi
}
# jstr <text> - JSON-encode a string
jstr() { jq -Rn --arg v "$1" '$v'; }

add_param location                      "$(jstr "$REGION")"
add_param resourceGroupName             "$(jstr "$RG")"
add_param namePrefix                    "$(jstr "$PREFIX")"
add_param oracleVmSize                  "$(jstr "${ORACLE_VM_SIZE:-Standard_D4s_v5}")"
add_param oracleAdminUsername           "$(jstr "${ORACLE_VM_ADMIN_USER:-azureuser}")"
add_param oracleSshPublicKey            "$(jstr "$SSH_PUB_KEY")"
add_param postgresDatabaseName          "$(jstr "${PGDATABASE:-contoso_store}")"
add_param postgresScratchDatabaseName   "$(jstr "${SCRATCH_PGDATABASE:-migration_scratch}")"
add_param postgresAdministratorLogin    "$(jstr "${PGUSER:-o2padmin}")"
# SkuNotAvailable is the most common regional deploy failure and the fix is to
# pick a different SKU, so the SKU has to be reachable from .env rather than
# only from infra/main.bicep. Empty means "use the template default".
[[ -n "${PG_SKU_NAME:-}" ]] && add_param postgresSkuName "$(jstr "$PG_SKU_NAME")"
[[ -n "${PG_SKU_TIER:-}" ]] && add_param postgresSkuTier "$(jstr "$PG_SKU_TIER")"
add_param foundryDeploymentName         "$(jstr "${FOUNDRY_DEPLOYMENT_NAME:-${PREFIX}-schema-conversion}")"
add_param foundryModelName              "$(jstr "${FOUNDRY_MODEL_NAME:-gpt-5.2}")"
add_param foundryModelVersion           "$(jstr "${FOUNDRY_MODEL_VERSION:-}")"
add_param foundryModelCapacity          "$(( ${FOUNDRY_TPM_QUOTA:-500000} / 1000 ))"
add_param jumpboxVmSize                 "$(jstr "${JUMPBOX_VM_SIZE:-Standard_D4s_v5}")"
add_param jumpboxAdminUsername          "$(jstr "${JUMPBOX_ADMIN_USER:-o2padmin}")"
# Bastion must be Standard: the Basic SKU rejects enableTunneling, and
# `az network bastion tunnel` is how connect.sh and seed-oracle.sh --azure
# reach the Oracle VM and the VNet-private PostgreSQL server. infra/main.bicep
# defaults this to Basic, which would leave both unusable.
add_param bastionSkuName                "$(jstr "${AZ_BASTION_SKU:-Standard}")"
[[ -n "$CLOUD_INIT_B64" ]] && add_param oracleCloudInitBase64 "$(jstr "$CLOUD_INIT_B64")"
add_param postgresAdministratorPassword "$(jstr "${PG_PW:-$CONTOSO_PW}")"      1
add_param jumpboxAdminPassword          "$(jstr "${JUMPBOX_PW:-$CONTOSO_PW}")" 1
add_param oracleSystemPassword          "$(jstr "$ORACLE_SYSTEM_PW")"          1
add_param contosoPassword               "$(jstr "$CONTOSO_PW")"                1
add_param scratchAdminPassword          "$(jstr "${SCRATCH_PG_PW:-$CONTOSO_PW}")" 1

# shellcheck disable=SC2016  # $schema is a literal JSON key, not a shell variable
printf '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#","contentVersion":"1.0.0.0","parameters":{%s}}\n' \
    "$PARAM_BODY" > "$PARAM_FILE"
chmod 600 "$PARAM_FILE"

if [[ -n "$SENT_NAMES" ]]; then
    ok "sending $(printf '%s' "$SENT_NAMES" | wc -w | tr -d ' ') parameter(s)"
    note "$(printf '%s' "$SENT_NAMES" | tr ' ' '\n' | grep -v '^$' | grep -iv 'password' | tr '\n' ' ')"
fi

# Anything the template requires that we did not supply is a contract break.
MISSING=''
if [[ -n "$REQUIRED" ]]; then
    for P in $REQUIRED; do
        printf '%s ' "$SENT_NAMES" | grep -qw "$P" || MISSING="${MISSING} ${P}"
    done
fi
if [[ -n "$MISSING" ]]; then
    die "${TEMPLATE#"$REPO_ROOT"/} requires parameter(s) deploy.sh does not supply:${MISSING}" \
        "either give them a defaultValue in the template, or tell the scripts author to add them to add_param in ${SCRIPT_NAME}"
fi

# --------------------------------------------------------------------------
# what-if
# --------------------------------------------------------------------------
if [[ "$WHAT_IF" -eq 1 ]]; then
    hdr "What-if (nothing will be created)"
    if [[ "$SCOPE" == "subscription" ]]; then
        az deployment sub what-if --name "$DEPLOY_NAME" --location "$REGION" \
            --template-file "$TEMPLATE" --parameters "@${PARAM_FILE}" \
            || die "what-if failed" "run with --debug for the ARM error, or check the template compiles: az bicep build --file '${TEMPLATE}'"
    else
        az group show --name "$RG" >/dev/null 2>&1 \
            || die "what-if at group scope needs the resource group to exist" "az group create --name '${RG}' --location '${REGION}'"
        az deployment group what-if --name "$DEPLOY_NAME" --resource-group "$RG" \
            --template-file "$TEMPLATE" --parameters "@${PARAM_FILE}" \
            || die "what-if failed" "run with --debug for the ARM error"
    fi
    printf '\n%s%sWhat-if complete. Nothing was created.%s Re-run without --what-if to deploy.\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET"
    exit 0
fi

# --------------------------------------------------------------------------
# Confirm
# --------------------------------------------------------------------------
if [[ "$ASSUME_YES" -eq 0 ]]; then
    printf '\n  %s%sThis creates billable Azure resources in %s.%s\n' "$C_BOLD" "$C_YELLOW" "$REGION" "$C_RESET"
    printf '  %sRun scripts/destroy.sh when you are done for the day.%s\n' "$C_DIM" "$C_RESET"
    # -r /dev/tty only tests the permission bits. In a CI runner, a detached
    # background job or a container without a controlling terminal the node is
    # present and readable but open() still fails with ENXIO ("Device not
    # configured"), so the -r test passes and the read then dies. Test whether
    # the device actually opens instead.
    if { exec 3</dev/tty; } 2>/dev/null; then
        printf '\n  Continue? [y/N] '
        ANS=''
        read -r ANS <&3 || true
        exec 3<&-
        case "$ANS" in y|Y|yes|YES) : ;; *) printf '\n  aborted, nothing deployed.\n'; exit 0 ;; esac
    else
        die "no usable terminal to confirm on, and --yes was not given" \
            "re-run with --yes for unattended deployment. It creates billable resources
       immediately, so pair it with scripts/destroy.sh in the same job."
    fi
fi

# --------------------------------------------------------------------------
# Deploy, streaming operation progress
# --------------------------------------------------------------------------
hdr "Deploying"
info "starting ${DEPLOY_NAME}"
note "Ctrl-C stops watching; the deployment keeps running in Azure."

if [[ "$SCOPE" == "subscription" ]]; then
    az deployment sub create --name "$DEPLOY_NAME" --location "$REGION" \
        --template-file "$TEMPLATE" --parameters "@${PARAM_FILE}" --no-wait \
        || die "could not start the deployment" \
               "re-run with --what-if first; if that passes, add --debug to see the ARM rejection"
    OP_LIST=(az deployment operation sub list --name "$DEPLOY_NAME")
    SHOW=(az deployment sub show --name "$DEPLOY_NAME")
else
    info "resource-group-scoped template; ensuring ${RG} exists"
    az group create --name "$RG" --location "$REGION" --output none \
        || die "could not create resource group ${RG}" "check you have Contributor on the subscription"
    az deployment group create --name "$DEPLOY_NAME" --resource-group "$RG" \
        --template-file "$TEMPLATE" --parameters "@${PARAM_FILE}" --no-wait \
        || die "could not start the deployment" "re-run with --what-if first, then add --debug"
    OP_LIST=(az deployment operation group list --name "$DEPLOY_NAME" --resource-group "$RG")
    SHOW=(az deployment group show --name "$DEPLOY_NAME" --resource-group "$RG")
fi

SEEN="${TMP_DIR}/seen"
: > "$SEEN"
START_TS="$(date +%s)"
STATE='Running'

while :; do
    OPS="$("${OP_LIST[@]}" -o json 2>/dev/null || echo '[]')"
    printf '%s' "$OPS" | jq -r '
        .[] | select(.properties.targetResource.resourceType != null)
        | "\(.properties.provisioningState)\t\(.properties.targetResource.resourceType)\t\(.properties.targetResource.resourceName // "-")"
    ' 2>/dev/null | sort -u | while IFS=$'\t' read -r PSTATE PTYPE PNAME; do
        KEY="${PSTATE}|${PTYPE}|${PNAME}"
        grep -qxF "$KEY" "$SEEN" 2>/dev/null && continue
        printf '%s\n' "$KEY" >> "$SEEN"
        case "$PSTATE" in
            Succeeded) printf '  %s[ ok ]%s %-52s %s\n' "$C_GREEN"  "$C_RESET" "${PTYPE#Microsoft.}" "$PNAME" ;;
            Failed)    printf '  %s[FAIL]%s %-52s %s\n' "$C_RED"    "$C_RESET" "${PTYPE#Microsoft.}" "$PNAME" ;;
            Running|Accepted|Creating)
                       printf '  %s[ .. ]%s %-52s %s\n' "$C_CYAN"   "$C_RESET" "${PTYPE#Microsoft.}" "$PNAME" ;;
            *)         printf '  %s[%4s]%s %-52s %s\n' "$C_YELLOW" "$PSTATE" "$C_RESET" "${PTYPE#Microsoft.}" "$PNAME" ;;
        esac
    done

    STATE="$("${SHOW[@]}" --query properties.provisioningState -o tsv 2>/dev/null || echo 'Running')"
    case "$STATE" in
        Succeeded|Failed|Canceled) break ;;
    esac
    sleep 10
done

ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n  elapsed: %dm %02ds\n' "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"

if [[ "$STATE" != "Succeeded" ]]; then
    printf '\n'
    "${OP_LIST[@]}" -o json 2>/dev/null \
    | jq -r '.[] | select(.properties.provisioningState=="Failed")
             | "  \(.properties.targetResource.resourceName // "-"): \(.properties.statusMessage.error.message // .properties.statusMessage // "no message")"' \
    2>/dev/null | head -20 || true
    die "deployment ${DEPLOY_NAME} finished as ${STATE}" \
        "read the errors above. Partially created resources are still billable - run scripts/destroy.sh to clean up."
fi

# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------
hdr "Connection details"
mkdir -p "$GEN_DIR"

RAW_OUT="$("${SHOW[@]}" --query properties.outputs -o json 2>/dev/null || echo '{}')"

# Flatten {"k":{"type":..,"value":..}} to {"k":value} and drop anything whose
# name smells like a credential. generated/ is gitignored, but a public repo
# earns two locks on that door.
printf '%s' "$RAW_OUT" | jq --sort-keys '
    to_entries
    | map(select(.key | test("password|secret|connectionstring|primarykey|accountkey"; "i") | not))
    | map({key: .key, value: (.value.value // .value)})
    | from_entries
' > "${OUTPUTS_JSON}.tmp" && mv "${OUTPUTS_JSON}.tmp" "$OUTPUTS_JSON"
chmod 600 "$OUTPUTS_JSON"

printf '  %s%-30s %s%s\n' "$C_BOLD" "SETTING" "VALUE" "$C_RESET"
printf '  %s\n' "------------------------------ --------------------------------------------------"
printf '  %-30s %s\n' "resourceGroup" "$RG"
printf '  %-30s %s\n' "location"      "$REGION"
jq -r 'to_entries[] | "\(.key)\t\(.value|tostring)"' "$OUTPUTS_JSON" 2>/dev/null \
| while IFS=$'\t' read -r K V; do printf '  %-30s %s\n' "$K" "$V"; done
printf '  %-30s %s\n' "sshPrivateKey" "${SSH_KEY#"$REPO_ROOT"/}"

printf '\n%s%sDeployment succeeded.%s Written to %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "${OUTPUTS_JSON#"$REPO_ROOT"/}"
cat <<EOF

  ${C_BOLD}Next${C_RESET}
    scripts/status.sh                  what is running and roughly what it costs
    scripts/seed-oracle.sh --azure     load CONTOSO into the Oracle VM
    scripts/connect.sh oracle-azure    a SQL*Plus session through the Bastion tunnel
    scripts/connect.sh postgres        psql against the target flexible server

  ${C_BOLD}${C_YELLOW}When you are done for the day: scripts/destroy.sh${C_RESET}
EOF
