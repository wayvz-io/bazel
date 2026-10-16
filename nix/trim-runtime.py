"""Repack the native launcher's payload without retaining its compiler closure."""

import hashlib
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile


launcher, output, compiler, graalvm, patchelf, remove_references = sys.argv[1:]
with tempfile.TemporaryDirectory() as temporary:
    directory = pathlib.Path(temporary)
    with zipfile.ZipFile(launcher) as archive:
        entries = archive.infolist()
        assert entries[-1].filename == "install_base_key", "install key must be last"
        prefix_size = min(entry.header_offset for entry in entries)
        archive.extractall(directory)

    added = []
    if (directory / "libmanagement_ext.so").exists():
        # Preserve the management library's dependencies without the compiler/JDK.
        for name, relative in [
            ("libjava.so", "lib/libjava.so"),
            ("libjvm.so", "lib/server/libjvm.so"),
        ]:
            target = directory / name
            target.write_bytes((pathlib.Path(graalvm) / relative).read_bytes())
            added.append(name)
        for name in ["libmanagement_ext.so", *added]:
            subprocess.run(
                [patchelf, "--set-rpath", "$ORIGIN", str(directory / name)], check=True
            )

    # Each payload change must select a new install base. Hash names and contents
    # in sorted order, retaining Bazel's 32-character hexadecimal key format.
    names = [
        entry.filename
        for entry in entries
        if not entry.is_dir() and entry.filename != "install_base_key"
    ]
    names += added
    digest = hashlib.sha256()
    references = set()
    for name in sorted(names):
        path = directory / name
        data = path.read_bytes()
        if compiler.encode() in data:
            subprocess.run([remove_references, "-t", compiler, str(path)], check=True)
            data = path.read_bytes()
        digest.update(name.encode() + b"\0" + len(data).to_bytes(8, "big") + data)
        references.update(re.findall(rb"/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+", data))
    (directory / "install_base_key").write_text(digest.hexdigest()[:32])

    client = directory / "client"
    with open(launcher, "rb") as source:
        client.write_bytes(source.read(prefix_size))
    subprocess.run([remove_references, "-t", compiler, str(client)], check=True)
    pathlib.Path(output).write_bytes(client.read_bytes())
    with zipfile.ZipFile(output, "a") as archive:
        for entry in entries:
            if entry.filename == "install_base_key":
                # The client requires the install key to be the final ZIP entry.
                for name in added:
                    extra = zipfile.ZipInfo(name, date_time=entry.date_time)
                    extra.compress_type = zipfile.ZIP_DEFLATED
                    extra.external_attr = 0o100755 << 16
                    archive.writestr(extra, (directory / name).read_bytes())
            data = b"" if entry.is_dir() else (directory / entry.filename).read_bytes()
            archive.writestr(entry, data)

    pathlib.Path(output).chmod(0o755)
    for reference in sorted(references):
        print(reference.decode())
