#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# connect.sh - open an interactive session against one of the lab's databases.
#
#   oracle-local   SQL*Plus inside the local Docker container
#   oracle-azure   SQL*Plus on the Oracle VM, over an az network bastion tunnel
#   postgres       psql against the Azure Database for PostgreSQL target
#   scratch        psql against the migration_scratch database (same server as the target)
#
# For the Azure targets the Bastion tunnel is opened, used, and torn down
# automatically. --tunnel-only holds the tunnel open without starting a client,
# which is what you want when connecting from VS Code, SQL Developer, or the
# PostgreSQL extension's conversion wizard.
#
# Passwords come from .env or Key Vault and are passed by stdin (SQL*Plus
# /nolog) or by environment (PGPASSWORD) - never on a command line.
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
    printf '\n%s%sconnect failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
TARGET=''
AS_SYSTEM=0
AS_READER=0
SHELL_MODE=0
TUNNEL_ONLY=0
DIRECT=0
PORT_OVERRIDE=''
SQL_COMMAND=''

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - open a session against one of the lab's databases.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} <target> [options]

${C_BOLD}TARGETS${C_RESET}
    oracle-local     SQL*Plus in the local Docker container, as ${C_BOLD}CONTOSO${C_RESET}.
    oracle-azure     SQL*Plus on the Azure Oracle VM, through a Bastion tunnel.
    postgres         psql against the target flexible server (\$PGHOST).
    scratch          psql against migration_scratch - a second database on the
                     target's own flexible server, reusing its admin credentials.

    Aliases: ${C_DIM}local, oracle, azure, pg, target${C_RESET}

${C_BOLD}OPTIONS${C_RESET}
    --system         Connect to Oracle as \$ORACLE_SYSTEM_USER instead of CONTOSO.
    --reader         Connect to Oracle as \$ORACLE_MIGRATION_USER (O2P_READER) -
                     the low-privilege account the converter itself uses. Use
                     this to reproduce a permissions problem the tool hits.
    --shell          For oracle-azure: an SSH shell on the VM instead of SQL*Plus.
    --tunnel-only    Open the tunnel, print the local port, and hold it until
                     Ctrl-C. Start no client. This is what VS Code, SQL
                     Developer and the pgsql extension need.
    --direct         For postgres/scratch: connect straight to \$PGHOST instead
                     of tunnelling. Only works if you have enabled public
                     network access on the flexible server yourself.
    --port <n>       Local port for the tunnel. Default: first free from 22022
                     (SSH) or 15432 (PostgreSQL).
    -c, --command <sql>
                     Run one statement non-interactively and exit. Useful in
                     scripts:  ${SCRIPT_NAME} oracle-local -c 'SELECT COUNT(*) FROM user_objects;'
    -h, --help       Show this help and exit.

${C_BOLD}HOW THE AZURE TARGETS ARE REACHED${C_RESET}
    The Oracle VM and the PostgreSQL server are both private - the server has
    a delegated subnet and a private DNS zone, so its FQDN only resolves inside
    the VNet. Everything therefore goes through Bastion:

      oracle-azure   laptop -> bastion tunnel -> Oracle VM:22 -> sqlplus in the container
      postgres       laptop -> bastion tunnel -> Oracle VM:22 -> ssh -L -> pg:5432

    Bastion must be the ${C_BOLD}Standard${C_RESET} SKU with native tunneling enabled. The Basic
    SKU rejects it, and scripts/deploy.sh passes Standard for that reason.

${C_BOLD}EXAMPLES${C_RESET}
    ${SCRIPT_NAME} oracle-local
    ${SCRIPT_NAME} oracle-local --reader -c 'SELECT COUNT(*) FROM user_objects;'
    ${SCRIPT_NAME} oracle-azure --shell
    ${SCRIPT_NAME} postgres
    ${SCRIPT_NAME} postgres --tunnel-only --port 15432    ${C_DIM}# then point VS Code at localhost:15432${C_RESET}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        oracle-local|local)   TARGET='oracle-local'; shift ;;
        oracle-azure|azure|oracle) TARGET='oracle-azure'; shift ;;
        postgres|pg|target)   TARGET='postgres'; shift ;;
        scratch)              TARGET='scratch'; shift ;;
        --system)             AS_SYSTEM=1; shift ;;
        --reader)             AS_READER=1; shift ;;
        --shell)              SHELL_MODE=1; shift ;;
        --tunnel-only)        TUNNEL_ONLY=1; shift ;;
        --direct)             DIRECT=1; shift ;;
        --port)               PORT_OVERRIDE="${2:-}"; [[ -n "$PORT_OVERRIDE" ]] || die "--port needs a value"; shift 2 ;;
        --port=*)             PORT_OVERRIDE="${1#*=}"; shift ;;
        -c|--command)         SQL_COMMAND="${2:-}"; [[ -n "$SQL_COMMAND" ]] || die "--command needs a value"; shift 2 ;;
        --command=*)          SQL_COMMAND="${1#*=}"; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) printf '%sunknown target or option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    printf '%serror: name a target%s\n\n' "$C_RED" "$C_RESET" >&2
    usage >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
