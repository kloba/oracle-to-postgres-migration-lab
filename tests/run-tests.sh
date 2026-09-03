#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# run-tests.sh - the test harness for the Contoso Store migration lab.
#
# Two kinds of check:
#
#   STATIC     Need nothing but the repo and a few CLI tools. These are what
#              .github/workflows/ci.yml runs on every push and pull request,
#              with no Azure credentials and no database.
#                bash -n            every shell script parses
#                lint               every shell script is shellcheck-clean
#                exec bits          every shell script is executable
#                az bicep build     every template and parameter file compiles
#                py_compile         every generator compiles
#                determinism        the generator is byte-identical across runs
#                markdown links     every relative link resolves
#                secret scan        no real subscription or tenant ids
#
#   ORACLE     Need a loaded CONTOSO schema. Chosen with --local or --azure,
#              exactly as scripts/seed-oracle.sh does.
#                tests/verify-schema.sql   structure, object budget, validity
#                tests/verify-counts.sql   row counts and referential integrity
#
# With no target flag only the static checks run, so `tests/run-tests.sh` is
# always safe to type.
#
# Exits non-zero if any check fails. SKIPped checks do not fail the run unless
# --strict is given, which is what CI uses.
#
# Part of the Contoso Store Oracle -> Azure Database for PostgreSQL lab.
# See docs/design.md - that document is the binding contract.
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
info() { printf '  %s[ .. ]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  {
    printf '\n%s%s%s failed:%s %s\n' "$C_BOLD" "$C_RED" "$SCRIPT_NAME" "$C_RESET" "$1" >&2
    [[ -n "${2:-}" ]] && printf '%sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2" >&2
    exit 2
}
have() { command -v "$1" >/dev/null 2>&1; }

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
SCALE_EXPLICIT=0
STRICT=0
ONLY_PATTERN=''
LIST_ONLY=0
VERBOSE="${VERBOSE:-0}"

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - run the lab's tests.

${C_BOLD}USAGE${C_RESET}
    ${SCRIPT_NAME}                     static checks only
    ${SCRIPT_NAME} --local  [options]  static checks + Oracle in Docker
    ${SCRIPT_NAME} --azure  [options]  static checks + the Oracle VM in Azure

${C_BOLD}TARGET${C_RESET}
    --local              Run the SQL tests against the Docker container named
                         by \$ORACLE_CONTAINER_NAME (default o2p-oracle).
    --azure              Run them against the Oracle VM, over SSH through an
                         'az network bastion tunnel'. Needs generated/outputs.json
                         from a successful scripts/deploy.sh.
    (neither)            Static checks only. No .env and no database needed.

${C_BOLD}OPTIONS${C_RESET}
    --scale <n>          Row-count multiplier the SQL tests expect, matching
                         the --scale you seeded with. If omitted, it is
                         auto-detected from the loaded data (verify-counts only).
                         0.01 = the CI smoke scale.
    --only <glob>        Run only checks whose name matches, e.g.
                         --only 'bicep' or --only '*lint*'.
    --strict             Treat SKIP as FAIL. Use in CI, where every tool is
                         installed on purpose and a silent skip is a lie.
    --list               List the checks that would run, then exit.
    -h, --help           Show this help and exit.

${C_BOLD}EXIT STATUS${C_RESET}
    0  every check passed
    1  at least one check failed
    2  the harness could not run at all

${C_BOLD}ENVIRONMENT${C_RESET}
    VERBOSE=1            Show each check's full output, not just failures.
    NO_COLOR=1           Disable colour.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)    TARGET='local'; shift ;;
        --azure)    TARGET='azure'; shift ;;
        --scale)    SCALE="${2:-}"; [[ -n "$SCALE" ]] || die "--scale needs a value"; SCALE_EXPLICIT=1; shift 2 ;;
        --scale=*)  SCALE="${1#*=}"; SCALE_EXPLICIT=1; shift ;;
        --only)     ONLY_PATTERN="${2:-}"; [[ -n "$ONLY_PATTERN" ]] || die "--only needs a value"; shift 2 ;;
        --only=*)   ONLY_PATTERN="${1#*=}"; shift ;;
        --strict)   STRICT=1; shift ;;
        --list)     LIST_ONLY=1; shift ;;
        --verbose)  VERBOSE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf '%sunknown option: %s%s\n\n' "$C_RED" "$1" "$C_RESET" >&2; usage >&2; exit 2 ;;
    esac
done

SCALE="${SCALE:-1}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG_DIR="${LOG_DIR}/tests-${RUN_ID}"

# --------------------------------------------------------------------------
# Result accounting
#
# Parallel arrays rather than an associative array: bash 3.2 still ships as
# /bin/bash on macOS and has no `declare -A`.
# --------------------------------------------------------------------------
R_NAME=(); R_STATUS=(); R_DETAIL=(); R_MS=()
N_PASS=0; N_FAIL=0; N_SKIP=0

