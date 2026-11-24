#!/usr/bin/env python3
"""Register Swift files in App/Features/LocalLibrary/ into project.pbxproj.

Idempotent: files already present (by basename) are skipped. IDs are derived
from a stable prefix + index so repeated runs never duplicate entries.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Legado.xcodeproj", "project.pbxproj")
SRC = os.path.join(ROOT, "App", "Features", "LocalLibrary")
GROUP_NAME = "LocalLibrary Feature"
APP_GROUP = "A30000000000000000000001"  # App group id
PREFIX_B = "L1"  # PBXBuildFile
PREFIX_R = "L2"  # PBXFileReference
PREFIX_G = "L3"  # PBXGroup


def bid(n): return f"{PREFIX_B}{n:022X}"
def rid(n): return f"{PREFIX_R}{n:022X}"
def gid(n): return f"{PREFIX_G}{n:022X}"


def read():
    with open(PBX, "r", encoding="utf-8") as f:
        return f.read()


def write(s):
    with open(PBX, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


def insert_after_section(text, section, line):
    marker = f"/* Begin {section} */\n"
    if marker not in text:
        raise SystemExit(f"missing section {section}")
    return text.replace(marker, marker + line, 1)


def main():
    if not os.path.isdir(SRC):
        print("no LocalLibrary dir; nothing to register")
        return
    files = sorted(
        f for f in os.listdir(SRC) if f.endswith(".swift")
    )
    if not files:
        print("no swift files; nothing to register")
        return

    text = read()
    changed = False

    # which basenames already registered
    known = set(re.findall(r"/\* ([A-Za-z0-9_]+\.swift) \*/", text))
    todo = [f for f in files if f not in known]
    if not todo:
        print("all LocalLibrary files already registered")
        return

    start = len(re.findall(r"L1[0-9A-F]{22} /\* .*\.swift in Sources \*/", text))
    base = max(start, 1)

    group_entries = []
    for i, name in enumerate(todo):
        n = base + i
        b, r = bid(n), rid(n)
        # PBXBuildFile
        text = insert_after_section(
            text, "PBXBuildFile section",
            f"\t\t{b} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {r} /* {name} */; }};\n")
        # PBXFileReference
        text = insert_after_section(
            text, "PBXFileReference section",
            f"\t\t{r} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
        # PBXSourcesBuildPhase: main target phase uses "files = (" (not "children")
        main_phase = "D30000000000000000000002 /* Sources */ = {\n"
        pos = text.index(main_phase) + len(main_phase)
        fs = text.index("files = (", pos)
        end = text.index(");", fs)
        text = text[:end] + f"\t\t\t\t{b} /* {name} in Sources */,\n" + text[end:]
        group_entries.append(f"\t\t\t\t{r} /* {name} */,\n")
        print(f"registered {name}: {b} / {r}")
        changed = True

    # create LocalLibrary group if missing
    if f"{gid(1)} /* {GROUP_NAME} */" not in text:
        group_block = (
            f"\t\t{gid(1)} /* {GROUP_NAME} */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            + "".join(group_entries)
            + "\t\t\t);\n"
            "\t\t\tpath = Features/LocalLibrary;\n"
            "\t\t\tsourceTree = \"<group>\";\n"
            "\t\t};\n"
        )
        text = insert_after_section(text, "PBXGroup section", group_block)
        # add to App group children
        app_marker = f"\t\t{APP_GROUP} /* App */ = {{\n"
        p = text.index(app_marker)
        ch = text.index("children = (", p)
        end = text.index(");", ch)
        text = text[:end] + f"\t\t\t\t{gid(1)} /* {GROUP_NAME} */,\n" + text[end:]
        print(f"created group {GROUP_NAME}: {gid(1)}")
        changed = True
    else:
        # group exists: append new refs to its children
        gmark = f"\t\t{gid(1)} /* {GROUP_NAME} */ = {{\n"
        p = text.index(gmark)
        ch = text.index("children = (", p)
        end = text.index(");", ch)
        text = text[:end] + "".join(group_entries) + text[end:]
        print("appended refs to existing LocalLibrary group")

    if changed:
        write(text)
        print("project.pbxproj updated")
    else:
        print("no changes")


if __name__ == "__main__":
    main()
