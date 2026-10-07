"""Validate install-critical metadata in an unsigned or signed Xcode product."""
from pathlib import Path
import plistlib
import sys


def main() -> None:
    bundle = Path(sys.argv[1])
    with (bundle / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    required = (
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
        "CFBundleVersion", "CFBundlePackageType", "MinimumOSVersion",
    )
    for key in required:
        if not info.get(key):
            raise SystemExit(f"FAIL: missing {key}")
    if info["CFBundlePackageType"] != "APPL":
        raise SystemExit("FAIL: product is not an application")
    if not (bundle / info["CFBundleExecutable"]).is_file():
        raise SystemExit("FAIL: executable is missing")
    minimum = tuple(int(part) for part in info["MinimumOSVersion"].split("."))
    if minimum[:2] != (16, 0):
        raise SystemExit("FAIL: expected iOS 16.0 deployment target")
    print("PASS: application metadata and iOS 16.0 deployment target")


if __name__ == "__main__":
    main()