record() {
    local name="$1" status="$2" detail="$3" ms="$4"
    R_NAME+=("$name"); R_STATUS+=("$status"); R_DETAIL+=("$detail"); R_MS+=("$ms")
    case "$status" in
        PASS) N_PASS=$(( N_PASS + 1 ));
              printf '  %s[ PASS ]%s %-26s %10s  %s\n' "$C_GREEN" "$C_RESET" "$name" "$(fmt_ms "$ms")" "$detail" ;;
        FAIL) N_FAIL=$(( N_FAIL + 1 ));
              printf '  %s[ FAIL ]%s %-26s %10s  %s\n' "$C_RED" "$C_RESET" "$name" "$(fmt_ms "$ms")" "$detail" ;;
        SKIP) N_SKIP=$(( N_SKIP + 1 ));
              printf '  %s[ SKIP ]%s %-26s %10s  %s\n' "$C_YELLOW" "$C_RESET" "$name" "$(fmt_ms "$ms")" "$detail" ;;
    esac
}

# selected <check-name> - honour --only
selected() {
    [[ -z "$ONLY_PATTERN" ]] && return 0
    # shellcheck disable=SC2254  # the glob is meant to be a pattern
    case "$1" in $ONLY_PATTERN) return 0 ;; *) return 1 ;; esac
}

# show_log <file> [lines] - print the tail of a check's log, indented
show_log() {
    local f="$1" n="${2:-30}"
    [[ -s "$f" ]] || return 0
    printf '         %s---- %s ----%s\n' "$C_DIM" "${f#"$REPO_ROOT"/}" "$C_RESET"
    tail -n "$n" "$f" | sed 's/^/         /'
}

# --------------------------------------------------------------------------
# File discovery. Everything the checks operate on is found once, here, so
# that adding a script or a template needs no edit to this file.
#
# generated/ and out/ are gitignored build output and are never checked.
# --------------------------------------------------------------------------
find_repo_files() {
    find "$REPO_ROOT" \
        \( -path "${REPO_ROOT}/.git" \
        -o -path "${REPO_ROOT}/generated" \
        -o -path "${REPO_ROOT}/out" \
        -o -path "${REPO_ROOT}/node_modules" \
        -o -name '__pycache__' \) -prune -o \
        -type f "$@" -print 2>/dev/null | LC_ALL=C sort
}

SH_FILES=(); PY_FILES=(); MD_FILES=(); BICEP_FILES=(); BICEPPARAM_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && SH_FILES+=("$f");         done < <(find_repo_files -name '*.sh')
while IFS= read -r f; do [[ -n "$f" ]] && PY_FILES+=("$f");         done < <(find_repo_files -name '*.py')
while IFS= read -r f; do [[ -n "$f" ]] && MD_FILES+=("$f");         done < <(find_repo_files -name '*.md')
while IFS= read -r f; do [[ -n "$f" ]] && BICEP_FILES+=("$f");      done < <(find_repo_files -name '*.bicep')
while IFS= read -r f; do [[ -n "$f" ]] && BICEPPARAM_FILES+=("$f"); done < <(find_repo_files -name '*.bicepparam')

CHECKS=(bash-syntax shellcheck exec-bits bicep-build python-compile
        generator-determinism cloud-init-sync markdown-links secret-scan)
[[ -n "$TARGET" ]] && CHECKS+=(verify-schema verify-counts)

if [[ "$LIST_ONLY" -eq 1 ]]; then
    printf '%sChecks that would run%s\n' "$C_BOLD" "$C_RESET"
    for c in "${CHECKS[@]}"; do selected "$c" && printf '  %s\n' "$c"; done
    exit 0
fi

mkdir -p "$RUN_LOG_DIR"

printf '\n%s%sContoso Store migration lab - test harness%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
printf '  %-14s %s\n' "repo"   "$REPO_ROOT"
printf '  %-14s %s\n' "target" "${TARGET:-static checks only}"
SCALE_BANNER="$SCALE"
[[ -n "$TARGET" && "$SCALE_EXPLICIT" -eq 0 ]] && SCALE_BANNER="${SCALE} (auto-detect from the loaded data)"
printf '  %-14s %s\n' "scale"  "$SCALE_BANNER"
printf '  %-14s %s\n' "logs"   "${RUN_LOG_DIR#"$REPO_ROOT"/}"

# ==========================================================================
# STATIC CHECKS
# ==========================================================================
hdr "Static checks"

# --------------------------------------------------------------------------
# bash -n on every shell script
# --------------------------------------------------------------------------
if selected bash-syntax; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/bash-syntax.log"; BAD=0
    : > "$LOG"
    for f in ${SH_FILES[@]+"${SH_FILES[@]}"}; do
        if ! bash -n "$f" >>"$LOG" 2>&1; then
            BAD=$(( BAD + 1 )); printf 'FAILED: %s\n' "${f#"$REPO_ROOT"/}" >> "$LOG"
        fi
    done
    MS=$(( $(now_ms) - T0 ))
    if [[ "$BAD" -eq 0 ]]; then
        record bash-syntax PASS "${#SH_FILES[@]} script(s) parse" "$MS"
    else
        record bash-syntax FAIL "${BAD} script(s) do not parse" "$MS"; show_log "$LOG"
    fi
fi

