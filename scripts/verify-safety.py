#!/usr/bin/env python3
"""Bounded source/symbol audit, not a proof of all possible runtime behaviour."""
import argparse
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULES = {
    "credential API": r"SecItem|\bKeychain\b",
    "keyboard / accessibility": r"CGEvent|AXIsProcessTrusted|AXUIElement",
    "network clients": r"URLSession|URLRequest|NSURLConnection|CFNetwork|NWConnection|NWListener|import Network\b",
    "execution / media": r"NSAppleScript|\bProcess\b|MRMediaRemote|MediaRemote|\b(?:execv|system|popen)\s*\(",
    "private Bluetooth storage": r"SQLite3|sqlite3_|com\.apple\.Bluetooth|Bluetooth.*\.db",
}
PRIVATE = r"SACLockScreenImmediate|CGSSessionScreenIsLocked|com\.apple\.screenIs(?:Locked|Unlocked)|login\.framework|\bdlopen\b|\bdlsym\b"

def forbidden(text):
    return [label for label, pattern in RULES.items() if re.search(pattern, text)]

def source_findings(name, text):
    issues = forbidden(text)
    if name != "ScreenLockAdapter.swift" and re.search(PRIVATE, text):
        issues.append("private screen API outside adapter")
    return issues

def self_test():
    for fixture in ("SecItemCopyMatching(x)", "CGEvent(keyboardEventSource: nil)",
                    "AXIsProcessTrusted()", "URLSession.shared", "NSAppleScript(source: s)",
                    "Process()", "MRMediaRemoteSendCommand()", "import SQLite3",
                    "/Library/Preferences/com.apple.Bluetooth.plist"):
        assert forbidden(fixture), fixture
    assert not forbidden("central.readRSSI()")
    assert source_findings("Other.swift", "SACLockScreenImmediate")
    assert not source_findings("ScreenLockAdapter.swift", "SACLockScreenImmediate")
    # Documentation is deliberately outside the runtime-source audit scope.
    print("PASS: auditor self-test")

def audit():
    failures = []
    def require(condition, message):
        if not condition:
            failures.append(message)
    sources = sorted((ROOT / "WatchLock").rglob("*.swift"))
    for path in sources:
        for finding in source_findings(path.name, path.read_text()):
            failures.append(f"{path.relative_to(ROOT)}: {finding}")
    require(bool(sources), "no app sources")
    require(not list((ROOT / "WatchLock").rglob("*.xib")), "obsolete XIB")
    require(not list((ROOT / "WatchLock").rglob("*.h")), "obsolete header")
    require(not (ROOT / "Launcher").exists(), "obsolete launcher")
    plist = plistlib.loads((ROOT / "WatchLock/Info.plist").read_bytes())
    require(plist.get("CFBundleIdentifier") == "local.shatravkada.WatchLock", "bundle identifier")
    require(plist.get("LSMinimumSystemVersion") == "14.0", "deployment target")
    require(plist.get("LSUIElement") is True, "menu-bar app metadata")
    require(plist.get("CFBundleIconFile") == "AppIcon.icns", "app icon metadata")
    icon = ROOT / "WatchLock/Resources/AppIcon.icns"
    require(icon.is_file() and icon.read_bytes().startswith(b"icns"), "app icon resource")
    require(bool(plist.get("NSBluetoothAlwaysUsageDescription")), "Bluetooth usage description")
    require("NSMainNibFile" not in plist, "old main nib")
    require(not plistlib.loads((ROOT / "WatchLock/WatchLock.entitlements").read_bytes()), "unexpected entitlements")
    project = (ROOT / "WatchLock.xcodeproj/project.pbxproj").read_text()
    for token in ("BLEUnlock", "Launcher", "MediaRemote", "login.framework", "DEVELOPMENT_TEAM", "PBXShellScriptBuildPhase", "PROVISIONING_PROFILE"):
        require(token not in project, "old project setting: " + token)
    # Compare only Swift file references with real fixed-directory build inputs.
    refs = re.findall(r'path = "([^"\n]+\.swift)";', project)
    require(set(refs) == {str(path.relative_to(ROOT)) for path in sources}, "Xcode/script source mismatch")
    require(len(refs) == len(sources), "duplicate Xcode source reference")
    require(project.count("isa = PBXBuildFile;") == len(sources) + 3, "Xcode Sources/resource count")
    build_script = (ROOT / "scripts/build-local.sh").read_text()
    require("sources=(WatchLock/Core/*.swift WatchLock/*.swift)" in build_script, "unexpected script source selection")
    require(all(path.parent in [ROOT / "WatchLock", ROOT / "WatchLock/Core"] for path in sources), "sources outside fixed build directories")
    binary = ROOT / "build/WatchLock.app/Contents/MacOS/WatchLock"
    if binary.exists():
        result = subprocess.run(["/usr/bin/nm", "-u", str(binary)], check=True, capture_output=True, text=True)
        for finding in forbidden(result.stdout):
            failures.append("direct undefined binary symbols: " + finding)
        bundle = ROOT / "build/WatchLock.app"
        expected = {"Contents/MacOS/WatchLock", "Contents/Info.plist", "Contents/PkgInfo",
                    "Contents/Resources/AppIcon.icns",
                    "Contents/Resources/LICENSE", "Contents/Resources/NOTICE", "Contents/_CodeSignature/CodeResources"}
        actual = {str(path.relative_to(bundle)) for path in bundle.rglob("*") if path.is_file()}
        require(actual == expected, "unexpected app bundle contents")
        bundled_icon = bundle / "Contents/Resources/AppIcon.icns"
        require(icon.is_file() and bundled_icon.is_file() and bundled_icon.read_bytes() == icon.read_bytes(), "bundled/source icon mismatch")
        require(plistlib.loads((bundle / "Contents/Info.plist").read_bytes()) == plist, "bundled/source metadata mismatch")
        result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)], check=True, capture_output=True)
        require(not result.stdout.strip() or not plistlib.loads(result.stdout), "unexpected signed entitlements")
        print("Checked: app source, metadata, Xcode/script parity, direct nm symbols, bundle, signed entitlements")
    else:
        print("NOT RUN: binary audit (build/WatchLock.app missing)")
    if failures:
        for failure in failures:
            print("FAIL:", failure)
        return 1
    print("PASS: listed static safety checks; not a proof of all network/runtime behaviour")
    return 0

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        raise SystemExit(audit())
