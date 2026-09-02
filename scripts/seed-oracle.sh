#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# seed-oracle.sh - build the CONTOSO schema in Oracle, in the right order.
#
# Runs, in this order:
#   1. src/oracle/00-*.sql .. 13-*.sql   the hand-written schema (~350 objects)
#   2. generated/oracle/*.sql            the object generator's ~792
#   3. generated/oracle/data/*.sql       the row data
#   4. src/oracle/99-verify-objects.sql  the object-count assertion, always last
#
# If generated/oracle/ has no SQL in it, tools/generate-objects.py is run
# first; if generated/oracle/data/ has none, tools/generate-data.py is.
#
# TARGETS
#   --local   the Docker container named by ORACLE_CONTAINER_NAME. sqlplus
#             runs inside it, so it always reaches the container's own
#             1521; ORACLE_PORT only describes the host mapping.
#   --azure   the Oracle VM, reached by SSH over an az network bastion tunnel
#
# Passwords are never placed on a command line. SQL*Plus is started with
# /nolog and the CONNECT is fed on stdin, so nothing sensitive appears in
# `ps` on this machine or on the VM.
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
    printf '\n%s%sseed failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Milliseconds since the epoch, on GNU date, bash 5 and everything else.
now_ms() {
    local t
    if t="$(date +%s%3N 2>/dev/null)" && [[ "$t" != *N* ]]; then
        printf '%s' "$t"
    elif [[ -n "${EPOCHREALTIME:-}" ]]; then
        t="${EPOCHREALTIME/,/.}"; t="${t%.*}${t#*.}"; printf '%s' "${t:0:13}"
    else
        printf '%s000' "$(date +%s)"
    fi
}
# fmt_ms <milliseconds> -> "1m 03.4s" or "812ms"
fmt_ms() {
    local ms="$1"
    if   [[ "$ms" -lt 1000  ]]; then printf '%dms' "$ms"
    elif [[ "$ms" -lt 60000 ]]; then printf '%d.%01ds' "$(( ms / 1000 ))" "$(( (ms % 1000) / 100 ))"
    else printf '%dm %02ds' "$(( ms / 60000 ))" "$(( (ms % 60000) / 1000 ))"; fi
}

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
TARGET=''
SCALE=''
DRY_RUN=0
NO_GENERATE=0
CONTINUE_ON_ERROR=0
ONLY_PATTERN=''
START_FROM=''

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - load the CONTOSO schema into Oracle.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME} --local  [options]
    ${SCRIPT_NAME} --azure  [options]

${C_BOLD}TARGET (exactly one is required)${C_RESET}
    --local              The Docker container \$ORACLE_CONTAINER_NAME
                         (default o2p-oracle). sqlplus runs inside the
                         container, so \$ORACLE_PORT is only the host
                         mapping and need not be 1521.
    --azure              The Oracle VM in Azure, over SSH through an
                         'az network bastion tunnel'. Needs generated/outputs.json
                         from a successful scripts/deploy.sh.

${C_BOLD}OPTIONS${C_RESET}
    --scale <n>          Row-volume multiplier exposed to the seed SQL as
                         &scale, and mapped to the nearest named scale
                         (small / medium / large) for tools/generate-data.py.
                         1 = the .env defaults (${SEED_ORDER_ROWS:-250000} orders).
                         Use 0.01 for a fast smoke test.
    --no-generate        Do not run tools/generate-objects.py or
                         tools/generate-data.py even if their output
                         directories are empty. The object count will fall
                         short of the 1000 floor and 99-verify-objects.sql
                         will fail.
    --only <glob>        Run only files whose basename matches this glob,
                         e.g. --only '1?-*.sql'. Ordering is preserved.
    --from <name>        Skip everything before this file. Use to resume after
                         fixing a failure, e.g. --from 07-packages.sql.
    --continue-on-error  Keep going after a failing file instead of stopping.
                         Off by default: one bad DDL file makes every later
                         file fail too, and the first error is the real one.
    --dry-run            Print the execution plan and exit. Connects to
                         nothing.
    -h, --help           Show this help and exit.

${C_BOLD}ORDER${C_RESET}
    src/oracle/00..13  ->  generated/oracle/  ->  generated/oracle/data/
       ->  src/oracle/99-verify-objects.sql
    Within each directory, files sort by their two-digit numeric prefix.

