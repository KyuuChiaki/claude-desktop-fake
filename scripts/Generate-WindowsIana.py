"""Regenerate the pinned CLDR 48 world-default Windows to IANA mapping."""

import argparse
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = "9cf3db6a31fb382fee21b70be6feba1e82766b0fcd06e6261fb7936a73e537ff"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "third_party/cldr/windowsZones.xml")
    parser.add_argument("--output", type=Path, default=ROOT / "include/windows_iana_cldr48.inc")
    args = parser.parse_args()
    data = args.source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        parser.error("The source is not the pinned Unicode CLDR release-48 windowsZones.xml")
    lines = [
        "// Unicode CLDR release-48 windowsZones.xml, territory 001 mappings.",
        f"// SHA256: {SOURCE_SHA256}",
        "// Copyright Unicode, Inc. Distributed under Unicode License v3.",
    ]
    names = set()
    for zone in ET.fromstring(data).iter("mapZone"):
        if zone.attrib["territory"] != "001":
            continue
        windows, iana = zone.attrib["other"], zone.attrib["type"]
        if windows in names or any(c in windows + iana for c in '\\"\n\r') or " " in iana:
            parser.error("Unexpected duplicate or ambiguous mapping")
        names.add(windows)
        lines.append(f'{{L"{windows}",L"{iana}"}},')
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Generated {len(names)} mappings: {args.output}")


if __name__ == "__main__":
    main()
