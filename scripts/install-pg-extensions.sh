#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# install-pg-extensions.sh - run CREATE EXTENSION against the target and
# scratch databases, then prove that shared_preload_libraries is actually
# loaded.
#
# WHY THIS SCRIPT EXISTS
#
# infra/modules/postgres-flex.bicep sets azure.extensions, which is the
# ALLOWLIST: it decides what a user is permitted to create. It does not create
# anything, and ARM has no resource that does. So a perfectly deployed server
# still has nothing but plpgsql in either database.
#
# That gap is invisible until the conversion tool's "Verify Extensions" button
# tells you about it. On a real run of this lab it said:
#
#   The following recommended Azure Database for PostgreSQL extensions are not
#   installed in database "migration_scratch": orafce, pg_partman, pgcrypto,
#   postgis, postgis_tiger_geocoder, postgis_topology, tablefunc, uuid-ossp,
#   pg_trgm
#
# THE SECOND CHECK MATTERS MORE THAN THE FIRST
#
# scripts/deploy.sh and scripts/status.sh both ask ARM whether
# shared_preload_libraries is pending a restart. ARM is not the server. This
# script asks the running server directly -- SHOW shared_preload_libraries --
# because that is the only answer that cannot be stale, and because
# plpgsql_check fails OPEN: if it is not in memory the converter skips its
# deeper validation with no error and no warning, and the report looks clean.
#
# WHERE TO RUN IT
#
# From the jumpbox, where PGHOST resolves and no tunnelling is needed. From a
# laptop, open a tunnel first and point PGHOST/PGPORT at it:
#
#   ./scripts/connect.sh postgres     # then PGHOST=127.0.0.1 PGPORT=15432
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
bad()  { printf '  %s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  {
    printf '\n%s%s%s failed:%s %s\n' "$C_BOLD" "$C_RED" "$SCRIPT_NAME" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - CREATE EXTENSION in the target and scratch databases.

  --target-only    only ${PGDATABASE:-contoso_store}
  --scratch-only   only the conversion tool's scratch database
  --check          report what is installed and change nothing
  -h, --help       this text

Reads connection details from .env. Needs psql on PATH.
EOF
}

DO_TARGET=1
DO_SCRATCH=1
CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-only)  DO_SCRATCH=0; shift ;;
        --scratch-only) DO_TARGET=0;  shift ;;
        --check)        CHECK_ONLY=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; die "unknown argument: $1" ;;
    esac
done

command -v psql >/dev/null 2>&1 || die "psql is not on PATH" \
    "install the PostgreSQL client, e.g. 'brew install libpq' or 'sudo dnf install postgresql'"

ENV_FILE="${REPO_ROOT}/.env"
[[ -f "$ENV_FILE" ]] || die "no .env at ${ENV_FILE}" "cp .env.example .env and fill it in"

# Anything already in the environment beats .env, so a tunnelled run works:
#
#   PGHOST=127.0.0.1 PGPORT=15432 ./scripts/install-pg-extensions.sh
#
# Without this, "set -a; . .env" would overwrite the override with the private
# FQDN and the script would sit there failing to resolve a name that only
# exists inside the VNet.
for V in PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PGSSLMODE SCRATCH_PGDATABASE; do
    [[ -n "${!V:-}" ]] && declare "OVERRIDE_${V}=${!V}"
done

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

for V in PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PGSSLMODE SCRATCH_PGDATABASE; do
    O="OVERRIDE_${V}"
    [[ -n "${!O:-}" ]] && declare "${V}=${!O}"
done

: "${PGHOST:?PGHOST is not set in .env}"
: "${PGPASSWORD:?PGPASSWORD is not set in .env}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-o2padmin}"
PGDATABASE="${PGDATABASE:-contoso_store}"
PGSSLMODE="${PGSSLMODE:-require}"
SCRATCH_PGDATABASE="${SCRATCH_PGDATABASE:-migration_scratch}"
export PGPASSWORD PGSSLMODE