# --------------------------------------------------------------------------
# Lint every shell script.
#
# Severity is `warning` by default: errors and warnings are real defects,
# while `info` and `style` findings are largely taste (SC2086 on a variable
# that cannot contain whitespace, SC2015's A && B || C note). --strict raises
# it to `style` for anyone who wants the pedantic pass.
#
# SC1091 is always excluded. It fires because shellcheck cannot follow
# `. "$ENV_FILE"` or `. /etc/os-release`, neither of which exists at lint
# time by design.
# --------------------------------------------------------------------------
if selected shellcheck; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/shellcheck.log"
    if ! have shellcheck; then
        record shellcheck SKIP "shellcheck not installed (brew install shellcheck)" "$(( $(now_ms) - T0 ))"
    else
        RC=0
        SC_SEVERITY='warning'
        [[ "$STRICT" -eq 1 ]] && SC_SEVERITY='style'
        shellcheck --severity="$SC_SEVERITY" --shell=bash --external-sources \
            --exclude=SC1091 \
            ${SH_FILES[@]+"${SH_FILES[@]}"} > "$LOG" 2>&1 || RC=$?
        MS=$(( $(now_ms) - T0 ))
        if [[ "$RC" -eq 0 ]]; then
            record shellcheck PASS "${#SH_FILES[@]} clean at severity=${SC_SEVERITY}" "$MS"
        else
            record shellcheck FAIL "$(grep -c '^In ' "$LOG" 2>/dev/null || echo '?') finding(s)" "$MS"
            show_log "$LOG" 40
        fi
    fi
fi

# --------------------------------------------------------------------------
# Executable bits. docs/design.md section 2 requires them, and a script that
# is not executable fails only when someone tries to run it from a doc.
# --------------------------------------------------------------------------
if selected exec-bits; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/exec-bits.log"; BAD=0
    : > "$LOG"
    for f in ${SH_FILES[@]+"${SH_FILES[@]}"}; do
        if [[ ! -x "$f" ]]; then
            BAD=$(( BAD + 1 ))
            printf 'not executable: %s   (chmod +x %s)\n' \
                "${f#"$REPO_ROOT"/}" "${f#"$REPO_ROOT"/}" >> "$LOG"
        fi
    done
    MS=$(( $(now_ms) - T0 ))
    if [[ "$BAD" -eq 0 ]]; then
        record exec-bits PASS "${#SH_FILES[@]} script(s) executable" "$MS"
    else
        record exec-bits FAIL "${BAD} script(s) not executable" "$MS"; show_log "$LOG"
    fi
fi

