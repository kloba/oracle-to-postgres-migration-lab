#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# collect-conversion-artifacts.sh - pull the whole conversion directory off the
# Oracle VM before you tear the lab down.
#
# WHY THIS EXISTS
#
# The VS Code extension writes everything it knows to
# ~/.github/postgres-migrations/<project>/ on whichever machine ran the
# conversion: the reports, the converted DDL, deploy.sql, per-chunk reports, the
# config it used, and -- most valuable of all when something goes wrong --
# internal/logs/conversion.log, internal/logs/extraction.log and the telemetry
# .jsonl files.
#
# None of that is in this repository. docs/conversion-report/ carries three
# summary files, because the rest is 9 MB of generated SQL and 1.7 MB of
# repetitive per-object prose, and committing it to a public repo made no sense.
#
# That reasoning was fine. What was NOT fine is that the environment was then
# destroyed with `scripts/destroy.sh`, and the logs went with it. When Microsoft
# asked for the conversion directory a few days later, the only honest answer was
# that most of it no longer existed. The failure reasons we had quoted from
# customer_summary.md could not be re-derived, and the conversion.log that would
# have shown exactly where the run stalled was gone.
#
# So: run this BEFORE destroy.sh, every time. It costs seconds and one tarball.
#
#   ./scripts/collect-conversion-artifacts.sh
#   ./scripts/destroy.sh
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
    printf '\n%s%s%s failed:%s %s\n' "$C_BOLD" "$C_RED" "$SCRIPT_NAME" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# The tilde is deliberate and must survive to the remote shell: this path is
# only ever interpolated into an ssh command, where ~ is the VM's azureuser home,
# not ours. Expanding it locally with $HOME would point at the wrong machine.
# shellcheck disable=SC2088
REMOTE_DIR_DEFAULT='~/.github/postgres-migrations'
LOCAL_PORT=2222
KEEP_TUNNEL=0

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - archive the conversion directory from the Oracle VM.

    --port <n>       Local port for the Bastion tunnel. Default ${LOCAL_PORT}.
    --remote <path>  Directory to collect. Default ${REMOTE_DIR_DEFAULT}.
    -h, --help       This text.

Writes out/conversion-artifacts-<UTC timestamp>.tar.gz, which is gitignored.
Run it BEFORE scripts/destroy.sh - afterwards there is nothing to collect.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)     LOCAL_PORT="${2:-}"; [[ -n "$LOCAL_PORT" ]] || die "--port needs a value"; shift 2 ;;
        --port=*)   LOCAL_PORT="${1#*=}"; shift ;;
        --remote)   REMOTE_DIR_DEFAULT="${2:-}"; [[ -n "$REMOTE_DIR_DEFAULT" ]] || die "--remote needs a value"; shift 2 ;;
        --remote=*) REMOTE_DIR_DEFAULT="${1#*=}"; shift ;;
        --keep-tunnel) KEEP_TUNNEL=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

have az || die "az CLI not installed" "brew install azure-cli"
have jq || die "jq not installed" "brew install jq"

OUTPUTS="${REPO_ROOT}/generated/outputs.json"
[[ -f "$OUTPUTS" ]] || die "no ${OUTPUTS#"$REPO_ROOT"/}" \
    "the lab is not deployed, or destroy.sh already renamed it to outputs.json.stale"

RG="$(jq -r '.resourceGroupName // empty' "$OUTPUTS")"
BASTION="$(jq -r '.bastionName // empty' "$OUTPUTS")"
VM_ID="$(jq -r '.oracleVmId // empty' "$OUTPUTS")"
[[ -n "$RG" && -n "$BASTION" && -n "$VM_ID" ]] || die "outputs.json is missing resourceGroupName, bastionName or oracleVmId"

SSH_KEY="${REPO_ROOT}/generated/ssh/o2p-lab_ed25519"
[[ -f "$SSH_KEY" ]] || die "no SSH key at ${SSH_KEY#"$REPO_ROOT"/}"
ADMIN="$(jq -r '.oracleAdminUsername // "azureuser"' "$OUTPUTS")"

