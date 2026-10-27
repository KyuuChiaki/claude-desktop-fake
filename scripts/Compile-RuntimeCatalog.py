"""Compile the single reviewed runtime catalogue into bounded no-CRT tables."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def octets(text):
    return "{" + ",".join(f"0x{x:02x}" for x in bytes.fromhex(text)) + "}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    data = args.catalog.read_bytes()
    catalog = json.loads(data)
    if catalog["schemaVersion"] != 2 or catalog["windowsBuild"] != 19045:
        raise ValueError("Unsupported catalogue schema or OS")
    if catalog["normalization"] != {"algorithm": "CDFENGINE1", "excludedSections": [".rsrc"], "ignoreRelocPlacement": True,
                                     "fuseSentinel": "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX", "fuseVersion": 1,
                                     "fuseBytes": 9, "allowedFuseStates": "01"}:
        raise ValueError("Unimplemented normalization rule")
    if len(catalog["abis"]) != 1 or any(catalog["abis"][0][key] != value for key, value in {
        "architecture": "AMD64", "stringBytes": 24, "stringShortMaximumBytes": 22,
        "handleScopeBytes": 24, "tryCatchBytes": 48, "cldrMapping": "cldr48-world",
    }.items()):
        raise ValueError("Unimplemented ABI bridge")
    lines = ["// Generated from profiles/runtime-adapters.json. Do not edit.",
             f"constexpr ULONG catalog_revision={catalog['revision']};",
             f"const BYTE catalog_hash[32]={octets(hashlib.sha256(data).hexdigest())};"]
    families = catalog["abis"]
    for ai, family in enumerate(families):
        if len(family["sites"]) != 14 or [site["role"] for site in family["sites"]] != list(range(14)):
            raise ValueError("Every ABI needs the ordered complete role set")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,63}", family["id"]):
            raise ValueError("Invalid ABI identifier")
        entries = list(family["sites"])
        for site in family["sites"]:
            for variant in site.get("variants", []):
                entries.append({**site, **variant, "role": site["role"]})
        for ri, site in enumerate(entries):
            code, mask = bytes.fromhex(site["bytes"]), bytes.fromhex(site["mask"])
            prefix = bytes.fromhex(site["prefix"])
            if (len(code) != len(mask) or not 12 <= len(code) <= 4096 or
                    not 12 <= len(prefix) <= len(code) or not code.startswith(prefix) or
                    sum(byte.bit_count() for byte in mask[:12]) < 64 or type(site["offset"]) is not int or
                    not 0 <= site["offset"] < len(code)):
                raise ValueError("Invalid or overly short function locator")
            lines += [f"const BYTE code_{ai}_{ri}[]={octets(site['bytes'])};",
                      f"const BYTE mask_{ai}_{ri}[]={octets(site['mask'])};"]
            references = site.get("references", [])
            for qi, reference in enumerate(references):
                if not 0 <= reference["displacement"] <= len(code)-4 or not 0 <= reference["next"] <= len(code):
                    raise ValueError("Invalid reference boundary")
                if ("targetRole" in reference) == ("bytes" in reference):
                    raise ValueError("A reference must select a role or constant")
                if "targetRole" in reference and not 0 <= reference["targetRole"] < 14:
                    raise ValueError("Unknown referenced role")
                if "bytes" in reference:
                    if not 1 <= len(bytes.fromhex(reference["bytes"])) <= 64:
                        raise ValueError("Invalid referenced constant")
                    lines.append(f"const BYTE refdata_{ai}_{ri}_{qi}[]={octets(reference['bytes'])};")
            if references:
                lines.append(f"const Reference refs_{ai}_{ri}[]={{")
                for qi, reference in enumerate(references):
                    target = reference.get("targetRole", 14)
                    payload = f"refdata_{ai}_{ri}_{qi}" if "bytes" in reference else "nullptr"
                    lines.append("{" + f"{reference['displacement']},{reference['next']},{target},{len(bytes.fromhex(reference.get('bytes', '')))},{payload}" + "},")
                lines.append("};")
        lines.append(f"const Template templates_{ai}[]={{")
        for ri, site in enumerate(entries):
            lines.append("{" + f"{site['role']},{site['offset']},{len(bytes.fromhex(site['bytes']))},"
                         f"{int(site['captureOnly'])},{int(site['unwind'])},code_{ai}_{ri},mask_{ai}_{ri},"
                         f"{'refs_'+str(ai)+'_'+str(ri) if site.get('references') else 'nullptr'},{len(site.get('references', []))}" + "},")
        lines.append("};")
    lines.append("const Family families[]={")
    for ai, family in enumerate(families):
        count=len(family["sites"])+sum(len(site.get("variants", [])) for site in family["sites"])
        lines.append("{" + f"L\"{family['id']}\",templates_{ai},{count}" + "},")
    lines.append("};\nconst Build builds[]={")
    if not 1 <= len(catalog["builds"]) <= 64:
        raise ValueError("Unsupported runtime build count")
    for build in catalog["builds"]:
        if (not re.fullmatch(r"[A-Za-z0-9._-]{1,95}", build["id"]) or
                not 0 <= build["abiIndex"] < len(families) or len(build["rvas"]) != 14 or
                not all(type(rva) is int and 0 < rva < 0x70000000 for rva in build["rvas"]) or
                len(bytes.fromhex(build["engineSha256"])) != 32 or
                not re.fullmatch(r"[A-Za-z0-9 ._/-]{1,63}", build["description"])):
            raise ValueError("Invalid runtime build")
        rvas = ",".join(str(x) for x in build["rvas"])
        lines.append("{" + f"L\"{build['id']}\",L\"{build['description']}\",{build['abiIndex']},"
                     f"{octets(build['engineSha256'])},{{{rvas}}}" + "},")
    lines.append("};\nconst Exact exact_images[]={")
    for image in catalog["images"]:
        if len(bytes.fromhex(image["sha256"])) != 32 or not 0 <= image["buildIndex"] < len(catalog["builds"]):
            raise ValueError("Invalid exact image reference")
        lines.append("{" + f"{octets(image['sha256'])},{image['buildIndex']}" + "},")
    lines.append("};")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(lines) + "\n"
    if not args.output.exists() or args.output.read_text(encoding="utf-8") != text:
        args.output.write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
