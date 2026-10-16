"""Keep embedded Bash test helpers executable in Nix sandboxes and on RBE."""

import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in (
    "test-setup.sh",
    "generate-xml.sh",
    "collect_coverage.sh",
    "collect_cc_coverage.sh",
    "dummy.sh",
):
    path = root / "tools/test" / name
    source = path.read_text()
    first, rest = source.split("\n", 1)
    if not first.startswith("#!") or "bash" not in first:
        raise ValueError(f"Unexpected Bash shebang in {path}: {first}")
    # Nix sandboxes provide /bin/sh as Bash. Other Linux workers can provide
    # dash there, so enter Bash through the action's explicitly configured PATH.
    path.write_text(
        '#!/bin/sh\n'
        'if [ -z "${BASH_VERSION:-}" ]; then\n'
        '  exec bash "$0" "$@"\n'
        'fi\n'
        'set +o posix\n'
        + rest
    )