TUNNEL_PID=''
cleanup() {
    if [[ -n "$TUNNEL_PID" && "$KEEP_TUNNEL" -eq 0 ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

hdr "Bastion tunnel"
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    ok "something is already listening on ${LOCAL_PORT}; reusing it"
else
    set -m
    az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
        --target-resource-id "$VM_ID" --resource-port 22 --port "$LOCAL_PORT" \
        </dev/null >/dev/null 2>&1 &
    TUNNEL_PID=$!
    set +m
    WAITED=0
    # lsof, not /dev/tcp: zsh and bash disagree about /dev/tcp and a false
    # negative here sends you hunting a Bastion problem that does not exist.
    until lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
        sleep 1; WAITED=$(( WAITED + 1 ))
        kill -0 "$TUNNEL_PID" 2>/dev/null || die "the Bastion tunnel exited immediately" \
            "Bastion must be Standard SKU with tunneling enabled"
        [[ "$WAITED" -lt 45 ]] || die "tunnel did not open within 45s"
    done
    ok "tunnel up on 127.0.0.1:${LOCAL_PORT}"
fi

SSH_OPTS=(-i "$SSH_KEY" -p "$LOCAL_PORT" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

hdr "What is on the VM"
# shellcheck disable=SC2029  # expanding the path client-side is intended; see above
REMOTE_SIZE="$(ssh "${SSH_OPTS[@]}" "${ADMIN}@127.0.0.1" \
    "du -sh ${REMOTE_DIR_DEFAULT} 2>/dev/null | cut -f1" 2>/dev/null || true)"
[[ -n "$REMOTE_SIZE" ]] || die "nothing at ${REMOTE_DIR_DEFAULT} on the VM" \
    "the conversion writes there only after you create a migration project in VS Code"
info "${REMOTE_DIR_DEFAULT} is ${REMOTE_SIZE}"
# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "${ADMIN}@127.0.0.1" \
    "find ${REMOTE_DIR_DEFAULT} -maxdepth 2 -mindepth 1 -type d -printf '  %p\n' 2>/dev/null | head -10" || true

mkdir -p "${REPO_ROOT}/out"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${REPO_ROOT}/out/conversion-artifacts-${STAMP}.tar.gz"

hdr "Collecting"
info "streaming a tarball over the tunnel; this is the whole directory, nothing filtered"
# shellcheck disable=SC2029
ssh "${SSH_OPTS[@]}" "${ADMIN}@127.0.0.1" \
    "tar -czf - -C \$(dirname ${REMOTE_DIR_DEFAULT}) \$(basename ${REMOTE_DIR_DEFAULT})" > "$ARCHIVE" \
    || die "the transfer failed" "check the tunnel and re-run"

[[ -s "$ARCHIVE" ]] || die "the archive is empty"
SIZE="$(du -h "$ARCHIVE" | cut -f1 | tr -d ' ')"
COUNT="$(tar -tzf "$ARCHIVE" | wc -l | tr -d ' ')"
ok "${ARCHIVE#"$REPO_ROOT"/} - ${SIZE}, ${COUNT} entries"

hdr "The files that matter when something went wrong"
for WANT in 'internal/logs/conversion.log' 'internal/logs/extraction.log' \
            'reports/customer_summary.md' 'reports/technical_conversion_report.md' \
            'deploy.sql' 'config/'; do
    if tar -tzf "$ARCHIVE" | grep -q -- "$WANT"; then
        ok "$WANT"
    else
        warn "$WANT not present"
    fi
done

printf '\n%s%sCollected.%s You can tear down now:  %sscripts/destroy.sh%s\n' \
    "$C_BOLD" "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
printf '%sout/ is gitignored. Review the archive before sharing it - the config directory\n' "$C_DIM"
printf 'records hostnames, and llm.yaml records your Foundry endpoint.%s\n\n' "$C_RESET"