[[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}" \
    "cp '${REPO_ROOT}/.env.example' '${ENV_FILE}' && chmod 600 '${ENV_FILE}'"
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

ORACLE_SERVICE="${ORACLE_SERVICE:-FREEPDB1}"
# Every sqlplus in this script runs INSIDE the Oracle container - `docker exec`
# locally, and `ssh ... docker exec` on the VM - so the listener it reaches is
# the container's own 1521, never the host-published port. install-oracle.sh
# and scripts/cloud-init/oracle-vm.yaml both publish `-p "${ORACLE_PORT}:1521"`,
# so ORACLE_PORT describes the HOST mapping only and is deliberately not read
# here. seed-oracle.sh hit this for real: ORACLE_PORT=1523 - the obvious way to
# dodge a clash with a local lab container - failed on the very first file with
# ORA-12541 "no listener". It carries the same note; do not "fix" this back.
ORACLE_TARGET_PORT='1521'
CONTOSO_SCHEMA="${CONTOSO_SCHEMA:-CONTOSO}"
CONTAINER="${ORACLE_CONTAINER_NAME:-o2p-oracle}"
PREFIX="${AZ_PREFIX:-o2p}"

kv_or_env() {
    local var="$1" kvvar="$2" value secret
    eval "value=\${${var}:-}"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
    [[ "${USE_KEYVAULT:-0}" == "1" ]] || return 0
    eval "secret=\${${kvvar}:-}"
    [[ -n "${AZ_KEYVAULT_NAME:-}" && -n "$secret" ]] || return 0
    az keyvault secret show --vault-name "$AZ_KEYVAULT_NAME" --name "$secret" --query value -o tsv 2>/dev/null || true
}

# free_port <start>
free_port() {
    local p="$1" limit=$(( $1 + 60 ))
    while [[ "$p" -lt "$limit" ]]; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then printf '%s' "$p"; return 0; fi
        # Braces matter. `exec` with no command applies its redirections to the
        # CURRENT SHELL, permanently -- so `exec 3>&- 2>/dev/null` does not
        # scope the 2>/dev/null to the fd-close, it points the whole script's
        # stderr at /dev/null for the rest of the run. Every later die() then
        # printed nothing: --azure failed after 3s with no error at all.
        { exec 3>&-; } 2>/dev/null || true
        p=$(( p + 1 ))
    done
    return 1
}

TUNNEL_PID=''
TUNNEL_PGID=''
TUNNEL_PORT=''
SELF_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"

# Killing $TUNNEL_PID alone does not close the tunnel. On Homebrew `az` is a
# bash wrapper that does NOT exec:
#     AZ_INSTALLER=HOMEBREW .../python -Im azure.cli "$@"
# so $! is the wrapper's PID, and killing it leaves the python child running -
# reparented to init, still holding the Bastion session and still bound to the
# local port. The script printed "closing Bastion tunnel" while closing
# nothing; free_port then had to walk one port further on every run, and its
# window is only 60 wide, so connect.sh eventually died with "no free local
# port". open_tunnel starts the tunnel in its OWN process group so the whole
# tree can be signalled here. Orphaning changes a process's parent, not its
# process group, so the pgid stays a reliable handle on the child even after
# the wrapper is gone.
tunnel_stragglers() {
    local pid pgid
    [[ -n "$TUNNEL_PORT" && -n "$TUNNEL_PGID" && "$TUNNEL_PGID" != "$SELF_PGID" ]] || return 0
    have lsof || return 0
    for pid in $(lsof -ti "tcp:${TUNNEL_PORT}" -sTCP:LISTEN 2>/dev/null); do
        pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        [[ "$pgid" == "$TUNNEL_PGID" ]] && printf '%s\n' "$pid"
    done
    return 0
}

cleanup() {
    [[ -n "$TUNNEL_PID" ]] || return 0
    printf '\n  %sclosing Bastion tunnel%s\n' "$C_DIM" "$C_RESET"
    if [[ -n "$TUNNEL_PGID" && "$TUNNEL_PGID" != "$SELF_PGID" ]]; then
        kill -- "-${TUNNEL_PGID}" 2>/dev/null || true
    else
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    wait "$TUNNEL_PID" 2>/dev/null || true

    # Backstop, and the proof that the tunnel really is shut: only ever kills
    # PIDs whose process group is the one open_tunnel created, so a port the
    # user handed us with --port that turned out to belong to someone else is
    # never touched.
    local waited=0 pids
    while [[ "$waited" -lt 5 ]]; do
        pids="$(tunnel_stragglers)"
        [[ -n "$pids" ]] || return 0
        # shellcheck disable=SC2086  # deliberate word splitting: one PID per line
        kill $pids 2>/dev/null || true
        sleep 1
        waited=$(( waited + 1 ))
    done
    [[ -z "$(tunnel_stragglers)" ]] || \
        warn "127.0.0.1:${TUNNEL_PORT} is still held: lsof -nP -iTCP:${TUNNEL_PORT} -sTCP:LISTEN"
}
trap cleanup EXIT INT TERM

# out <key> - read a value from generated/outputs.json
OUTPUTS="${REPO_ROOT}/generated/outputs.json"
out() {
    [[ -f "$OUTPUTS" ]] || return 0
    have jq || return 0
    jq -r --arg k "$1" '.[$k] // empty' "$OUTPUTS" 2>/dev/null || true
}

# open_tunnel <bastion> <rg> <target-resource-id> <remote-port> <local-port>
open_tunnel() {
    local bastion="$1" rg="$2" resid="$3" rport="$4" lport="$5" waited=0
    info "Bastion tunnel 127.0.0.1:${lport} -> ${rport}"
    # `set -m` (job control) puts the background job in a process group of its
    # own, which is the only handle that survives the non-exec `az` wrapper.
    # See the note above cleanup().
    set -m
    az network bastion tunnel --name "$bastion" --resource-group "$rg" \
        --target-resource-id "$resid" --resource-port "$rport" --port "$lport" >/dev/null 2>&1 &
    TUNNEL_PID=$!
    set +m
    TUNNEL_PORT="$lport"
    TUNNEL_PGID="$(ps -o pgid= -p "$TUNNEL_PID" 2>/dev/null | tr -d '[:space:]')"
    until (exec 3<>"/dev/tcp/127.0.0.1/${lport}") 2>/dev/null; do
        { exec 3>&-; } 2>/dev/null || true
        sleep 1
        waited=$(( waited + 1 ))
        kill -0 "$TUNNEL_PID" 2>/dev/null || die "the Bastion tunnel process exited immediately" \
            "Bastion must be the Standard SKU with native client support enabled:
       az network bastion show --name '${bastion}' --resource-group '${rg}' --query 'sku.name'
       az network bastion update --name '${bastion}' --resource-group '${rg}' --enable-tunneling true
       more: docs/troubleshooting.md"
        [[ "$waited" -lt 45 ]] || die "Bastion tunnel did not open within 45s" \
            "az network bastion tunnel --name '${bastion}' --resource-group '${rg}' --target-resource-id '${resid}' --resource-port ${rport} --port ${lport}"
    done
    { exec 3>&-; } 2>/dev/null || true
    ok "tunnel up on 127.0.0.1:${lport}"
}

hold_tunnel() {
    local lport="$1" what="$2"
    printf '\n  %s%sTunnel open.%s Point %s at %s127.0.0.1:%s%s\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET" "$what" "$C_BOLD" "$lport" "$C_RESET"
    printf '  %sCtrl-C to close it.%s\n\n' "$C_DIM" "$C_RESET"
    while kill -0 "$TUNNEL_PID" 2>/dev/null; do sleep 5; done
    warn "the tunnel process exited on its own"
}

# --------------------------------------------------------------------------
# Oracle helpers
# --------------------------------------------------------------------------
oracle_user_and_pw() {
    if   [[ "$AS_SYSTEM" -eq 1 ]]; then
        O_USER="${ORACLE_SYSTEM_USER:-SYSTEM}"
        O_PW="$(kv_or_env ORACLE_SYSTEM_PASSWORD KV_SECRET_ORACLE_SYSTEM_PASSWORD)"
    elif [[ "$AS_READER" -eq 1 ]]; then
        O_USER="${ORACLE_MIGRATION_USER:-O2P_READER}"
        O_PW="$(kv_or_env ORACLE_MIGRATION_PASSWORD KV_SECRET_ORACLE_MIGRATION_PASSWORD)"
    else
        O_USER="$CONTOSO_SCHEMA"
        O_PW="$(kv_or_env CONTOSO_PASSWORD KV_SECRET_CONTOSO_PASSWORD)"
    fi
    [[ -n "$O_PW" ]] || die "no password for Oracle user ${O_USER}" \
        "set the matching *_PASSWORD in ${ENV_FILE}, or USE_KEYVAULT=1"
}

# The connect string goes on stdin via /nolog, so it never appears in `ps`.
oracle_login_sql() {
    cat <<SQL
SET SQLPROMPT "${O_USER}@${ORACLE_SERVICE}> "
SET LINESIZE 200
SET PAGESIZE 5000
SET LONG 200000
SET SERVEROUTPUT ON SIZE UNLIMITED
SET TRIMSPOOL ON
WHENEVER SQLERROR CONTINUE
CONNECT ${O_USER}/"${O_PW}"@${1}:${2}/${ORACLE_SERVICE}
SQL
}

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
case "$TARGET" in

# ---------------------------------------------------------------- oracle-local
oracle-local)
    hdr "oracle-local"
    have docker || die "docker not installed" "brew install --cask docker"
    docker info >/dev/null 2>&1 || die "the Docker daemon is not responding" "start Docker Desktop"

    if ! docker inspect -f '{{.State.Status}}' "$CONTAINER" >/dev/null 2>&1; then
        if docker inspect -f '{{.State.Status}}' oracle-lab >/dev/null 2>&1; then
            CONTAINER='oracle-lab'
        else
            die "no container named '${CONTAINER}' (nor 'oracle-lab')" \
                "start Oracle first - see docs/02-seed-oracle.md.  docker ps -a"
        fi
    fi
    CSTATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
    [[ "$CSTATE" == "running" ]] || die "container '${CONTAINER}' is '${CSTATE}'" "docker start ${CONTAINER}"

    oracle_user_and_pw
    ok "${O_USER}@${ORACLE_SERVICE} in container ${CONTAINER}"

    if [[ -n "$SQL_COMMAND" ]]; then
        { oracle_login_sql localhost "$ORACLE_TARGET_PORT"
          printf 'SET HEADING ON\n%s\nEXIT SUCCESS\n' "$SQL_COMMAND"
        } | docker exec -i -e NLS_LANG=.AL32UTF8 "$CONTAINER" sqlplus -S -L /nolog
    else
        printf '  %stype EXIT to leave%s\n\n' "$C_DIM" "$C_RESET"
        # -t keeps the SQL> prompt interactive; the login script arrives on fd 0
        # first, then the terminal takes over.
        { oracle_login_sql localhost "$ORACLE_TARGET_PORT"; cat; } \
            | docker exec -i -e NLS_LANG=.AL32UTF8 "$CONTAINER" sqlplus -S -L /nolog
    fi
    ;;