# --------------------------------------------------------------------------
# Bicep. `az bicep build` compiles a template and everything it modules in,
# so building infra/main.bicep covers infra/modules/ transitively -- but we
# build each file anyway, because a module with an error that main.bicep does
# not reference should still fail the build.
#
# .bicepparam files are compiled with build-params, which also type-checks
# them against the template in their `using` clause.
# --------------------------------------------------------------------------
if selected bicep-build; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/bicep-build.log"
    : > "$LOG"
    if [[ "${#BICEP_FILES[@]}" -eq 0 ]]; then
        record bicep-build SKIP "no .bicep files found" "$(( $(now_ms) - T0 ))"
    elif ! have az; then
        record bicep-build SKIP "az CLI not installed" "$(( $(now_ms) - T0 ))"
    elif ! az bicep version >>"$LOG" 2>&1; then
        record bicep-build SKIP "bicep not installed (az bicep install)" "$(( $(now_ms) - T0 ))"
        show_log "$LOG" 5
    else
        BAD=0
        for f in "${BICEP_FILES[@]}"; do
            printf '\n--- az bicep build %s\n' "${f#"$REPO_ROOT"/}" >> "$LOG"
            if ! az bicep build --file "$f" --stdout >/dev/null 2>>"$LOG"; then
                BAD=$(( BAD + 1 )); printf 'FAILED: %s\n' "${f#"$REPO_ROOT"/}" >> "$LOG"
            fi
        done
        for f in ${BICEPPARAM_FILES[@]+"${BICEPPARAM_FILES[@]}"}; do
            printf '\n--- az bicep build-params %s\n' "${f#"$REPO_ROOT"/}" >> "$LOG"
            # build-params evaluates readEnvironmentVariable(), so a parameter
            # file that reads a required secret fails here unless the variable
            # is set. That is a real finding, not harness noise: the reader
            # hits exactly the same error at deploy time.
            if ! az bicep build-params --file "$f" --stdout >/dev/null 2>>"$LOG"; then
                BAD=$(( BAD + 1 )); printf 'FAILED: %s\n' "${f#"$REPO_ROOT"/}" >> "$LOG"
            fi
        done
        MS=$(( $(now_ms) - T0 ))
        TOTAL_BICEP=$(( ${#BICEP_FILES[@]} + ${#BICEPPARAM_FILES[@]} ))
        if [[ "$BAD" -eq 0 ]]; then
            record bicep-build PASS "${TOTAL_BICEP} template(s) compile" "$MS"
        else
            record bicep-build FAIL "${BAD} of ${TOTAL_BICEP} failed" "$MS"; show_log "$LOG" 40
        fi
        # Warnings do not fail the build, but they should be visible.
        if grep -q 'Warning ' "$LOG" 2>/dev/null; then
            note "$(grep -c 'Warning ' "$LOG") bicep warning(s) - see ${LOG#"$REPO_ROOT"/}"
        fi
    fi
fi

# --------------------------------------------------------------------------
# python3 -m py_compile on the generators
# --------------------------------------------------------------------------
if selected python-compile; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/python-compile.log"
    if [[ "${#PY_FILES[@]}" -eq 0 ]]; then
        record python-compile SKIP "no .py files found" "$(( $(now_ms) - T0 ))"
    elif ! have python3; then
        record python-compile SKIP "python3 not installed" "$(( $(now_ms) - T0 ))"
    else
        RC=0
        # PYTHONPYCACHEPREFIX keeps __pycache__ out of the working tree.
        PYTHONPYCACHEPREFIX="${RUN_LOG_DIR}/pycache" \
            python3 -m py_compile "${PY_FILES[@]}" > "$LOG" 2>&1 || RC=$?
        MS=$(( $(now_ms) - T0 ))
        if [[ "$RC" -eq 0 ]]; then
            record python-compile PASS "${#PY_FILES[@]} file(s) compile" "$MS"
        else
            record python-compile FAIL "compile error" "$MS"; show_log "$LOG" 30
        fi
    fi
fi

# --------------------------------------------------------------------------
# Generator determinism.
#
# docs/design.md section 7: "Two runs on two machines must produce
# byte-identical output - the lab diffs conversion results across runs, so
# drift is fatal." Two runs on ONE machine with the same seed is the weakest
# useful form of that, and it catches the common causes: dict iteration
# order, PYTHONHASHSEED, set iteration, time or locale leaking into output.
#
# PYTHONHASHSEED is deliberately DIFFERENT between the two runs. Identical
# output with identical hash seeds would prove almost nothing.
#
# The generator's flags are probed rather than assumed: tools/ has a
# different author, and failing on an unknown flag would be a worse
# experience than adapting to it. scripts/seed-oracle.sh does the same.
# --------------------------------------------------------------------------
if selected generator-determinism; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/generator-determinism.log"
    GENERATOR="${REPO_ROOT}/tools/generate-objects.py"
    : > "$LOG"
    if ! have python3; then
        record generator-determinism SKIP "python3 not installed" "$(( $(now_ms) - T0 ))"
    elif [[ ! -f "$GENERATOR" ]]; then
        record generator-determinism SKIP "tools/generate-objects.py not present" "$(( $(now_ms) - T0 ))"
    else
        GEN_HELP="$(python3 "$GENERATOR" --help 2>&1 || true)"
        if [[ -z "${GEN_HELP//[[:space:]]/}" ]]; then
            # No argparse yet: the generator is still being written. Not a
            # pass -- there is nothing to be determinate about.
            record generator-determinism SKIP "generator exposes no CLI yet" "$(( $(now_ms) - T0 ))"
        else
            gen_supports() { printf '%s' "$GEN_HELP" | grep -qe "$1"; }
            D1="${RUN_LOG_DIR}/gen-run-1"; D2="${RUN_LOG_DIR}/gen-run-2"
            rm -rf "$D1" "$D2"; mkdir -p "$D1" "$D2"

            GEN_BASE=()
            gen_supports '\-\-seed' && GEN_BASE+=(--seed "${GEN_SEED:-20260902}")

            gen_run() {   # gen_run <outdir> <hashseed>
                local outdir="$1" hashseed="$2"
                local args=()
                args=(${GEN_BASE[@]+"${GEN_BASE[@]}"})
                if   gen_supports '\-\-out\b';      then args+=(--out "$outdir")
                elif gen_supports '\-\-output-dir'; then args+=(--output-dir "$outdir")
                else return 3   # nowhere to send the output; cannot compare
                fi
                PYTHONHASHSEED="$hashseed" python3 "$GENERATOR" \
                    ${args[@]+"${args[@]}"} >>"$LOG" 2>&1
            }

            RC=0
            gen_run "$D1" 0 || RC=$?
            [[ "$RC" -eq 0 ]] && { gen_run "$D2" 12345 || RC=$?; }
            MS=$(( $(now_ms) - T0 ))

            N1="$(find "$D1" -type f 2>/dev/null | wc -l | tr -d ' ')"

            if [[ "$RC" -eq 3 ]]; then
                record generator-determinism SKIP "generator has no --out flag" "$MS"
            elif [[ "$RC" -ne 0 ]]; then
                record generator-determinism FAIL "generator exited ${RC}" "$MS"; show_log "$LOG" 30
            elif [[ "$N1" -eq 0 ]]; then
                record generator-determinism FAIL "generator wrote no files" "$MS"; show_log "$LOG" 30
            elif diff -r "$D1" "$D2" >>"$LOG" 2>&1; then
                record generator-determinism PASS "${N1} file(s) byte-identical" "$MS"
            else
                record generator-determinism FAIL "output differs between runs" "$MS"
                show_log "$LOG" 40
            fi
        fi
    fi
fi

# --------------------------------------------------------------------------
# Markdown relative-link check.
#
# Only relative links are followed. External URLs are not fetched: a test
# that needs the internet is a test that fails on a train, and docs/design.md
# section 11 deliberately names pages that 301-redirect.
# --------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# cloud-init-sync
#
# scripts/cloud-init/oracle-vm.yaml embeds a copy of scripts/install-oracle.sh,
# because the VM has no access to this repository at first boot. A hand-kept
# "byte-identical copy" is a promise nobody can keep: it had already drifted by
# 58 lines, so a real deployment ran a version of the installer that was fixed
# in the repo weeks earlier. Nothing caught it because nothing compared them.
#
# Re-sync with:  python3 tools/sync-cloud-init.py
# ---------------------------------------------------------------------------
if selected cloud-init-sync; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/cloud-init-sync.log"
    if python3 "${REPO_ROOT}/tools/sync-cloud-init.py" --check > "$LOG" 2>&1; then
        MS=$(( $(now_ms) - T0 ))
        record cloud-init-sync PASS "embedded installer matches scripts/install-oracle.sh" "$MS"
    else
        MS=$(( $(now_ms) - T0 ))
        record cloud-init-sync FAIL "embedded installer has drifted from scripts/install-oracle.sh" "$MS"
        show_log "$LOG"
    fi
fi

if selected markdown-links; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/markdown-links.log"
    if [[ "${#MD_FILES[@]}" -eq 0 ]]; then
        record markdown-links SKIP "no .md files found" "$(( $(now_ms) - T0 ))"
    elif ! have python3; then
        record markdown-links SKIP "python3 not installed" "$(( $(now_ms) - T0 ))"
    else
        RC=0
        python3 - "$REPO_ROOT" ${MD_FILES[@]+"${MD_FILES[@]}"} > "$LOG" 2>&1 <<'PYEOF' || RC=$?
import os
import re
import sys

repo_root = os.path.abspath(sys.argv[1])
md_files = sys.argv[2:]

# [text](target)  and  [text](target "title")
INLINE = re.compile(r'\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)>\s]+)>?(?:\s+"[^"]*")?\s*\)')
# [label]: target
REFDEF = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?([^>\s]+)>?', re.MULTILINE)
# Fenced code blocks: links inside them are examples, not navigation.
FENCE = re.compile(r'^(?P<fence>```+|~~~+).*?^(?P=fence)\s*$', re.MULTILINE | re.DOTALL)

SKIP_SCHEMES = ('http://', 'https://', 'mailto:', 'tel:', 'ftp://',
                'data:', 'javascript:', '//')

broken = 0
checked = 0

for path in md_files:
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except OSError as exc:
        print('cannot read %s: %s' % (path, exc))
        broken += 1
        continue

    # Blank out fenced blocks, preserving line numbers so the report is useful.
    text = FENCE.sub(lambda m: re.sub(r'[^\n]', ' ', m.group(0)), text)

    targets = [m.group(1) for m in INLINE.finditer(text)]
    targets += [m.group(1) for m in REFDEF.finditer(text)]

    base = os.path.dirname(os.path.abspath(path))
    rel_src = os.path.relpath(path, repo_root)

    for raw in targets:
        target = raw.strip()
        if not target or target.startswith('#'):
            continue                      # same-document anchor
        if target.lower().startswith(SKIP_SCHEMES):
            continue                      # external
        if target.startswith('<') and target.endswith('>'):
            target = target[1:-1]

        # Drop the anchor: we check that the file exists, not that the
        # heading does. Heading slugs differ between renderers.
        file_part = target.split('#', 1)[0]
        if not file_part:
            continue

        # Absolute repo paths are written as /docs/x.md by some authors.
        if file_part.startswith('/'):
            resolved = os.path.join(repo_root, file_part.lstrip('/'))
        else:
            resolved = os.path.join(base, file_part)

        checked += 1
        if not os.path.exists(resolved):
            broken += 1
            print('%s -> %s   (no such file: %s)'
                  % (rel_src, target, os.path.relpath(resolved, repo_root)))

print('checked %d relative link(s) in %d file(s), %d broken'
      % (checked, len(md_files), broken))
sys.exit(1 if broken else 0)
PYEOF
        MS=$(( $(now_ms) - T0 ))
        if [[ "$RC" -eq 0 ]]; then
            record markdown-links PASS "$(tail -1 "$LOG")" "$MS"
        else
            record markdown-links FAIL "$(tail -1 "$LOG")" "$MS"; show_log "$LOG" 40
        fi
    fi
fi

# --------------------------------------------------------------------------
# Secret scan.
#
# docs/design.md section 2: "Public repo: no real tenant IDs, subscription
# IDs, endpoints, or resource names anywhere." This catches the accident
# where someone pastes a working value into .env.example or a doc.
#
# Any GUID that is not the all-zero placeholder is reported. That is a blunt
# rule and it is meant to be: a false positive costs one line of explanation,
# a false negative costs a public subscription id.
# --------------------------------------------------------------------------
if selected secret-scan; then
    T0="$(now_ms)"; LOG="${RUN_LOG_DIR}/secret-scan.log"
    : > "$LOG"
    BAD=0

    # Real-looking GUIDs, excluding the 00000000-... placeholder and the
    # well-known Azure built-in role definition ids that Bicep templates must
    # reference by GUID.
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        printf 'possible real GUID: %s\n' "$hit" >> "$LOG"
        BAD=$(( BAD + 1 ))
    done < <(
        find_repo_files \( -name '*.md' -o -name '*.sh' -o -name '*.example' \
                        -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' \) \
        | while IFS= read -r f; do
            grep -oniE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$f" 2>/dev/null \
            | grep -viE '00000000-0000-0000-0000-000000000000' \
            | while IFS= read -r m; do printf '%s:%s\n' "${f#"$REPO_ROOT"/}" "$m"; done
          done
    )

    # A committed .env is the other way this goes wrong.
    if [[ -f "${REPO_ROOT}/.env" ]] && git -C "$REPO_ROOT" ls-files --error-unmatch .env >/dev/null 2>&1; then
        printf '.env is tracked by git. It must be gitignored.\n' >> "$LOG"
        BAD=$(( BAD + 1 ))
    fi

    MS=$(( $(now_ms) - T0 ))
    if [[ "$BAD" -eq 0 ]]; then
        record secret-scan PASS "no real GUIDs or tracked .env" "$MS"
    else
        record secret-scan FAIL "${BAD} finding(s)" "$MS"; show_log "$LOG" 30
    fi
fi

# ==========================================================================
# ORACLE CHECKS
# ==========================================================================
TUNNEL_PID=''
cleanup() {
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [[ -n "$TARGET" ]]; then
    hdr "Oracle checks (${TARGET})"

    ENV_FILE="${REPO_ROOT}/.env"
    [[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}" \
        "cp '${REPO_ROOT}/.env.example' '${ENV_FILE}' && chmod 600 '${ENV_FILE}'"
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a

    ORACLE_SERVICE="${ORACLE_SERVICE:-FREEPDB1}"
    ORACLE_PORT="${ORACLE_PORT:-1521}"
    CONTOSO_SCHEMA="${CONTOSO_SCHEMA:-CONTOSO}"
    CONTAINER="${ORACLE_CONTAINER_NAME:-o2p-oracle}"
    CONTOSO_PW="${CONTOSO_PASSWORD:-}"

    if [[ -z "$CONTOSO_PW" && "${USE_KEYVAULT:-0}" == "1" && -n "${AZ_KEYVAULT_NAME:-}" ]]; then
        CONTOSO_PW="$(az keyvault secret show --vault-name "$AZ_KEYVAULT_NAME" \
            --name "${KV_SECRET_CONTOSO_PASSWORD:-contoso-schema-password}" \
            --query value -o tsv 2>/dev/null || true)"
    fi
    [[ -n "$CONTOSO_PW" ]] || die "CONTOSO_PASSWORD is not set" \
        "set it in ${ENV_FILE} (or USE_KEYVAULT=1)"

    free_port() {
        local p="$1" limit=$(( $1 + 60 ))
        while [[ "$p" -lt "$limit" ]]; do
            if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then printf '%s' "$p"; return 0; fi
            exec 3>&- 2>/dev/null || true
            p=$(( p + 1 ))
        done
        return 1
    }

    if [[ "$TARGET" == "local" ]]; then
        have docker || die "docker not installed" "brew install --cask docker, or use --azure"
        docker info >/dev/null 2>&1 || die "the Docker daemon is not responding" "start Docker Desktop"
        if ! docker inspect -f '{{.State.Status}}' "$CONTAINER" >/dev/null 2>&1; then
            if docker inspect -f '{{.State.Status}}' oracle-lab >/dev/null 2>&1; then
                CONTAINER='oracle-lab'
            else
                die "no container named '${CONTAINER}' (nor 'oracle-lab')" \
                    "start Oracle first: see docs/02-seed-oracle.md, then  docker ps -a"
            fi
        fi
        CSTATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER")"
        [[ "$CSTATE" == "running" ]] || die "container '${CONTAINER}' is '${CSTATE}'" \
            "docker start ${CONTAINER}"
        info "container ${CONTAINER} is running"
        ORACLE_TARGET_HOST='localhost'
        exec_sqlplus() { docker exec -i "$CONTAINER" sqlplus -S -L /nolog; }
    else
        have az || die "az CLI not installed" "brew install azure-cli"
        have jq || die "jq is required to read generated/outputs.json" "brew install jq"
        az account show >/dev/null 2>&1 || die "Azure CLI is not logged in" "az login"

        OUTPUTS="${REPO_ROOT}/generated/outputs.json"
        [[ -f "$OUTPUTS" ]] || die "generated/outputs.json not found" \
            "run scripts/deploy.sh first"

        out() { jq -r --arg k "$1" '.[$k] // empty' "$OUTPUTS" 2>/dev/null || true; }
        PREFIX="${AZ_PREFIX:-o2p}"
        RG="$(out resourceGroupName)"; RG="${RG:-${AZ_RESOURCE_GROUP:-${PREFIX}-migration-lab-rg}}"
        BASTION="$(out bastionName)";  BASTION="${BASTION:-${PREFIX}-bastion}"
        VM_NAME="$(out oracleVmName)"; VM_NAME="${VM_NAME:-${PREFIX}-oracle-vm}"
        VM_ID="$(out oracleVmId)"
        SSH_USER="$(out oracleAdminUsername)"; SSH_USER="${SSH_USER:-${ORACLE_VM_ADMIN_USER:-azureuser}}"
        SSH_KEY="${SSH_KEY_PATH:-${REPO_ROOT}/generated/ssh/${PREFIX}-lab_ed25519}"

        [[ -f "$SSH_KEY" ]] || die "no SSH private key at ${SSH_KEY}" \
            "scripts/deploy.sh generates it; set SSH_KEY_PATH in .env if yours is elsewhere"
        if [[ -z "$VM_ID" ]]; then
            VM_ID="$(az vm show --resource-group "$RG" --name "$VM_NAME" --query id -o tsv 2>/dev/null || true)"
        fi
        [[ -n "$VM_ID" ]] || die "cannot find the Oracle VM '${VM_NAME}' in '${RG}'" \
            "az vm list --resource-group '${RG}' -o table"

        SSH_PORT="$(free_port 22022)" || die "no free local port in 22022-22082"
        info "opening Bastion tunnel 127.0.0.1:${SSH_PORT} -> ${VM_NAME}:22"
        az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
            --target-resource-id "$VM_ID" --resource-port 22 --port "$SSH_PORT" >/dev/null 2>&1 &
        TUNNEL_PID=$!

        WAITED=0
        until (exec 3<>"/dev/tcp/127.0.0.1/${SSH_PORT}") 2>/dev/null; do
            exec 3>&- 2>/dev/null || true
            sleep 1; WAITED=$(( WAITED + 1 ))
            kill -0 "$TUNNEL_PID" 2>/dev/null || die "the Bastion tunnel exited immediately" \
                "check the Bastion SKU is Standard with native client support enabled"
            [[ "$WAITED" -lt 45 ]] || die "Bastion tunnel did not open within 45s"
        done
        exec 3>&- 2>/dev/null || true
        info "tunnel up on 127.0.0.1:${SSH_PORT}"

        SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT"
                  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                  -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30)
        ORACLE_TARGET_HOST='localhost'
        exec_sqlplus() {
            # shellcheck disable=SC2029  # $CONTAINER expands locally on purpose
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" \
                "docker exec -i $(printf '%q' "$CONTAINER") sqlplus -S -L /nolog"
        }
    fi

    # ----------------------------------------------------------------------
    # SQL*Plus preamble. Fed on stdin so no password reaches argv, exactly as
    # scripts/seed-oracle.sh does it. DEFINE scale is what tests/verify-counts.sql
    # reads; without it SQL*Plus would prompt and hang a CI run.
    # ----------------------------------------------------------------------
    preamble() {
        cat <<PRE
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET ECHO OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TAB OFF
SET TRIMSPOOL ON
SET LINESIZE 200
SET PAGESIZE 5000
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET SQLBLANKLINES ON
CONNECT ${CONTOSO_SCHEMA}/"${CONTOSO_PW}"@${ORACLE_TARGET_HOST}:${ORACLE_PORT}/${ORACLE_SERVICE}
DEFINE contoso_schema = "${CONTOSO_SCHEMA}"
DEFINE scale = "${SCALE}"
PRE
    }

    # run_sql_test <check-name> <file>
    run_sql_test() {
        local name="$1" file="$2"
        local t0 ms rc=0 log
        log="${RUN_LOG_DIR}/${name}.log"

        if [[ ! -f "$file" ]]; then
            record "$name" SKIP "${file#"$REPO_ROOT"/} not found" 0
            return 0
        fi
        t0="$(now_ms)"
        { preamble; cat "$file"; printf '\nEXIT SUCCESS\n'; } \
            | exec_sqlplus > "$log" 2>&1 || rc=$?
        ms=$(( $(now_ms) - t0 ))

        # Print the whole SQL*Plus output, indented. The PASS/FAIL lines and
        # the per-type census the SQL prints ARE the test report -- filtering
        # them down to a summary throws away the reason anyone ran this.
        # Runs of blank lines are squeezed; nothing else is dropped.
        sed 's/^/         /' "$log" | cat -s

        if [[ "$rc" -ne 0 ]]; then
            local why
            why="$(grep -m1 -E '^ORA-2010[0-9]' "$log" 2>/dev/null | cut -c1-58 || true)"
            if [[ -z "$why" ]]; then
                why="$(grep -m1 -E '^(ORA-|PLS-|SP2-)[0-9]' "$log" 2>/dev/null | cut -c1-58 || true)"
            fi
            record "$name" FAIL "${why:-sqlplus exit $rc}" "$ms"
        else
            record "$name" PASS "all assertions passed" "$ms"
        fi
    }

    # ----------------------------------------------------------------------
    # Scale detection. verify-counts.sql scores each table against a
    # fixed + scaled*SCALE minimum, so running it at the wrong --scale turns a
    # correctly-seeded database into a wall of bogus "SHORT" failures -- which
    # teaches the reader to ignore failures. Measure the actual volume first and
    # either adopt the matching scale (when the caller pinned none) or refuse
    # with the right flag (when they did). verify-schema is scale-independent,
    # so only bother when verify-counts is actually going to run.
    # ----------------------------------------------------------------------
    if selected verify-counts; then
        # sales_order is the most load-bearing scaled table and tracks the
        # documented levels cleanly: 0.01 -> ~2,500, 0.1 -> ~25,000, 1 -> ~250,000.
        ORDERS_AT_1="${SEED_ORDER_ROWS:-250000}"
        case "$ORDERS_AT_1" in ''|0|*[!0-9]*) ORDERS_AT_1=250000 ;; esac

        # A PL/SQL block with its own handler, so a missing table degrades to
        # O2P_ORDERS=-1 instead of tripping WHENEVER SQLERROR in the preamble.
        measure_orders() {
            {
                preamble
                cat <<'DETECT'
SET HEADING OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
   n NUMBER;
BEGIN
   EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM sales_order' INTO n;
   DBMS_OUTPUT.PUT_LINE('O2P_ORDERS=' || n);
EXCEPTION
   WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('O2P_ORDERS=-1');
END;
/
EXIT SUCCESS
DETECT
            } | exec_sqlplus 2>/dev/null \
              | sed -n 's/.*O2P_ORDERS=\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' | head -n1
        }

        ORDERS="$(measure_orders || true)"
        if [[ -z "$ORDERS" || ! "$ORDERS" =~ ^-?[0-9]+$ || "$ORDERS" -lt 0 ]]; then
            note "could not measure row volume (sales_order not readable yet); using --scale ${SCALE}"
        elif [[ "$ORDERS" -eq 0 ]]; then
            note "sales_order is empty; using --scale ${SCALE} -- seed data first (scripts/seed-oracle.sh)"
        else
            # Snap the observed volume to the nearest named level on a log scale.
            DETECTED="$(awk -v n="$ORDERS" -v full="$ORDERS_AT_1" 'BEGIN{
                if      (n >= sqrt(0.1  * 1.0) * full) lvl = "1";
                else if (n >= sqrt(0.01 * 0.1) * full) lvl = "0.1";
                else                                   lvl = "0.01";
                printf "%s", lvl;
            }')"
            if [[ "$SCALE_EXPLICIT" -eq 1 ]]; then
                # Compare raw ratios, not snapped levels, so a legitimate
                # in-between scale is tolerated and only an order-of-magnitude
                # mismatch (the --scale 1 vs 0.01 trap) trips this.
                MISMATCH="$(awk -v n="$ORDERS" -v full="$ORDERS_AT_1" -v us="$SCALE" 'BEGIN{
                    us  = us + 0;            # coerce a non-numeric --scale to 0
                    obs = n / full;          # full and n are validated positive
                    if      (us <= 0)      print 1;
                    else if (us > 3 * obs) print 1;
                    else if (obs > 3 * us) print 1;
                    else                   print 0;
                }')"
                if [[ "$MISMATCH" -eq 1 ]]; then
                    die "the loaded data matches --scale ${DETECTED} (${ORDERS} orders in sales_order), but --scale ${SCALE} was requested" \
                        "re-run with --scale ${DETECTED} (or keep --scale ${SCALE} only if you are certain this seed differs)"
                fi
                info "scale ${SCALE} matches the loaded data (${ORDERS} orders)"
            else
                if [[ "$SCALE" != "$DETECTED" ]]; then
                    info "detected --scale ${DETECTED} from ${ORDERS} orders (pass --scale to override)"
                    SCALE="$DETECTED"
                else
                    info "scale ${DETECTED} confirmed from ${ORDERS} orders"
                fi
            fi
        fi
    fi

    selected verify-schema && run_sql_test verify-schema "${SCRIPT_DIR}/verify-schema.sql"
    selected verify-counts && run_sql_test verify-counts "${SCRIPT_DIR}/verify-counts.sql"
fi

# ==========================================================================
# Summary
# ==========================================================================
hdr "Summary"
printf '  %s%-26s %-8s %10s  %s%s\n' "$C_BOLD" "CHECK" "RESULT" "TIME" "DETAIL" "$C_RESET"
printf '  %s\n' "-------------------------- -------- ----------  ------------------------------"
for i in "${!R_NAME[@]}"; do
    case "${R_STATUS[$i]}" in
        PASS) COL="$C_GREEN" ;;
        FAIL) COL="$C_RED" ;;
        *)    COL="$C_YELLOW" ;;
    esac
    printf '  %-26s %s%-8s%s %10s  %s\n' \
        "${R_NAME[$i]}" "$COL" "${R_STATUS[$i]}" "$C_RESET" \
        "$(fmt_ms "${R_MS[$i]}")" "${R_DETAIL[$i]}"
