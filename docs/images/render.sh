#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# render.sh - regenerate the diagrams in this directory from their .dot source.
#
# The .png files are committed so the README renders on GitHub without anyone
# needing Graphviz. That means they can drift from the .dot source, so this
# script is the only supported way to change them: edit the .dot, run this,
# commit both.
#
#   ./docs/images/render.sh            # render every .dot here
#   ./docs/images/render.sh --check    # fail if a .png is stale (used by CI)
#
# Needs Graphviz:  brew install graphviz   |   apt-get install -y graphviz
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

command -v dot >/dev/null 2>&1 || {
    printf 'render.sh: graphviz is not installed.\n' >&2
    printf 'fix: brew install graphviz   (macOS)   |   apt-get install -y graphviz   (Debian/Ubuntu)\n' >&2
    exit 1
}

# -Gdpi=144 renders at 2x so the diagram stays sharp on a HiDPI display and
# when GitHub scales it down into the README column.
rc=0
for src in "${SCRIPT_DIR}"/*.dot; do
    [[ -e "$src" ]] || { printf 'render.sh: no .dot files in %s\n' "$SCRIPT_DIR" >&2; exit 1; }
    out="${src%.dot}.png"
    if [[ "$CHECK" -eq 1 ]]; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/render.XXXXXX.png")"
        dot -Tpng -Gdpi=144 "$src" -o "$tmp"
        if cmp -s "$tmp" "$out"; then
            printf '  ok    %s is up to date\n' "$(basename "$out")"
        else
            printf '  STALE %s does not match %s - run ./docs/images/render.sh\n' \
                   "$(basename "$out")" "$(basename "$src")" >&2
            rc=1
        fi
        rm -f "$tmp"
    else
        dot -Tpng -Gdpi=144 "$src" -o "$out"
        printf '  rendered %s (%s)\n' "$(basename "$out")" "$(du -h "$out" | cut -f1 | tr -d ' ')"
    fi
done
exit "$rc"
