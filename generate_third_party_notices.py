#!/usr/bin/env python3
"""Collect notices and bundled license files for pymobiledevice3 dependencies."""

from __future__ import annotations

import argparse
import ast
import re
import shutil
from importlib import metadata
from pathlib import Path

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


LICENSE_NAMES = ("license", "licence", "copying", "notice", "authors")
OVERRIDES_DIRECTORY = Path(__file__).resolve().parent / "third_party_license_overrides"


def dependency_closure(root: str) -> list[metadata.Distribution]:
    pending = [root]
    seen: set[str] = set()
    result: list[metadata.Distribution] = []

    while pending:
        name = canonicalize_name(pending.pop())
        if name in seen:
            continue
        seen.add(name)
        distribution = metadata.distribution(name)
        result.append(distribution)
        for raw_requirement in distribution.requires or []:
            requirement = Requirement(raw_requirement)
            if requirement.marker is None or requirement.marker.evaluate({"extra": ""}):
                pending.append(requirement.name)

    return sorted(result, key=lambda item: canonicalize_name(item.metadata["Name"]))


def bundled_distributions(toc_path: Path) -> list[metadata.Distribution]:
    _, entries = ast.literal_eval(toc_path.read_text(encoding="utf-8"))
    package_map = metadata.packages_distributions()
    names = {canonicalize_name("pymobiledevice3")}
    for module_name, *_ in entries:
        top_level_name = module_name.split(".", 1)[0]
        names.update(canonicalize_name(name) for name in package_map.get(top_level_name, []))
    names.update(canonicalize_name(item.metadata["Name"]) for item in dependency_closure("pymobiledevice3"))
    result = [metadata.distribution(name) for name in names]
    return sorted(result, key=lambda item: canonicalize_name(item.metadata["Name"]))


def is_license_file(path: Path) -> bool:
    name = path.name.lower()
    return any(
        name == stem or name.startswith(f"{stem}.") or name.startswith(f"{stem}-")
        for stem in LICENSE_NAMES
    )


def safe_filename(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value)


def project_url(distribution: metadata.Distribution) -> str:
    for value in distribution.metadata.get_all("Project-URL", []):
        _, separator, url = value.partition(",")
        if separator and url.strip():
            return url.strip()
    return distribution.metadata.get("Home-page", "")


def license_name(distribution: metadata.Distribution) -> str:
    declared = distribution.metadata.get("License-Expression") or distribution.metadata.get("License")
    if declared and "\n" not in declared and len(declared) <= 160:
        return declared.strip()
    classifiers = distribution.metadata.get_all("Classifier", [])
    licenses = [item.removeprefix("License :: ") for item in classifiers if item.startswith("License :: ")]
    return "; ".join(licenses) or "See bundled license files and project metadata"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--pyinstaller-toc", type=Path)
    args = parser.parse_args()

    destination = args.destination.resolve()
    licenses_directory = destination / "licenses"
    shutil.rmtree(destination, ignore_errors=True)
    licenses_directory.mkdir(parents=True)

    rows: list[str] = []
    distributions = (
        bundled_distributions(args.pyinstaller_toc)
        if args.pyinstaller_toc
        else dependency_closure("pymobiledevice3")
    )
    for distribution in distributions:
        name = distribution.metadata["Name"]
        version = distribution.version
        canonical_name = canonicalize_name(name)
        copied: list[str] = []
        package_directory = licenses_directory / safe_filename(f"{name}-{version}")

        for relative_path in distribution.files or []:
            path = Path(str(relative_path))
            if not is_license_file(path):
                continue
            source = Path(distribution.locate_file(relative_path))
            if not source.is_file():
                continue
            package_directory.mkdir(parents=True, exist_ok=True)
            target = package_directory / safe_filename("__".join(path.parts))
            shutil.copy2(source, target)
            copied.append(str(target.relative_to(destination)))

        overrides = sorted(OVERRIDES_DIRECTORY.glob(f"{canonical_name}__*"))
        if canonical_name == "developer-disk-image":
            overrides.append(Path(__file__).resolve().parent / "LICENSE")
        for source in overrides:
            package_directory.mkdir(parents=True, exist_ok=True)
            target = package_directory / source.name.partition("__")[2]
            if source.name == "LICENSE":
                target = package_directory / "LICENSE-GPL-3.0.txt"
            shutil.copy2(source, target)
            copied.append(str(target.relative_to(destination)))

        rows.extend(
            [
                f"Package: {name}",
                f"Version: {version}",
                f"License: {license_name(distribution)}",
                f"Project: {project_url(distribution) or 'not declared in package metadata'}",
                "License files: " + (", ".join(copied) if copied else "none included in the installed package"),
                "",
            ]
        )

    header = (
        "THIRD-PARTY SOFTWARE NOTICES\n\n"
        "This application bundles the following Python packages through pymobiledevice3. "
        "The packages remain subject to their respective licenses. License texts shipped "
        "by the installed distributions are copied into the licenses directory.\n\n"
    )
    (destination / "THIRD_PARTY_NOTICES.txt").write_text(header + "\n".join(rows), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