# The list the conversion tool asks for, plus the two this lab needs that it
# does not mention: dblink (PRAGMA AUTONOMOUS_TRANSACTION converts to a dblink
# round trip) and plpgsql_check (the validation pass that fails open).
#
# Order matters. postgis_tiger_geocoder depends on postgis and fuzzystrmatch,
# and fuzzystrmatch is NOT allowlistable on Azure by name -- CASCADE pulls it in
# as a dependency, which Azure permits, but a direct CREATE EXTENSION
# fuzzystrmatch is refused. Hence CASCADE on every statement and this ordering.
EXTENSIONS=(
    "uuid-ossp" pgcrypto pg_trgm tablefunc orafce dblink
    plpgsql_check pg_stat_statements
    postgis postgis_topology postgis_tiger_geocoder
    pg_partman
)

psql_q() {
    local db="$1"; shift
    psql --host "$PGHOST" --port "$PGPORT" --username "$PGUSER" --dbname "$db" \
         --no-psqlrc --tuples-only --no-align --quiet "$@"
}

install_into() {
    local db="$1" ext failures=0
    hdr "Database ${db}"

    local before
    before="$(psql_q "$db" -c "SELECT count(*) FROM pg_extension;" 2>/dev/null)" \
        || die "cannot connect to ${db} on ${PGHOST}:${PGPORT} as ${PGUSER}" \
               "from a laptop the server is private - open a tunnel first: ./scripts/connect.sh postgres"
    info "${before} extension(s) installed before this run"

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        psql_q "$db" -c "SELECT extname FROM pg_extension ORDER BY 1;" | sed 's/^/         /'
        return 0
    fi

    for ext in "${EXTENSIONS[@]}"; do
        if psql_q "$db" -c "CREATE EXTENSION IF NOT EXISTS \"${ext}\" CASCADE;" >/dev/null 2>&1; then
            ok "$ext"
        else
            # Not fatal on its own. postgis is a large install that some SKUs
            # refuse, and the conversion still runs without it - it just loses
            # the spatial cases. plpgsql_check is the one that matters, and it
            # is checked separately below.
            warn "${ext} - not installed"
            failures=$(( failures + 1 ))
        fi
    done

    local after
    after="$(psql_q "$db" -c "SELECT count(*) FROM pg_extension;")"
    info "${after} extension(s) installed now"
    [[ "$failures" -eq 0 ]] || note "${failures} could not be created; check azure.extensions allows them"
    return 0
}

RC=0
[[ "$DO_TARGET"  -eq 1 ]] && install_into "$PGDATABASE"
[[ "$DO_SCRATCH" -eq 1 ]] && install_into "$SCRATCH_PGDATABASE"

# --------------------------------------------------------------------------
# The check ARM cannot answer
# --------------------------------------------------------------------------
# deploy.sh and status.sh read isConfigPendingRestart from ARM. That is the
# control plane's opinion. This is the server's.
hdr "shared_preload_libraries, as the running server reports it"
LOADED="$(psql_q "$PGDATABASE" -c "SHOW shared_preload_libraries;" 2>/dev/null || echo '')"
if [[ -z "$LOADED" ]]; then
    warn "could not read shared_preload_libraries"
    RC=1
else
    note "$LOADED"
    for LIB in plpgsql_check pg_stat_statements; do
        if [[ ",${LOADED}," == *",${LIB},"* ]]; then
            ok "${LIB} is loaded"
        else
            bad "${LIB} is NOT loaded"
            if [[ "$LIB" == plpgsql_check ]]; then
                note "plpgsql_check fails OPEN: the converter will skip its deeper validation"
                note "with no error and no warning, and the report will look clean."
                note "fix: az postgres flexible-server restart -g ${AZ_RESOURCE_GROUP:-<rg>} -n \${PG_SERVER}"
            fi
            RC=1
        fi
    done
fi

printf '\n'
if [[ "$RC" -eq 0 ]]; then
    printf '%s%sReady.%s Run "Verify Extensions" in the wizard to see the same answer.\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET"
else
    printf '%s%sNot ready.%s Fix the failures above before trusting a conversion report.\n' \
        "$C_BOLD" "$C_RED" "$C_RESET"
fi
exit "$RC"