${C_BOLD}ON FAILURE${C_RESET}
    The full SQL*Plus output for every file is kept under \$LOG_DIR
    (default ./out/logs). The failing file's log is named in the error.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)             TARGET='local'; shift ;;
        --azure)             TARGET='azure'; shift ;;
        --scale)             SCALE="${2:-}"; [[ -n "$SCALE" ]] || die "--scale needs a value"; shift 2 ;;
        --scale=*)           SCALE="${1#*=}"; shift ;;
        --only)              ONLY_PATTERN="${2:-}"; [[ -n "$ONLY_PATTERN" ]] || die "--only needs a value"; shift 2 ;;
        --only=*)            ONLY_PATTERN="${1#*=}"; shift ;;
        --from)              START_FROM="${2:-}"; [[ -n "$START_FROM" ]] || die "--from needs a value"; shift 2 ;;
        --from=*)            START_FROM="${1#*=}"; shift ;;
        --no-generate)       NO_GENERATE=1; shift ;;
        --continue-on-error) CONTINUE_ON_ERROR=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$TARGET" ]] || { printf '%serror: choose a target: --local or --azure%s\n\n' "$C_RED" "$C_RESET" >&2; usage >&2; exit 2; }

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
ORACLE_PORT="${ORACLE_PORT:-1521}"
CONTOSO_SCHEMA="${CONTOSO_SCHEMA:-CONTOSO}"
ORACLE_SYSTEM_USER="${ORACLE_SYSTEM_USER:-SYSTEM}"
ORACLE_MIGRATION_USER="${ORACLE_MIGRATION_USER:-O2P_READER}"
CONTAINER="${ORACLE_CONTAINER_NAME:-o2p-oracle}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/logs}"
GEN_ROOT="${GEN_OUTPUT_DIR:-${REPO_ROOT}/generated}"
case "$GEN_ROOT" in ./*) GEN_ROOT="${REPO_ROOT}/${GEN_ROOT#./}" ;; esac
# tools/generate-objects.py takes an output ROOT and writes into <root>/oracle/.
# GEN_ROOT is what --out receives; GEN_DIR is where the .sql actually lands and
# is what the file discovery below must scan. Collapsing these two into one path
# silently loads zero generated files: the plan still succeeds, it is just 760
# objects short, and 99-verify-objects.sql fails a long way from the cause.
GEN_DIR="${GEN_ROOT}/oracle"
SCALE="${SCALE:-1}"

# kv_or_env <env-var> <keyvault-secret-var>
kv_or_env() {
    local var="$1" kvvar="$2" value secret
    eval "value=\${${var}:-}"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
    [[ "${USE_KEYVAULT:-0}" == "1" ]] || return 0
    eval "secret=\${${kvvar}:-}"
    [[ -n "${AZ_KEYVAULT_NAME:-}" && -n "$secret" ]] || return 0
    az keyvault secret show --vault-name "$AZ_KEYVAULT_NAME" --name "$secret" --query value -o tsv 2>/dev/null || true
}

SYSTEM_PW="$(kv_or_env ORACLE_SYSTEM_PASSWORD    KV_SECRET_ORACLE_SYSTEM_PASSWORD)"
CONTOSO_PW="$(kv_or_env CONTOSO_PASSWORD         KV_SECRET_CONTOSO_PASSWORD)"
READER_PW="$(kv_or_env ORACLE_MIGRATION_PASSWORD KV_SECRET_ORACLE_MIGRATION_PASSWORD)"

[[ -n "$SYSTEM_PW"  ]] || die "ORACLE_SYSTEM_PASSWORD is not set"  "set it in ${ENV_FILE} (or USE_KEYVAULT=1)"
# CONTOSO_PW becomes &contoso_password / &1 in 00-user-tablespace.sql's
# CREATE USER contoso IDENTIFIED BY "...". An empty value makes that a
# zero-length identifier -- ORA-01741 -- raised deep inside the SQL on a clean
# runner. Catch it here, by name, before a single line of SQL is fed to sqlplus.
[[ -n "$CONTOSO_PW" ]] || die "CONTOSO_PASSWORD is empty"          "set it in ${ENV_FILE} (or USE_KEYVAULT=1); 00-user-tablespace.sql needs it to CREATE USER contoso"

# --------------------------------------------------------------------------
# Locate the SQL. src/oracle/ is where the hand-written schema lives; sql/ is
# checked first because an earlier draft of the layout used that name and an
# older checkout may still have it.
# --------------------------------------------------------------------------
SQL_DIR=''
for CANDIDATE in "${REPO_ROOT}/sql" "${REPO_ROOT}/src/oracle"; do
    if [[ -d "$CANDIDATE" ]] && ls "$CANDIDATE"/*.sql >/dev/null 2>&1; then SQL_DIR="$CANDIDATE"; break; fi
done
[[ -n "$SQL_DIR" ]] || die "no .sql files in ${REPO_ROOT}/src/oracle (nor sql/)" \
    "the schema authors have not written them yet, or you are in the wrong directory"

# Row data. tools/generate-data.py emits into generated/oracle/data/; seed/ and
# src/seed/ are accepted for hand-written data files, first match wins.
DATA_DIR="${GEN_DIR}/data"
SEED_DIR=''
for CANDIDATE in "$DATA_DIR" "${REPO_ROOT}/seed" "${REPO_ROOT}/src/seed"; do
    if [[ -d "$CANDIDATE" ]] && ls "$CANDIDATE"/*.sql >/dev/null 2>&1; then SEED_DIR="$CANDIDATE"; break; fi
done

# --------------------------------------------------------------------------
# Generators
# --------------------------------------------------------------------------
GENERATOR="${REPO_ROOT}/tools/generate-objects.py"
DATA_GENERATOR="${REPO_ROOT}/tools/generate-data.py"
gen_sql_present()  { ls "$GEN_DIR"/*.sql  >/dev/null 2>&1; }
data_sql_present() { [[ -n "$SEED_DIR" ]]; }

# gen_supports <extended-regex> - is this flag really in the generator's --help?
# Prefix matching in argparse means an unsupported flag is not always an error:
# `--count 760` against a parser that only declares --count-multiplier is
# silently accepted as --count-multiplier=760.0, which multiplies every object
# family by 760 instead of emitting 760 objects. So the probes below are
# anchored to reject a longer option that merely starts with the same letters.
GEN_HELP=''
gen_supports() { printf '%s' "$GEN_HELP" | grep -qE "$1"; }

if [[ "$NO_GENERATE" -eq 0 ]] && ! gen_sql_present; then
    hdr "Generator"
    [[ -f "$GENERATOR" ]] || die "${GEN_DIR#"$REPO_ROOT"/} is empty and ${GENERATOR#"$REPO_ROOT"/} does not exist" \
        "the generator's author has not written it yet. Re-run with --no-generate to load only the
       hand-written schema, but expect src/oracle/99-verify-objects.sql to fail the 1000-object floor."
    have python3 || die "python3 not installed" "brew install python@3.12"

    mkdir -p "$GEN_DIR"
    # Only pass flags the generator actually advertises. tools/ has a different
    # author; guessing its interface and failing on an unknown flag would be a
    # worse experience than adapting to it.
    GEN_HELP="$(python3 "$GENERATOR" --help 2>&1 || true)"
    GEN_ARGS=()
    gen_supports '\-\-seed[ =]'  && GEN_ARGS+=(--seed  "${GEN_SEED:-20260902}")
    # DELIBERATELY NOT passing --count.
    #
    # The generator owns its own object budget (GEN_OBJECT_TARGET in
    # tools/generate-objects.py) and asserts against it. Passing the number in
    # from .env made it a SECOND source of truth, and the two drifted: the
    # generator moved to 792 while .env.example still said 760. Because --count
    # is converted to a multiplier of N/GEN_OBJECT_TARGET, "--count 760" then
    # scaled the whole corpus by 0.9596 -> 763 objects instead of 792, missing
    # four per-type minimums, AND the budget assertion silently disabled itself
    # because the multiplier was no longer 1.0. The seed still printed
    # "verified" because 99-verify-objects.sql only asserts the 1000 floor, so
    # the failure only surfaced later in tests/run-tests.sh.
    #
    # Letting the generator use its own default is the fix: one source of
    # truth, and the budget assertion stays armed. Set GEN_OBJECT_COUNT in the
    # environment only if you deliberately want a non-contract corpus.
    if [[ -n "${GEN_OBJECT_COUNT:-}" ]] && gen_supports '\-\-count[^-a-z]'; then
        warn "GEN_OBJECT_COUNT=${GEN_OBJECT_COUNT} overrides the generator's own budget"
        note "the section 8 budget assertion is skipped for any value but the generator's default"
        GEN_ARGS+=(--count "$GEN_OBJECT_COUNT")
    fi
    # --out takes the ROOT; the generator appends /oracle itself. Passing
    # GEN_DIR here would nest it a second time as generated/oracle/oracle.
    if   gen_supports '\-\-out[ =]';    then GEN_ARGS+=(--out "$GEN_ROOT")
    elif gen_supports '\-\-output-dir'; then GEN_ARGS+=(--output-dir "$GEN_ROOT")
    fi

    info "python3 ${GENERATOR#"$REPO_ROOT"/} ${GEN_ARGS[*]-}"
    GEN_T0="$(now_ms)"
    python3 "$GENERATOR" ${GEN_ARGS[@]+"${GEN_ARGS[@]}"} \
        || die "the object generator failed" \
               "run it by hand to see the traceback: python3 '${GENERATOR}' ${GEN_ARGS[*]-}"
    GEN_N="$(find "$GEN_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
    ok "generated ${GEN_N} file(s) in $(fmt_ms $(( $(now_ms) - GEN_T0 )))"
elif [[ "$NO_GENERATE" -eq 1 ]]; then
    warn "--no-generate: skipping tools/generate-objects.py"
fi

# The row data is a separate generator with a separate output directory. It has
# to run here rather than being left to the reader, because nothing else in the
# pipeline produces rows: the conversion tool copies schema and code only, so an
# empty data phase would sail through the seed and only surface as an empty
# target database three documents later.
if [[ "$NO_GENERATE" -eq 0 ]] && ! data_sql_present && [[ -f "$DATA_GENERATOR" ]]; then
    hdr "Data generator"
    have python3 || die "python3 not installed" "brew install python@3.12"
    mkdir -p "$DATA_DIR"
    GEN_HELP="$(python3 "$DATA_GENERATOR" --help 2>&1 || true)"
    DATA_ARGS=()
    gen_supports '\-\-seed[ =]' && DATA_ARGS+=(--seed "${GEN_SEED:-20260902}")
    # --scale here is a NAME (small/medium/large), not the numeric multiplier
    # this script's own --scale carries. Map one onto the other rather than
    # passing a number argparse would reject.
    if gen_supports '\-\-scale[ =]'; then
        if gen_supports 'small,medium,large'; then
            case "$SCALE" in
                0|0.0*|0.1|.1|.0*) DATA_SCALE='small'  ;;
                1|1.*|0.5|.5|'')   DATA_SCALE='medium' ;;
                *)                 DATA_SCALE='large'  ;;
            esac
        else
            DATA_SCALE="$SCALE"
        fi
        DATA_ARGS+=(--scale "$DATA_SCALE")
    fi
    # Same rule as the object generator: --out is the ROOT, the generator
    # appends /oracle/data itself.
    if   gen_supports '\-\-out[ =]';    then DATA_ARGS+=(--out "$GEN_ROOT")
    elif gen_supports '\-\-output-dir'; then DATA_ARGS+=(--output-dir "$GEN_ROOT")
    fi

    info "python3 ${DATA_GENERATOR#"$REPO_ROOT"/} ${DATA_ARGS[*]-}"
    DATA_T0="$(now_ms)"
    python3 "$DATA_GENERATOR" ${DATA_ARGS[@]+"${DATA_ARGS[@]}"} \
        || die "the data generator failed" \
               "run it by hand to see the traceback: python3 '${DATA_GENERATOR}' ${DATA_ARGS[*]-}"
    [[ -d "$DATA_DIR" ]] && ls "$DATA_DIR"/*.sql >/dev/null 2>&1 && SEED_DIR="$DATA_DIR"
    DATA_N="$(find "$DATA_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
    ok "generated ${DATA_N} data file(s) in $(fmt_ms $(( $(now_ms) - DATA_T0 )))"
elif [[ "$NO_GENERATE" -eq 1 ]]; then
    warn "--no-generate: skipping tools/generate-data.py"
elif ! data_sql_present; then
    warn "no row data: neither ${DATA_DIR#"$REPO_ROOT"/} nor seed/ contains .sql"
    note "the schema will build and verify, but every table will be empty"
fi

# --------------------------------------------------------------------------
# Build the ordered file list
# --------------------------------------------------------------------------
FILES=()
add_files() {
    local dir="$1" f base
    [[ -d "$dir" ]] || return 0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        base="$(basename "$f")"
        # 99-verify-objects.sql is appended at the very end, not here.
        case "$base" in 99-*) continue ;; esac
        # *-load-all.sql is a SQL*Plus driver that @@-includes its siblings. It
        # exists so a human can cd into the directory and run one file by hand.
        # It must not be loaded here: this script feeds file CONTENTS to sqlplus
        # over stdin, so the @@ relative includes resolve against the container's
        # working directory and fail with SP2-0310 - and if they did resolve,
        # every generated object would be created twice.
        case "$base" in *-load-all.sql) continue ;; esac
        if [[ -n "$ONLY_PATTERN" ]]; then
            # shellcheck disable=SC2254  # the glob is supposed to be a pattern
            case "$base" in $ONLY_PATTERN) : ;; *) continue ;; esac
        fi
        FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | LC_ALL=C sort)
}

add_files "$SQL_DIR"
add_files "$GEN_DIR"
[[ -n "$SEED_DIR" ]] && add_files "$SEED_DIR"

VERIFY_FILE=''
for CANDIDATE in "$SQL_DIR"/99-*.sql; do
    [[ -f "$CANDIDATE" ]] && VERIFY_FILE="$CANDIDATE"
done
if [[ -z "$VERIFY_FILE" ]]; then
    # Silence here would be the worst outcome: the run would report success
    # having asserted nothing at all, and the 1000-object floor would go
    # unchecked until somebody read the by-type table by eye.
    warn "no 99-*.sql in ${SQL_DIR#"$REPO_ROOT"/} - the object floor will NOT be asserted"
    note "expected ${SQL_DIR#"$REPO_ROOT"/}/99-verify-objects.sql"
fi
if [[ -n "$VERIFY_FILE" ]]; then
    if [[ -z "$ONLY_PATTERN" ]]; then
        FILES+=("$VERIFY_FILE")
    else
        # shellcheck disable=SC2254  # the glob is supposed to be a pattern
        case "$(basename "$VERIFY_FILE")" in $ONLY_PATTERN) FILES+=("$VERIFY_FILE") ;; esac
    fi
fi

# --from: drop everything before the named file
if [[ -n "$START_FROM" ]]; then
    TRIMMED=()
    FOUND=0
    for F in ${FILES[@]+"${FILES[@]}"}; do
        [[ "$(basename "$F")" == "$START_FROM" ]] && FOUND=1
        [[ "$FOUND" -eq 1 ]] && TRIMMED+=("$F")
    done
    [[ "$FOUND" -eq 1 ]] || die "--from '${START_FROM}' matches no file in the plan" \
        "run with --dry-run to see the exact file names"
    FILES=(${TRIMMED[@]+"${TRIMMED[@]}"})
fi

TOTAL="${#FILES[@]}"
[[ "$TOTAL" -gt 0 ]] || die "no SQL files to run" "check --only / --from, or run --dry-run"

# --------------------------------------------------------------------------
# Plan
# --------------------------------------------------------------------------
hdr "Plan"
printf '  %-16s %s\n' "target"      "$TARGET"
printf '  %-16s %s\n' "schema"      "$CONTOSO_SCHEMA"
printf '  %-16s %s\n' "service"     "$ORACLE_SERVICE"
printf '  %-16s %s\n' "scale"       "$SCALE"
printf '  %-16s %s file(s)\n' "to run" "$TOTAL"
if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '\n'
    N=0
    for F in ${FILES[@]+"${FILES[@]}"}; do
        N=$(( N + 1 ))
        printf '  %3d. %s\n' "$N" "${F#"$REPO_ROOT"/}"
    done
    printf '\n%sDry run - nothing was executed and nothing was connected to.%s\n' "$C_DIM" "$C_RESET"
    exit 0
fi

# --------------------------------------------------------------------------
# Connect the target
# --------------------------------------------------------------------------
TUNNEL_PID=''
cleanup() {
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# free_port <start> - first TCP port from <start> that nothing is listening on
free_port() {
    local p="$1" limit=$(( $1 + 60 ))
    while [[ "$p" -lt "$limit" ]]; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then printf '%s' "$p"; return 0; fi
        exec 3>&- 2>/dev/null || true
        p=$(( p + 1 ))
    done
    return 1
}

SSH_HOST=''
SSH_PORT=''
SSH_USER=''
SSH_KEY=''

if [[ "$TARGET" == "local" ]]; then
    hdr "Target: local Docker container"
    have docker || die "docker not installed" "brew install --cask docker, or use --azure"
    docker info >/dev/null 2>&1 || die "the Docker daemon is not responding" "start Docker Desktop"

    if ! docker inspect -f '{{.State.Status}}' "$CONTAINER" >/dev/null 2>&1; then
        # An earlier draft of the brief called this container 'oracle-lab'.
        # Accept it so both names work.
        if docker inspect -f '{{.State.Status}}' oracle-lab >/dev/null 2>&1; then
            CONTAINER='oracle-lab'
            note "using container 'oracle-lab' (ORACLE_CONTAINER_NAME=${ORACLE_CONTAINER_NAME:-o2p-oracle} not found)"
        else
            die "no container named '${CONTAINER}' (nor 'oracle-lab')" \
                "start Oracle first. See docs/02-seed-oracle.md.
       docker ps -a   # to see what you do have"
        fi
    fi
    CSTATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
    [[ "$CSTATE" == "running" ]] || die "container '${CONTAINER}' is '${CSTATE}', not running" \
        "docker start ${CONTAINER}"
    ok "container ${CONTAINER} is running"

    # sqlplus runs INSIDE the container, so the listener it reaches is the
    # container's own 1521 — never the host-published port. Using ORACLE_PORT
    # here made ORACLE_PORT=1523 (with -p 1523:1521, the obvious way to avoid a
    # clash) fail on the very first file with ORA-12541 "no listener".
    # ORACLE_PORT still describes the HOST mapping, which is what a reader uses
    # from their own machine; it is simply not what docker exec sees.
    ORACLE_TARGET_HOST='localhost'
    ORACLE_TARGET_PORT='1521'
    exec_sqlplus() { docker exec -i "$CONTAINER" sqlplus -S -L /nolog; }

else
    hdr "Target: Azure Oracle VM via Bastion"
    have az || die "az CLI not installed" "brew install azure-cli"
    have jq || die "jq is required to read generated/outputs.json" "brew install jq"
    az account show >/dev/null 2>&1 || die "Azure CLI is not logged in" "az login"

    OUTPUTS="${REPO_ROOT}/generated/outputs.json"
    [[ -f "$OUTPUTS" ]] || die "generated/outputs.json not found" \
        "run scripts/deploy.sh first; it writes the connection details this script needs"

    # out <key> [default] - read a template output, tolerating naming drift
    out() { jq -r --arg k "$1" '.[$k] // empty' "$OUTPUTS" 2>/dev/null || true; }
    PREFIX="${AZ_PREFIX:-o2p}"
    RG="$(out resourceGroupName)";  RG="${RG:-${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}}"
    BASTION="$(out bastionName)";   BASTION="${BASTION:-${PREFIX}-bastion}"
    VM_NAME="$(out oracleVmName)";  VM_NAME="${VM_NAME:-${PREFIX}-oracle-vm}"
    VM_ID="$(out oracleVmId)"
    SSH_USER="$(out oracleAdminUsername)"; SSH_USER="${SSH_USER:-${ORACLE_VM_ADMIN_USER:-azureuser}}"
    SSH_KEY="${SSH_KEY_PATH:-${REPO_ROOT}/generated/ssh/${PREFIX}-lab_ed25519}"

    [[ -f "$SSH_KEY" ]] || die "no SSH private key at ${SSH_KEY}" \
        "scripts/deploy.sh generates it. Set SSH_KEY_PATH in .env if yours lives elsewhere."

    if [[ -z "$VM_ID" ]]; then
        VM_ID="$(az vm show --resource-group "$RG" --name "$VM_NAME" --query id -o tsv 2>/dev/null || true)"
    fi
    [[ -n "$VM_ID" ]] || die "cannot find the Oracle VM '${VM_NAME}' in resource group '${RG}'" \
        "az vm list --resource-group '${RG}' -o table"

    SSH_PORT="$(free_port 22022)" || die "no free local port in 22022-22082" "close something and retry"
    SSH_HOST='127.0.0.1'

    info "opening Bastion tunnel 127.0.0.1:${SSH_PORT} -> ${VM_NAME}:22"
    az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
        --target-resource-id "$VM_ID" --resource-port 22 --port "$SSH_PORT" >/dev/null 2>&1 &
    TUNNEL_PID=$!

    WAITED=0
    until (exec 3<>"/dev/tcp/127.0.0.1/${SSH_PORT}") 2>/dev/null; do
        exec 3>&- 2>/dev/null || true
        sleep 1
        WAITED=$(( WAITED + 1 ))
        kill -0 "$TUNNEL_PID" 2>/dev/null || die "the Bastion tunnel process exited immediately" \
            "check the Bastion SKU is Standard and native client support is enabled:
       az network bastion show --name '${BASTION}' --resource-group '${RG}' --query 'sku.name'"
        [[ "$WAITED" -lt 45 ]] || die "Bastion tunnel did not open within 45s" \
            "az network bastion tunnel --name '${BASTION}' --resource-group '${RG}' --target-resource-id '${VM_ID}' --resource-port 22 --port ${SSH_PORT}"
    done
    exec 3>&- 2>/dev/null || true
    ok "tunnel up on 127.0.0.1:${SSH_PORT}"

    SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30)

    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" true 2>/dev/null \
        || die "SSH to the Oracle VM failed through the tunnel" \
               "check the key matches the VM: ssh-keygen -y -f '${SSH_KEY}'
       and that the VM is running: az vm get-instance-view -g '${RG}' -n '${VM_NAME}' --query instanceView.statuses"
    ok "SSH to ${SSH_USER}@${VM_NAME} works"

    # Same reasoning as the --local branch: this sqlplus also runs inside the
    # container (over SSH), so it reaches the container's 1521, not the host's.
    ORACLE_TARGET_HOST='localhost'
    ORACLE_TARGET_PORT='1521'
    exec_sqlplus() {
        # shellcheck disable=SC2029  # $CONTAINER is meant to expand locally; printf %q quotes it for the remote shell
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" \
            "docker exec -i $(printf '%q' "$CONTAINER") sqlplus -S -L /nolog"
    }
fi

# --------------------------------------------------------------------------
# SQL*Plus preamble
#
# Fed on stdin so no password reaches argv. DEFINEs give the .sql files a way
# to reference credentials without hardcoding them, which the public-repo rule
# requires: 00-schema-setup.sql can say
#     CREATE USER &contoso_schema IDENTIFIED BY "&contoso_password";
#
# ORACLE_TARGET_HOST / ORACLE_TARGET_PORT are the address as seen from WHERE
# sqlplus actually runs - inside the container, on both targets - so they are
# always localhost:1521. They are deliberately NOT ORACLE_HOST/ORACLE_PORT,
# which describe the host-side publish mapping (docker run -p 1523:1521) and
# mean nothing to a process inside the container. &oracle_host and &oracle_port
# hand that same pair to the SQL so the two can never disagree.
# --------------------------------------------------------------------------
preamble() {
    local user="$1" pw="$2" as_system="${3:-0}"
    cat <<PRE
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING ON
SET VERIFY OFF
SET TAB OFF
SET TRIMSPOOL ON
SET TRIMOUT ON
SET LINESIZE 200
SET PAGESIZE 5000
SET LONG 200000
SET LONGCHUNKSIZE 200000
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET SQLBLANKLINES ON
CONNECT ${user}/"${pw}"@${ORACLE_TARGET_HOST}:${ORACLE_TARGET_PORT}/${ORACLE_SERVICE}
DEFINE contoso_schema = "${CONTOSO_SCHEMA}"
DEFINE contoso_password = "${CONTOSO_PW}"
DEFINE oracle_service = "${ORACLE_SERVICE}"
DEFINE oracle_host = "${ORACLE_TARGET_HOST}"
DEFINE oracle_port = "${ORACLE_TARGET_PORT}"
DEFINE migration_user = "${ORACLE_MIGRATION_USER}"
DEFINE migration_password = "${READER_PW}"
DEFINE utl_file_dir_name = "${ORACLE_UTL_FILE_DIR_NAME:-CONTOSO_EXPORT_DIR}"
DEFINE scale = "${SCALE}"
DEFINE order_rows = "${SEED_ORDER_ROWS:-250000}"
DEFINE customer_rows = "${SEED_CUSTOMER_ROWS:-50000}"
PRE
    # The SYSTEM credentials are only handed to the file that has to create the
    # CONTOSO user. Everything else runs as CONTOSO and never sees them.
    #
    # DEFINE 1 supplies the first positional SQL*Plus parameter that
    # src/oracle/00-user-tablespace.sql expects: its line 25 does
    # `DEFINE contoso_password = '&1'`. That contract is written for a standalone
    # `sqlplus @00-user-tablespace.sql "$pw"` run. We feed files on stdin, not
    # with @, so there is no positional &1 -- sqlplus would prompt for it, read an
    # empty line, and CREATE USER with a zero-length password (ORA-01741, seen on
    # a clean CI runner). Emitting &1 as a DEFINE here closes that gap and leaves
    # the .sql file and its documented positional-arg contract untouched.
    if [[ "$as_system" == "1" ]]; then
        cat <<PRE
DEFINE system_user = "${ORACLE_SYSTEM_USER}"
DEFINE system_password = "${SYSTEM_PW}"
DEFINE cdb_service = "${ORACLE_CDB_SERVICE:-FREE}"
DEFINE 1 = "${CONTOSO_PW}"
PRE
    fi
}

# Only 00-* runs as SYSTEM: it is the file that creates the CONTOSO user, so it
# cannot connect as CONTOSO. src/oracle/00-user-tablespace.sql grants CONTOSO
# everything the later files need (CREATE ANY CONTEXT, EXECUTE ON DBMS_RLS,
# CREATE ANY DIRECTORY), so 12-security-context.sql runs as CONTOSO like the
# rest. Override with SEED_SYSTEM_FILES if your 00-* does not do those grants.
runs_as_system() {
    # shellcheck disable=SC2254  # the glob is supposed to be a pattern
    case "$(basename "$1")" in ${SEED_SYSTEM_FILES:-00-*}) return 0 ;; *) return 1 ;; esac
}

# EXECUTE ON SYS.DBMS_RLS can only be granted by SYS. O7_DICTIONARY_ACCESSIBILITY
# is FALSE on a stock image, so GRANT ANY OBJECT PRIVILEGE -- which SYSTEM holds
# via DBA -- does not reach SYS-owned objects, and granting through a role is no
# help either because roles are disabled inside definer's-rights PL/SQL, which is
# exactly where pkg_vpd_policy needs it. 00-* warns and carries on when it cannot
# make the grant; this closes the gap over OS authentication inside the container,
# where "/ AS SYSDBA" needs no password.
#
# Deliberately best-effort. Losing the VPD hard case (H-40) is a much better
# outcome than refusing to seed the schema, so a failure here is a skip, not a
# build failure. Must run AFTER 00-*, which drops and recreates CONTOSO.
grant_dbms_rls() {
    local log="${RUN_LOG_DIR}/000-sysdba-dbms-rls.log" rc=0
    printf '  %-4s %-44s ' '--' 'grant execute on sys.dbms_rls (as sysdba)'
    exec_sqlplus > "$log" 2>&1 <<SYSDBA || rc=$?
WHENEVER SQLERROR EXIT FAILURE
CONNECT / AS SYSDBA
ALTER SESSION SET CONTAINER = ${ORACLE_SERVICE};
GRANT EXECUTE ON sys.dbms_rls TO ${CONTOSO_SCHEMA};
EXIT SUCCESS
SYSDBA
    if [[ "$rc" -eq 0 ]] && ! grep -qE '^(ORA-|PLS-)[0-9]' "$log" 2>/dev/null; then
        printf '%10s  %sok%s\n' '-' "$C_GREEN" "$C_RESET"
    else
        printf '%10s  %sskip%s\n' '-' "$C_YELLOW" "$C_RESET"
        printf '       %sVPD (H-40) will degrade to a warning in 12-security-context.sql;%s\n' "$C_DIM" "$C_RESET"
        printf '       %ssee %s%s\n' "$C_DIM" "${log#"$REPO_ROOT"/}" "$C_RESET"
    fi
}

# Harmless SP2- messages that are not failures.
SP2_IGNORE='SP2-0640|SP2-0641|SP2-0851'

mkdir -p "$LOG_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG_DIR="${LOG_DIR}/seed-${RUN_ID}"
mkdir -p "$RUN_LOG_DIR"

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
hdr "Loading ${TOTAL} file(s)"
printf '  %s%-4s %-44s %10s  %s%s\n' "$C_BOLD" "#" "FILE" "TIME" "RESULT" "$C_RESET"
printf '  %s\n' "---- -------------------------------------------- ----------  ------"

IDX=0
FAILED=0
FAILED_FILES=''
RUN_T0="$(now_ms)"

for F in ${FILES[@]+"${FILES[@]}"}; do
    IDX=$(( IDX + 1 ))
    BASE="$(basename "$F")"
    REL="${F#"$REPO_ROOT"/}"
    FLOG="${RUN_LOG_DIR}/$(printf '%03d' "$IDX")-${BASE}.log"

    if runs_as_system "$F"; then RUN_USER="$ORACLE_SYSTEM_USER"; RUN_PW="$SYSTEM_PW"; AS_SYS=1
    else                          RUN_USER="$CONTOSO_SCHEMA";     RUN_PW="$CONTOSO_PW"; AS_SYS=0; fi

    printf '  %-4s %-44s ' "$IDX" "$(printf '%.44s' "$REL")"

    T0="$(now_ms)"
    RC=0
    { preamble "$RUN_USER" "$RUN_PW" "$AS_SYS"; cat "$F"; printf '\nEXIT SUCCESS\n'; } \
        | exec_sqlplus > "$FLOG" 2>&1 || RC=$?
    MS=$(( $(now_ms) - T0 ))

    # sqlplus exits 0 even when a package body compiles with errors, so the
    # log has to be read as well as the exit status. This is the single most
    # common way an Oracle build "succeeds" while leaving invalid objects.
    HARD_ERR=''
    if [[ "$RC" -ne 0 ]]; then
        HARD_ERR="sqlplus exit ${RC}"
    elif grep -qE '^(ORA-|PLS-)[0-9]' "$FLOG" 2>/dev/null; then
        HARD_ERR="$(grep -m1 -E '^(ORA-|PLS-)[0-9]' "$FLOG" | cut -c1-70)"
    elif grep -qE '^SP2-' "$FLOG" 2>/dev/null && ! grep -qE "$SP2_IGNORE" "$FLOG" 2>/dev/null; then
        HARD_ERR="$(grep -m1 -E '^SP2-[0-9]' "$FLOG" | cut -c1-70)"
    elif grep -qiE 'created with compilation errors' "$FLOG" 2>/dev/null; then
        HARD_ERR='object created with compilation errors'
    fi

    if [[ -z "$HARD_ERR" ]]; then
        printf '%10s  %sok%s\n' "$(fmt_ms "$MS")" "$C_GREEN" "$C_RESET"
        # The one grant 00-* cannot make for itself, made straight after it.
        if runs_as_system "$F"; then grant_dbms_rls; fi
    else
        printf '%10s  %sFAIL%s\n' "$(fmt_ms "$MS")" "$C_RED" "$C_RESET"
        printf '       %s%s%s\n' "$C_RED" "$HARD_ERR" "$C_RESET"
        FAILED=$(( FAILED + 1 ))
        FAILED_FILES="${FAILED_FILES}${REL} "
        if [[ "$CONTINUE_ON_ERROR" -eq 0 ]]; then
            printf '\n'
            printf '  %sLast 25 lines of %s:%s\n' "$C_DIM" "${FLOG#"$REPO_ROOT"/}" "$C_RESET"
            tail -25 "$FLOG" 2>/dev/null | sed 's/^/    /'
            die "stopped at ${REL}" \
                "read ${FLOG#"$REPO_ROOT"/} in full, fix the SQL, then resume without redoing the
       earlier files:  ${SCRIPT_NAME} --${TARGET} --from ${BASE}"
        fi
    fi
done

RUN_MS=$(( $(now_ms) - RUN_T0 ))
printf '\n  %d file(s) in %s\n' "$TOTAL" "$(fmt_ms "$RUN_MS")"

# --------------------------------------------------------------------------
# Report: object count, invalid objects, row counts
# --------------------------------------------------------------------------
hdr "Verification"
REPORT_LOG="${RUN_LOG_DIR}/999-report.log"
REPORT_RC=0
{
    preamble "$CONTOSO_SCHEMA" "$CONTOSO_PW"
    # The PROMPT banners below must NOT end in '----'. A trailing hyphen is
    # SQL*Plus's line-continuation character, so `PROMPT ... ----` swallows the
    # next input line -- the SELECT that prints TOTAL_OBJECTS, or the BEGIN of the
    # stats block -- leaving FROM/DBMS_STATS as orphan commands (SP2-0734 on a
    # clean 23ai runner) and the seed exits with "the report query did not run".
    cat <<'REPORT'
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT ---- recompiling the schema before counting
-- Loading ~25 files in dependency order still leaves a handful of objects
-- INVALID, and they are not broken: a trigger created with FOLLOWS, or a body
-- whose dependency was replaced later in the load, is marked invalid until
-- something touches it. Oracle would revalidate them on first use anyway.
--
-- Without this pass the seed reports a small non-zero invalid count on a
-- perfectly good build, which trains the reader to ignore that number - and
-- that number is exactly what docs/05-validate.md tells them to trust before
-- converting. Recompile first, then count, so a non-zero result afterwards
-- means something is genuinely wrong.
BEGIN
  DBMS_UTILITY.COMPILE_SCHEMA(USER, compile_all => FALSE);
END;
/
PROMPT
PROMPT ---- object count (the contract's counting rule)
SELECT 'TOTAL_OBJECTS=' || COUNT(*)
  FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION');
PROMPT
PROMPT ---- by type
SET HEADING ON
COLUMN object_type FORMAT A24
COLUMN generated   FORMAT 999999
COLUMN handwritten FORMAT 999999
COLUMN total       FORMAT 999999
SELECT object_type,
       SUM(CASE WHEN LOWER(object_name) LIKE '%gen\_%' ESCAPE '\' THEN 1 ELSE 0 END) AS generated,
       SUM(CASE WHEN LOWER(object_name) LIKE '%gen\_%' ESCAPE '\' THEN 0 ELSE 1 END) AS handwritten,
       COUNT(*) AS total
  FROM user_objects
 WHERE object_type NOT IN ('LOB','TABLE PARTITION','INDEX PARTITION','LOB PARTITION')
 GROUP BY object_type
 ORDER BY total DESC, object_type;
SET HEADING OFF
PROMPT
PROMPT ---- invalid objects
SELECT 'INVALID_OBJECTS=' || COUNT(*) FROM user_objects WHERE status = 'INVALID';
SET HEADING ON
COLUMN object_name FORMAT A40
SELECT object_type, object_name
  FROM user_objects
 WHERE status = 'INVALID'
 ORDER BY object_type, object_name
 FETCH FIRST 20 ROWS ONLY;
SET HEADING OFF
PROMPT
PROMPT ---- row counts
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname          => USER,
                                 estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                 cascade          => TRUE,
                                 no_invalidate    => FALSE);
END;
/
SET HEADING ON
COLUMN table_name FORMAT A34
COLUMN num_rows   FORMAT 999,999,999
SELECT table_name, num_rows
  FROM user_tables
 WHERE num_rows > 0
 ORDER BY num_rows DESC, table_name
 FETCH FIRST 25 ROWS ONLY;
SET HEADING OFF
SELECT 'TOTAL_ROWS=' || TO_CHAR(NVL(SUM(num_rows),0)) FROM user_tables;
EXIT SUCCESS
REPORT
} | exec_sqlplus > "$REPORT_LOG" 2>&1 || REPORT_RC=$?

if [[ "$REPORT_RC" -ne 0 ]] && [[ ! -s "$REPORT_LOG" ]]; then
    warn "could not produce the verification report (sqlplus exit ${REPORT_RC})"
    note "see ${REPORT_LOG#"$REPO_ROOT"/}"
else
    sed 's/^/  /' "$REPORT_LOG" | grep -v '^  *$' || true
fi

OBJ_COUNT="$(grep -oE 'TOTAL_OBJECTS=[0-9]+' "$REPORT_LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
INVALID="$(grep -oE 'INVALID_OBJECTS=[0-9]+'  "$REPORT_LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
FLOOR="${OBJECT_COUNT_FLOOR:-1000}"

hdr "Summary"
printf '  %-22s %s\n' "files run"       "$TOTAL"
printf '  %-22s %s\n' "files failed"    "$FAILED"
printf '  %-22s %s\n' "elapsed"         "$(fmt_ms "$RUN_MS")"
printf '  %-22s %s\n' "logs"            "${RUN_LOG_DIR#"$REPO_ROOT"/}"

EXIT_CODE=0
if [[ -n "$OBJ_COUNT" ]]; then
    if [[ "$OBJ_COUNT" -ge "$FLOOR" ]]; then
        printf '  %-22s %s%s%s (floor %s)\n' "objects in ${CONTOSO_SCHEMA}" "$C_GREEN" "$OBJ_COUNT" "$C_RESET" "$FLOOR"
    else
        printf '  %-22s %s%s%s (floor %s - SHORT)\n' "objects in ${CONTOSO_SCHEMA}" "$C_RED" "$OBJ_COUNT" "$C_RESET" "$FLOOR"
        EXIT_CODE=1
    fi
else
    printf '  %-22s %s\n' "objects" "unknown - the report query did not run"
    EXIT_CODE=1
fi

if [[ -n "$INVALID" && "$INVALID" != "0" ]]; then
    printf '  %-22s %s%s%s\n' "invalid objects" "$C_RED" "$INVALID" "$C_RESET"
    EXIT_CODE=1
fi

if [[ "$FAILED" -gt 0 ]]; then
    printf '\n%s%s%d file(s) failed:%s %s\n' "$C_BOLD" "$C_RED" "$FAILED" "$C_RESET" "$FAILED_FILES"
    printf 'fix: read the per-file logs in %s, then re-run with --from <first failing file>\n' \
        "${RUN_LOG_DIR#"$REPO_ROOT"/}"
    exit 1
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
    printf '\n%s%sSchema loaded, but verification failed.%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf 'fix: %s\n' "recompile invalid objects with
       scripts/connect.sh ${TARGET/local/oracle-local}  then:  EXEC UTL_RECOMP.RECOMP_SERIAL('${CONTOSO_SCHEMA}');
     and read ${REPORT_LOG#"$REPO_ROOT"/} for which objects are short or invalid"
    exit 1
fi

printf '\n%s%sCONTOSO is loaded and verified.%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
printf 'Next: scripts/connect.sh %s\n\n' "$( [[ "$TARGET" == "local" ]] && echo 'oracle-local' || echo 'oracle-azure' )"