# ---------------------------------------------------------------- oracle-azure
oracle-azure)
    hdr "oracle-azure"
    have az || die "az CLI not installed" "brew install azure-cli"
    have jq || die "jq is required to read generated/outputs.json" "brew install jq"
    az account show >/dev/null 2>&1 || die "Azure CLI is not logged in" "az login"
    [[ -f "$OUTPUTS" ]] || die "generated/outputs.json not found" \
        "run scripts/deploy.sh first - it writes the connection details this script reads"

    RG="$(out resourceGroupName)"; RG="${RG:-${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}}"
    BASTION="$(out bastionName)"; BASTION="${BASTION:-${PREFIX}-bastion}"
    VM_NAME="$(out oracleVmName)"; VM_NAME="${VM_NAME:-${PREFIX}-oracle-vm}"
    VM_ID="$(out oracleVmId)"
    SSH_USER="$(out oracleAdminUsername)"; SSH_USER="${SSH_USER:-${ORACLE_VM_ADMIN_USER:-azureuser}}"
    SSH_KEY="${SSH_KEY_PATH:-${REPO_ROOT}/generated/ssh/${PREFIX}-lab_ed25519}"

    [[ -f "$SSH_KEY" ]] || die "no SSH private key at ${SSH_KEY}" \
        "scripts/deploy.sh generates it; set SSH_KEY_PATH in .env if yours is elsewhere"

    if [[ -z "$VM_ID" ]]; then
        VM_ID="$(az vm show --resource-group "$RG" --name "$VM_NAME" --query id -o tsv 2>/dev/null || true)"
    fi
    [[ -n "$VM_ID" ]] || die "cannot find VM '${VM_NAME}' in resource group '${RG}'" \
        "az vm list --resource-group '${RG}' -o table"

    LPORT="${PORT_OVERRIDE:-$(free_port 22022)}"
    [[ -n "$LPORT" ]] || die "no free local port" "pass --port <n>"
    open_tunnel "$BASTION" "$RG" "$VM_ID" 22 "$LPORT"

    if [[ "$TUNNEL_ONLY" -eq 1 ]]; then
        printf '  %sssh -i %s -p %s %s@127.0.0.1%s\n' "$C_DIM" "$SSH_KEY" "$LPORT" "$SSH_USER" "$C_RESET"
        hold_tunnel "$LPORT" "your SSH client"
        exit 0
    fi

    SSH_OPTS=(-i "$SSH_KEY" -p "$LPORT"
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30)

    if [[ "$SHELL_MODE" -eq 1 ]]; then
        ok "opening a shell on ${VM_NAME}"
        note "the Oracle container is '${CONTAINER}'; try: docker exec -it ${CONTAINER} sqlplus / as sysdba"
        ssh -t "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" || true
        exit 0
    fi

    oracle_user_and_pw
    ok "${O_USER}@${ORACLE_SERVICE} on ${VM_NAME}"
    # $CONTAINER is deliberately expanded here, on the client, and printf %q
    # quotes it safely for the remote shell.
    # See the NLS_LANG note in scripts/seed-oracle.sh: never inherit it from the image.
    REMOTE_CMD="docker exec -i -e NLS_LANG=.AL32UTF8 $(printf '%q' "$CONTAINER") sqlplus -S -L /nolog"
    # shellcheck disable=SC2029  # $REMOTE_CMD is deliberately expanded locally; printf %q quoted it above
    if [[ -n "$SQL_COMMAND" ]]; then
        { oracle_login_sql localhost "$ORACLE_TARGET_PORT"
          printf 'SET HEADING ON\n%s\nEXIT SUCCESS\n' "$SQL_COMMAND"
        } | ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" "$REMOTE_CMD"
    else
        printf '  %stype EXIT to leave%s\n\n' "$C_DIM" "$C_RESET"
        { oracle_login_sql localhost "$ORACLE_TARGET_PORT"; cat; } \
            | ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" "$REMOTE_CMD"
    fi
    ;;

