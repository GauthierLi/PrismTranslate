#!/usr/bin/env python3
"""Build offline Linux tar/deb packages without compiling on the host OS."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
VERSION = "0.2.0"
ARCHES = {"amd64": "manylinux_2_28_x86_64", "arm64": "manylinux_2_31_aarch64"}
DEPENDENCIES = (
    "python3 (>= 3.8), python3 (<< 3.13), python3-venv, util-linux, ca-certificates, "
    "libgl1, libegl1, libfontconfig1, libdbus-1-3, libgssapi-krb5-2, libxkbcommon-x11-0, libxi6, "
    "libxcb-cursor0, libxcb-icccm4, libxcb-image0, libxcb-keysyms1, "
    "libxcb-render-util0, libxcb-xinerama0, libxcb-randr0, libxcb-shape0, "
    "libxcb-xfixes0, tesseract-ocr, tesseract-ocr-eng, tesseract-ocr-chi-sim"
)


def tar_bytes(directory):
    result = io.BytesIO()
    # dpkg does not accept Python's default PAX extended headers.
    with tarfile.open(fileobj=result, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
        for path in sorted(directory.rglob("*")):
            info = archive.gettarinfo(str(path), str(path.relative_to(directory)))
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = int(info.mtime)
            if path.is_file():
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
            else:
                archive.addfile(info)
    return result.getvalue()


def write_deb(path, control, data):
    # Debian's format is an ar archive of these three members; no host dpkg needed.
    with path.open("wb") as output:
        output.write(b"!<arch>\n")
        for name, content in (("debian-binary", b"2.0\n"),
                              ("control.tar.gz", tar_bytes(control)),
                              ("data.tar.gz", tar_bytes(data))):
            header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(content):<10}`\n"
            output.write(header.encode("ascii"))
            output.write(content)
            if len(content) % 2:
                output.write(b"\n")


def build(arch, output, wheel_dir):
    output.mkdir(parents=True, exist_ok=True)
    name = f"prismtranslate-{VERSION}-linux-{arch}"
    with tempfile.TemporaryDirectory(prefix="prismtranslate-build-") as temporary:
        work = Path(temporary)
        app = work / name
        app.mkdir()
        shutil.copytree(ROOT / "prismtranslate", app / "prismtranslate",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        shutil.copy(ROOT.parent / "Resources/logo.png", app / "prismtranslate/logo.png")
        for filename in ("requirements.txt", "README.md", "PARITY.md", "prismtranslate.desktop"):
            shutil.copy(ROOT / filename, app / filename)
        shutil.copy(ROOT / "prismtranslate-launcher", app / "prismtranslate-launcher")
        (app / "prismtranslate-launcher").chmod(0o755)
        # Command name lives beside the Python package via a bin directory.
        (app / "bin").mkdir()
        (app / "bin/prismtranslate").symlink_to("../prismtranslate-launcher")
        if wheel_dir:
            shutil.copytree(wheel_dir, app / "wheels")
        else:
            subprocess.run([
                sys.executable, "-m", "pip", "download", "--only-binary=:all:",
                "--platform", ARCHES[arch], "--python-version", "38", "--implementation", "cp",
                "--abi", "abi3", "--abi", "cp38", "--dest", str(app / "wheels"),
                "PySide6-Essentials==6.6.3.1", "dbus-next==0.2.3", "six==1.17.0", "pip==24.3.1",
            ], check=True)
            # langdetect ships a source archive, but contains no native code.
            # Build its portable wheel on the host; all Linux binaries above
            # still come from the pinned manylinux/abi3 distributions.
            subprocess.run([sys.executable, "-m", "pip", "wheel", "--no-deps",
                            "--wheel-dir", str(app / "wheels"), "langdetect==1.0.9"], check=True)
        digest = hashlib.sha256()
        for path in sorted(app.rglob("*")):
            if path.is_file():
                digest.update(str(path.relative_to(app)).encode())
                digest.update(path.read_bytes())
        (app / "runtime-id").write_text(VERSION + "-" + arch + "-" + digest.hexdigest()[:12] + "\n")
        tar_path = output / (name + ".tar.gz")
        with tarfile.open(tar_path, "w:gz", format=tarfile.GNU_FORMAT) as archive:
            archive.add(app, arcname=name)
        data = work / "data"
        install = data / "usr/lib/prismtranslate"
        install.parent.mkdir(parents=True)
        shutil.copytree(app, install, symlinks=True)
        (data / "usr/bin").mkdir(parents=True)
        (data / "usr/bin/prismtranslate").symlink_to("../lib/prismtranslate/prismtranslate-launcher")
        (data / "usr/share/applications").mkdir(parents=True)
        shutil.copy(ROOT / "prismtranslate.desktop", data / "usr/share/applications")
        (data / "usr/share/icons/hicolor/256x256/apps").mkdir(parents=True)
        shutil.copy(ROOT.parent / "Resources/logo.png",
                    data / "usr/share/icons/hicolor/256x256/apps/prismtranslate.png")
        control = work / "control"
        control.mkdir()
        (control / "control").write_text(
            f"Package: prismtranslate\nVersion: {VERSION}\nArchitecture: {arch}\n"
            "Maintainer: PrismTranslate contributors\nSection: utils\nPriority: optional\n"
            f"Depends: {DEPENDENCIES}\n"
            "Recommends: xdg-desktop-portal, fonts-noto-cjk\n"
            "Description: Clipboard translation and screen OCR with floating subtitles\n"
            " Native Qt Linux desktop application with offline Python dependencies.\n",
            encoding="utf-8")
        deb_path = output / f"prismtranslate_{VERSION}_{arch}.deb"
        write_deb(deb_path, control, data)
        checksums = {}
        for path in (tar_path, deb_path):
            checksums[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest = {
            "version": VERSION, "architecture": arch, "python": "3.8–3.12",
            "ubuntu_targets": ["20.04", "22.04", "24.04"], "sha256": checksums,
        }
        if shutil.which("git"):
            revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT.parent,
                                      text=True, capture_output=True)
            if revision.returncode == 0:
                manifest["source_revision"] = revision.stdout.strip()
        (output / f"manifest-{arch}.json").write_text(json.dumps(manifest, indent=2) + "\n")
        for filename, checksum in checksums.items():
            print(checksum + "  " + filename)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=ARCHES, default="amd64")
    parser.add_argument("--output", type=Path, default=ROOT.parent / "build-linux")
    parser.add_argument("--wheel-dir", type=Path, help="Use a pre-downloaded wheel directory")
    arguments = parser.parse_args()
    build(arguments.arch, arguments.output.resolve(), arguments.wheel_dir)
