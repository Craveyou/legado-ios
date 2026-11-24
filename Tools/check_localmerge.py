#!/usr/bin/env python3
"""Static gates for the LocalLibrary merge:
1. every .swift in App/Features/LocalLibrary is registered in project.pbxproj
2. no iOS 17+ only API leaked into LocalLibrary sources (iOS 15 deployment target)
Exit code 0 = pass, 1 = fail.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Legado.xcodeproj", "project.pbxproj")
SRC = os.path.join(ROOT, "App", "Features", "LocalLibrary")

# iOS 17+ APIs that must not appear in LocalLibrary (iOS 15 target)
BANNED = [
    r"(?<!Reading)\bNavigationStack\b",
    r"\bContentUnavailableView\b",
    r"@Observable\b",
    r"\.onChange\(of:[^\{]*\{\s*_,",  # two-param onChange (iOS 17)
    r"navigationDestination\(isPresented:",
    r"\.contentTransition\(",
    r"\.presentationDetents\(",
    r"\.presentationDragIndicator\(",
    r"\.scrollContentBackground\(",
    r"\.scrollDismissesKeyboard\(",
    r"\.kerning\(",
    r"\bTable\s*\(",
    r"\bInspector\s*\(",
    r"\.buttonStyle\(\.borderless\)",
    r"\.foregroundStyle\([^)]*,[^)]*\)",  # dual-arg foregroundStyle is iOS 17
]

errors = []

# gate 1: registration
if os.path.isdir(SRC):
    pbx = open(PBX, encoding="utf-8").read()
    registered = set(re.findall(r"/\* ([A-Za-z0-9_]+\.swift) \*/", pbx))
    for f in sorted(os.listdir(SRC)):
        if not f.endswith(".swift"):
            continue
        if f not in registered:
            errors.append(f"[pbxproj] {f} 未在 project.pbxproj 登记")
    # gate 2: banned APIs
    for f in sorted(os.listdir(SRC)):
        if not f.endswith(".swift"):
            continue
        path = os.path.join(SRC, f)
        lines = open(path, encoding="utf-8").read().splitlines()
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for pat in BANNED:
                if re.search(pat, line):
                    errors.append(f"[ios17] {f}:{i} 命中禁用 API ({pat}): {stripped[:90]}")
                    break

if errors:
    print("LOCALMERGE CHECK FAILED:")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print("LOCALMERGE CHECK OK")