# ------------------------------------------------------------ postgres/scratch
postgres|scratch)
    # The target database (contoso_store) server is the anchor. Per task #3 the
    # scratch database (migration_scratch) is a SECOND database on the SAME
    # flexible server - same FQDN, same admin credentials - so scratch inherits
    # every target value and overrides only the database name. There is no
    # scratch HOST output distinct from the target's, so the host falls back to
    # the target's FQDN.
    #
    # For the HOSTNAME, and only the hostname, outputs.json outranks .env - in
    # BOTH branches. infra/main.bicep names the server
    # '${namePrefix}-pg-${uniqueString(...)}', so no hostname a reader writes in
    # .env before deploying can ever be right; .env.example ships
    # o2p-pg-target / o2p-pg-scratch placeholders that resolve to NXDOMAIN. The
    # scratch branch used to read `${SCRATCH_PGHOST:-$(out ...)}`, which let
    # that placeholder outrank a real deployment: straight after a successful
    # deploy.sh, `connect.sh postgres` worked and `connect.sh scratch` failed
    # against a host that has never existed. .env still supplies the host when
    # there is no outputs.json, which is the case a reader pointing at their own
    # server actually needs.
    PG_FQDN="$(out postgresFqdn)"; PG_FQDN="${PG_FQDN:-${PGHOST:-}}"
    if [[ "$TARGET" == "scratch" ]]; then
        hdr "scratch PostgreSQL"
        P_HOST="$(out scratchPostgresFqdn)"; P_HOST="${P_HOST:-${SCRATCH_PGHOST:-$PG_FQDN}}"
        P_PORT="${SCRATCH_PGPORT:-${PGPORT:-5432}}"
        P_DB="${SCRATCH_PGDATABASE:-$(out postgresScratchDatabaseName)}"; P_DB="${P_DB:-migration_scratch}"
        P_USER="${SCRATCH_PGUSER:-${PGUSER:-o2padmin}}"
        P_PW="$(kv_or_env SCRATCH_PGPASSWORD KV_SECRET_SCRATCH_PG_PASSWORD)"
        P_PW="${P_PW:-$(kv_or_env PGPASSWORD KV_SECRET_PG_PASSWORD)}"
        P_SSL="${SCRATCH_PGSSLMODE:-${PGSSLMODE:-require}}"
    else
        hdr "target PostgreSQL"
        P_HOST="$PG_FQDN"
        P_PORT="${PGPORT:-5432}"
        P_DB="${PGDATABASE:-contoso_store}"
        P_USER="${PGUSER:-o2padmin}"
        P_PW="$(kv_or_env PGPASSWORD KV_SECRET_PG_PASSWORD)"
        P_SSL="${PGSSLMODE:-require}"
    fi

    [[ -n "$P_HOST" ]] || die "no PostgreSQL host for target '${TARGET}'" \
        "run scripts/deploy.sh so outputs.json has postgresFqdn, or set $( [[ "$TARGET" == "scratch" ]] && echo 'SCRATCH_PGHOST (or PGHOST - scratch shares the target server)' || echo PGHOST ) in ${ENV_FILE}"

    # infra/main.bicep gives the flexible server a delegated subnet and a
    # private DNS zone, so it has no public endpoint and its FQDN only resolves
    # inside the VNet. Reaching it from a laptop therefore takes two hops:
    #
    #   laptop --(az network bastion tunnel)--> Oracle VM :22
    #          --(ssh -L)-------------------->  <pg fqdn> :5432
    #
    # The Oracle VM is the jump host rather than the jumpbox because it is
    # Linux and already has our SSH key; the jumpbox is Windows and would need
    # OpenSSH server enabled first. Pass --direct to skip all of this if you
    # have enabled public network access on the server yourself.
    PG_CONNECT_HOST="$P_HOST"
    PG_CONNECT_PORT="$P_PORT"
    SSH_FWD_PID=''
    SSH_FWD_LOG=''
    fwd_cleanup() {
        if [[ -n "$SSH_FWD_PID" ]]; then kill "$SSH_FWD_PID" 2>/dev/null || true; fi
        if [[ -n "$SSH_FWD_LOG" ]]; then rm -f "$SSH_FWD_LOG"; fi
        cleanup
    }

    if [[ "$DIRECT" -eq 0 ]]; then
        have az || die "az CLI not installed" "brew install azure-cli, or use --direct"
        have jq || die "jq is required to read generated/outputs.json" "brew install jq"
        az account show >/dev/null 2>&1 || die "Azure CLI is not logged in" "az login"
        [[ -f "$OUTPUTS" ]] || die "generated/outputs.json not found" \
            "run scripts/deploy.sh first, or use --direct if you are pointing at your own server"

        RG="$(out resourceGroupName)"; RG="${RG:-${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}}"
        BASTION="$(out bastionName)"; BASTION="${BASTION:-${PREFIX}-bastion}"
        VM_NAME="$(out oracleVmName)"; VM_NAME="${VM_NAME:-${PREFIX}-oracle-vm}"
        SSH_USER="$(out oracleAdminUsername)"; SSH_USER="${SSH_USER:-${ORACLE_VM_ADMIN_USER:-azureuser}}"
        SSH_KEY="${SSH_KEY_PATH:-${REPO_ROOT}/generated/ssh/${PREFIX}-lab_ed25519}"
        [[ -f "$SSH_KEY" ]] || die "no SSH private key at ${SSH_KEY}" \
            "scripts/deploy.sh generates it; set SSH_KEY_PATH in .env if yours is elsewhere"

        VM_ID="$(az vm show --resource-group "$RG" --name "$VM_NAME" --query id -o tsv 2>/dev/null || true)"
        [[ -n "$VM_ID" ]] || die "cannot find the Oracle VM '${VM_NAME}' in '${RG}' to jump through" \
            "az vm list --resource-group '${RG}' -o table
       or use --direct if the server has public network access enabled"

        SSH_LPORT="$(free_port 22022)" || die "no free local port for the Bastion tunnel"
        open_tunnel "$BASTION" "$RG" "$VM_ID" 22 "$SSH_LPORT"

        PG_LPORT="${PORT_OVERRIDE:-$(free_port 15432)}"
        [[ -n "$PG_LPORT" ]] || die "no free local port for the PostgreSQL forward" "pass --port <n>"

        trap fwd_cleanup EXIT INT TERM

        # Ask the VM before claiming anything. `ssh -L` binds the LOCAL port
        # straight away and defers the remote name lookup and connect until a
        # client actually opens a channel; -o ExitOnForwardFailure=yes covers a
        # local BIND failure and nothing else. So a /dev/tcp probe of the local
        # end says only "ssh is listening" - it succeeds happily when the
        # forward points at a host that does not exist, and the reader is told
        # the database is reachable one line before psql dies with "server
        # closed the connection unexpectedly". Verified locally: with the exact
        # flags below and a bogus remote host, the local bind and the probe both
        # succeed. A real end-to-end check has to run on the far side of the
        # Bastion tunnel, so that is where this one runs.
        info "checking ${P_HOST}:${P_PORT} from ${VM_NAME}"
        PROBE_RC=0
        ssh -i "$SSH_KEY" -p "$SSH_LPORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes \
            "${SSH_USER}@127.0.0.1" \
            "bash -s -- $(printf '%q %q' "$P_HOST" "$P_PORT")" <<'PROBE' || PROBE_RC=$?
