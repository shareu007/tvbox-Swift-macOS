#!/usr/bin/env python3
"""Fail release packaging if a bundle contains local data or credential material.

Reports file names and categories only: matched private values are never logged.
Third-party parser constants (e.g. a PEM header without a key) are not secrets.
"""
import argparse
import json
import subprocess
import re
from pathlib import Path


SECRET_PATTERNS = {
    "private key payload": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+[A-Za-z0-9+/]{32,}"),
    "GitHub credential": re.compile(rb"(?<![A-Za-z0-9_])(?:github_pat_[A-Za-z0-9_]{20,}|gh[opsu]_[A-Za-z0-9]{20,})(?![A-Za-z0-9_])"),
    "AWS access key": re.compile(rb"(?<![A-Za-z0-9/+=])AKIA[A-Z0-9]{16}(?![A-Za-z0-9/+=])"),
}
PRIVATE_SUFFIXES = {".db", ".sqlite", ".sqlite3", ".p12", ".pfx", ".p8", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".log", ".dSYM"}
PRIVATE_NAMES = {".git", ".env", ".DS_Store", "IOS-key", "HomeSnapshots.json", "CloudDriveCredentials.json", "secrets.sh"}


def audit_bundle(bundle, local_roots):
    issues = []
    presets = bundle / "Contents/Resources/TVBoxPresets.json"
    try:
        if json.loads(presets.read_text()) != []:
            issues.append(("Contents/Resources/TVBoxPresets.json", "nonempty interface presets"))
    except (OSError, ValueError):
        issues.append(("Contents/Resources/TVBoxPresets.json", "missing or invalid interface presets"))
    needles = []
    for root in local_roots:
        value = str(root).rstrip("/") + "/"
        needles.extend([value.encode(), value.encode("utf-16-le"), value.replace("/", "\\/").encode()])
    for path in [bundle, *bundle.rglob("*")]:
        relative = str(path.relative_to(bundle))
        if path.name in PRIVATE_NAMES or path.suffix in PRIVATE_SUFFIXES:
            issues.append((relative, "private data or development artifact"))
        if path.is_symlink():
            # Framework aliases are internal; external aliases can expose local files.
            if not path.resolve().is_relative_to(bundle.resolve()):
                issues.append((relative, "external symlink"))
            continue
        if not path.is_file() and not path.is_dir():
            continue
        payloads = [path.read_bytes()] if path.is_file() else []
        names = subprocess.check_output(["xattr", str(path)], text=True).splitlines()
        for name in names:
            value = subprocess.check_output(["xattr", "-px", name, str(path)], text=True)
            payloads.append(bytes.fromhex(value))
        if any(needle in data for data in payloads for needle in needles):
            issues.append((relative, "local absolute path"))
        for label, pattern in SECRET_PATTERNS.items():
            if any(pattern.search(data) for data in payloads):
                issues.append((relative, label))
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    if not (args.bundle / "Contents/MacOS/TVBox").is_file():
        parser.error("not a TVBox application bundle")
    issues = audit_bundle(args.bundle, [Path.home(), Path(__file__).resolve().parent.parent])
    for relative, label in issues:
        print(f"privacy audit failed: {relative}: {label}")
    if issues:
        return 1
    print("macOS bundle privacy audit passed (local paths, presets, private files, credential patterns)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