done

printf '\n  %d passed, %d failed, %d skipped\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
printf '  logs: %s\n' "${RUN_LOG_DIR#"$REPO_ROOT"/}"

# A test harness that runs nothing and reports success is worse than no harness.
# `--only 'zzz'` used to print "All checks passed" and exit 0, and CI leans on
# --only 'verify-schema' / --only 'verify-counts' — so renaming a check would
# have turned CI green while asserting nothing at all. That is the same
# fail-open shape this repo warns readers about for plpgsql_check, so it should
# not exist in the repo's own tooling.
if [[ "$(( N_PASS + N_FAIL + N_SKIP ))" -eq 0 ]]; then
    printf '\n%s%sNo checks ran.%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
    if [[ -n "$ONLY_PATTERN" ]]; then
        printf 'fix: --only %s matched none of the known checks. They are:\n' "$ONLY_PATTERN"
        for c in "${CHECKS[@]}"; do printf '       %s\n' "$c"; done
        printf '     Note --only takes a glob, so use --only '\''verify-*'\'' to match a family.\n\n'
    else
        printf 'fix: every check was filtered out. This is a bug in the harness.\n\n'
    fi
    exit 2
fi

if [[ "$N_FAIL" -gt 0 ]]; then
    printf '\n%s%s%d check(s) failed.%s\n\n' "$C_BOLD" "$C_RED" "$N_FAIL" "$C_RESET"
    exit 1
fi

if [[ "$N_SKIP" -gt 0 && "$STRICT" -eq 1 ]]; then
    printf '\n%s%s%d check(s) skipped and --strict was given.%s\n' "$C_BOLD" "$C_RED" "$N_SKIP" "$C_RESET"
    printf 'fix: install the missing tool, or drop --strict.\n\n'
    exit 1
fi

if [[ "$N_SKIP" -gt 0 ]]; then
    printf '\n%s%sAll checks that could run passed. %d were skipped.%s\n\n' \
        "$C_BOLD" "$C_YELLOW" "$N_SKIP" "$C_RESET"
else
    printf '\n%s%sAll checks passed.%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
fi