host="$1"; port="$2"
getent hosts "$host" >/dev/null 2>&1 || exit 3
timeout 10 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1 || exit 4
exit 0
PROBE
        case "$PROBE_RC" in
            0) ok "${VM_NAME} can reach ${P_HOST}:${P_PORT}" ;;
            3) die "${VM_NAME} cannot resolve ${P_HOST}" \
                   "the name is wrong, or the private DNS zone is not linked to the VNet.
       compare what you are using with what the deployment produced:
         jq -r '.postgresFqdn, .scratchPostgresFqdn' generated/outputs.json
       a stale PGHOST / SCRATCH_PGHOST in ${ENV_FILE} is the usual cause -
       the real server name carries a uniqueString() suffix, so any hostname
       written before deploying is a guess. More: docs/troubleshooting.md" ;;
            4) die "${VM_NAME} resolves ${P_HOST} but cannot open port ${P_PORT}" \
                   "the flexible server's NSG or firewall is blocking the VM's subnet:
       az postgres flexible-server show --name '${P_HOST%%.*}' --resource-group '${RG}' -o json
       More: docs/troubleshooting.md" ;;
            *) die "could not run the reachability check on ${VM_NAME} (ssh exited ${PROBE_RC})" \
                   "check the Bastion tunnel and the key:
       ${SCRIPT_NAME} oracle-azure --shell" ;;
        esac

        # ssh's stderr goes to a file rather than the terminal: at LogLevel=INFO
        # it is noisy on a good run ("Warning: Permanently added ..."), but it
        # carries the one line that names the real cause on a bad one -
        # "channel 2: open failed: administratively prohibited". LogLevel=ERROR
        # used to swallow that, leaving a bare psql disconnect and a hint that
        # sent the reader after the password. The log is printed on failure.
        SSH_FWD_LOG="$(mktemp "${TMPDIR:-/tmp}/o2p-pgfwd.XXXXXX")"
        info "forwarding 127.0.0.1:${PG_LPORT} -> ${P_HOST}:${P_PORT} via ${VM_NAME}"
        ssh -N -L "${PG_LPORT}:${P_HOST}:${P_PORT}" \
            -i "$SSH_KEY" -p "$SSH_LPORT" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=INFO -o ConnectTimeout=15 -o ServerAliveInterval=30 \
            -o ExitOnForwardFailure=yes \
            "${SSH_USER}@127.0.0.1" 2>"$SSH_FWD_LOG" &
        SSH_FWD_PID=$!

        WAITED=0
        until (exec 3<>"/dev/tcp/127.0.0.1/${PG_LPORT}") 2>/dev/null; do
            { exec 3>&-; } 2>/dev/null || true
            sleep 1
            WAITED=$(( WAITED + 1 ))
            kill -0 "$SSH_FWD_PID" 2>/dev/null || die "the SSH port-forward exited immediately" \
                "check the Oracle VM can resolve and reach the server:
       ${SCRIPT_NAME} oracle-azure --shell   then:  getent hosts ${P_HOST}"
            [[ "$WAITED" -lt 30 ]] || die "the port-forward did not open within 30s" \
                "check the private DNS zone links the VNet to ${P_HOST} - see docs/troubleshooting.md"
        done
        { exec 3>&-; } 2>/dev/null || true
        # Only the local bind is proven here; the far end was proven above.
        ok "forward bound on 127.0.0.1:${PG_LPORT}"

        PG_CONNECT_HOST='127.0.0.1'
        PG_CONNECT_PORT="$PG_LPORT"
        # sslmode=require encrypts but does not verify the hostname, so the
        # 127.0.0.1 / FQDN mismatch is fine. verify-full would not be.
        case "$P_SSL" in
            verify-ca|verify-full)
                warn "sslmode=${P_SSL} cannot verify a certificate through a port-forward; using 'require'"
                P_SSL='require' ;;
        esac
    fi

    if [[ "$TUNNEL_ONLY" -eq 1 ]]; then
        [[ "$DIRECT" -eq 0 ]] || die "--tunnel-only and --direct contradict each other" "drop one of them"
        printf '\n  %sconnection string:%s postgresql://%s@127.0.0.1:%s/%s?sslmode=%s\n' \
            "$C_DIM" "$C_RESET" "$P_USER" "$PG_CONNECT_PORT" "$P_DB" "$P_SSL"
        hold_tunnel "$PG_CONNECT_PORT" "psql / VS Code / the pgsql extension"
        exit 0
    fi

    have psql || die "psql not installed" \
        "brew install libpq && brew link --force libpq
       or: brew install postgresql@16"
    [[ -n "$P_PW" ]] || die "no PostgreSQL password" \
        "set $( [[ "$TARGET" == "scratch" ]] && echo SCRATCH_PGPASSWORD || echo PGPASSWORD ) in ${ENV_FILE}, or USE_KEYVAULT=1"

    ok "${P_USER}@${P_DB} (${P_HOST}) sslmode=${P_SSL}"
    note "search_path: ${PG_SEARCH_PATH:-contoso,public}"
    note "pg_catalog is searched first - call oracle.to_char() explicitly where Oracle semantics matter"

    # PGPASSWORD in the environment of the child only; never in argv.
    export PGPASSWORD="$P_PW"
    export PGOPTIONS="--search_path=${PG_SEARCH_PATH:-contoso,public}"
    export PGSSLMODE="$P_SSL"
    PSQL_ARGS=(--host "$PG_CONNECT_HOST" --port "$PG_CONNECT_PORT" --username "$P_USER" --dbname "$P_DB")

    # psql's own exit status is preserved - callers script against it.
    pg_failed() {
        local rc="$1"
        if [[ -n "$SSH_FWD_LOG" && -s "$SSH_FWD_LOG" ]]; then
            printf '\n  %sssh port-forward log:%s\n' "$C_BOLD" "$C_RESET" >&2
            grep -v 'Permanently added' "$SSH_FWD_LOG" | sed 's/^/    /' >&2 || true
        fi
        printf '\n%s%sconnect failed:%s psql exited %s against %s\n' \
            "$C_BOLD" "$C_RED" "$C_RESET" "$rc" "$P_HOST" >&2
        printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "the usual causes:
       - wrong password: check $( [[ "$TARGET" == "scratch" ]] && echo SCRATCH_PGPASSWORD || echo PGPASSWORD ) in ${ENV_FILE}
       - the database does not exist yet: connect to 'postgres' instead
       - with --direct, the server is private-only or your IP is not allowed:
           drop --direct to tunnel through the Oracle VM instead" >&2
        exit "$rc"
    }

    PSQL_RC=0
    if [[ -n "$SQL_COMMAND" ]]; then
        psql "${PSQL_ARGS[@]}" --command "$SQL_COMMAND" || PSQL_RC=$?
    else
        printf '  %stype \\q to leave%s\n\n' "$C_DIM" "$C_RESET"
        psql "${PSQL_ARGS[@]}" || PSQL_RC=$?
    fi
    [[ "$PSQL_RC" -eq 0 ]] || pg_failed "$PSQL_RC"
    ;;

*)
    die "unknown target '${TARGET}'" "run ${SCRIPT_NAME} --help"
    ;;
esac
