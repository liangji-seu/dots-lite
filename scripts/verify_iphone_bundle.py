"""Validate install-critical metadata in an unsigned or signed Xcode product."""
from pathlib import Path
import ipaddress
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
    ats = info.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsArbitraryLoads"):
        raise SystemExit("FAIL: global ATS bypass is not permitted")
    tailscale = ipaddress.ip_network("100.64.0.0/10")
    covered = False
    for name, exception in ats.get("NSExceptionDomains", {}).items():
        try:
            network = ipaddress.ip_network(name)
        except ValueError:
            continue
        if exception.get("NSExceptionAllowsInsecureHTTPLoads"):
            if not network.subnet_of(tailscale):
                raise SystemExit("FAIL: numeric HTTP exception extends beyond Tailscale IPv4")
            covered |= network == tailscale
    if not covered:
        raise SystemExit("FAIL: Tailscale IPv4 requires an explicit HTTP exception on iOS 17+")
    print("PASS: app metadata, iOS 16.0 target and scoped Tailscale HTTP exception")


if __name__ == "__main__":
    main()
