#!/usr/bin/env python3
"""Keep the installer embedded in cloud-init identical to the real one.

scripts/cloud-init/oracle-vm.yaml carries a full copy of
scripts/install-oracle.sh inside a write_files block, because the VM has no
access to this repository at first boot and fetching the script from GitHub
would make provisioning depend on a network path that the NAT gateway, the
NSGs and GitHub itself all have to cooperate on.

The cost of that choice is a duplicate, and the comment in the YAML claiming
the copy is "byte-identical" is a promise no human keeps. It had already
drifted by 58 lines: a real Azure deployment provisioned a VM running an
installer whose bug had been fixed in the repo, and nothing noticed, because
nothing compared them.

    python3 tools/sync-cloud-init.py            rewrite the embedded copy
    python3 tools/sync-cloud-init.py --check    exit 1 if it has drifted

tests/run-tests.sh runs --check, so drift now fails the build instead of
surfacing as a mystifying failure on a VM forty minutes into a deployment.

Standard library only, like the other tools here.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "install-oracle.sh"
CLOUD_INIT = REPO / "scripts" / "cloud-init" / "oracle-vm.yaml"

# The write_files entry, up to and including its "content: |" line, then the
# indented body. cloud-init indents write_files content by six spaces here.
BLOCK = re.compile(
    r"(- path: /usr/local/sbin/install-oracle\.sh\n"
    r"(?:.*\n)*?"
    r"    content: \|\n)"
    r"((?:      .*\n|\n)+)"
)
INDENT = "      "


def embedded_text(yaml_text: str) -> str:
    """The installer as it currently sits inside the YAML, de-indented."""
    m = BLOCK.search(yaml_text)
    if not m:
        sys.exit(
            "sync-cloud-init: could not find the install-oracle.sh write_files "
            f"block in {CLOUD_INIT.relative_to(REPO)}.\n"
            "If the YAML was restructured, update the BLOCK regex in this file."
        )
    lines = []
    for line in m.group(2).split("\n"):
        lines.append(line[len(INDENT):] if line.startswith(INDENT) else line)
    return "\n".join(lines).rstrip("\n")


def indent(script_text: str) -> str:
    """Indent for embedding. Blank lines stay blank rather than gaining trailing space."""
    out = []
    for line in script_text.rstrip("\n").split("\n"):
        out.append(INDENT + line + "\n" if line.strip() else "\n")
    return "".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="sync-cloud-init.py", allow_abbrev=False,
                                 description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="do not write; exit 1 if the embedded copy has drifted")
    args = ap.parse_args(argv)

    for p in (SCRIPT, CLOUD_INIT):
        if not p.is_file():
            print(f"sync-cloud-init: missing {p}", file=sys.stderr)
            return 2

    script = SCRIPT.read_text().rstrip("\n")
    yaml_text = CLOUD_INIT.read_text()
    current = embedded_text(yaml_text)

    if current.rstrip() == script.rstrip():
        print(f"in sync: {len(script.splitlines())} lines")
        return 0

    if args.check:
        cur_n, new_n = len(current.splitlines()), len(script.splitlines())
        print("DRIFT: the installer embedded in cloud-init does not match "
              "scripts/install-oracle.sh", file=sys.stderr)
        print(f"  embedded : {cur_n} lines", file=sys.stderr)
        print(f"  repo     : {new_n} lines", file=sys.stderr)
        print("", file=sys.stderr)
        print("A VM provisioned from this cloud-init would run the embedded "
              "version, not the repo one.", file=sys.stderr)
        print("fix: python3 tools/sync-cloud-init.py", file=sys.stderr)
        return 1

    m = BLOCK.search(yaml_text)
    CLOUD_INIT.write_text(yaml_text[:m.start(2)] + indent(script) + yaml_text[m.end(2):])
    print(f"synced: embedded {len(script.splitlines())} lines into "
          f"{CLOUD_INIT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
