#!/usr/bin/env python3
"""Convert IEEE oui.csv (MA-L) into a sorted `PREFIX\tShort Name` TSV.

Usage: python3 -I oui_clean.py <oui.csv> <out.tsv>
"""
import csv
import re
import sys

# Trailing legal/corporate suffixes, removed repeatedly (case-insensitive).
SUFFIXES = [
    "Pte. Ltd.", "Pte Ltd", "Pte.", "Pte", "Co., Ltd.", "Co.,Ltd.", "Co., Ltd", "Co.,Ltd", "Co. Ltd.", "Co. Ltd",
    "Co.Ltd.", "Co.Ltd", "Company Limited", "Co. Limited", "Co., Limited", "Co.,Limited",
    "Inc.", "Inc", "Incorporated", "Ltd.", "Ltd", "Limited", "L.L.C.", "LLC", "L.P.", "LP",
    "Corporation", "Corp.", "Corp", "GmbH & Co. KG", "GmbH & Co KG", "GmbH", "mbH", "AG", "KG",
    "S.A.", "SA", "S.A.S.", "SAS", "S.p.A.", "SpA", "S.r.l.", "Srl", "S.L.", "SL", "B.V.", "BV",
    "N.V.", "NV", "Oy", "Oyj", "AB", "A/S", "AS", "ASA", "Pty", "Pty.", "PLC", "Plc", "Sdn. Bhd.",
    "Sdn Bhd", "Bhd", "S.de R.L. de C.V.", "S.A. de C.V.", "de C.V.", "Co.", "Co", "Company",
    "Group", "Holdings", "International",
]
_suffix_re = re.compile(
    r"[\s,.]*\b(?:" + "|".join(re.escape(s) for s in sorted(SUFFIXES, key=len, reverse=True)) + r")\s*$",
    re.IGNORECASE,
)

# Brand overrides: first regex (on the raw name) that matches wins.
OVERRIDES = [
    (r"^Apple\b", "Apple"),
    (r"^Samsung Electronics", "Samsung Electronics"),
    (r"^Samsung\b", "Samsung"),
    (r"^TP-?Link", "TP-Link"),
    (r"^Google\b", "Google"),
    (r"^Amazon\b", "Amazon"),
    (r"^Sonos\b", "Sonos"),
    (r"^Espressif\b", "Espressif"),
    (r"^Raspberry Pi", "Raspberry Pi"),
    (r"^Ubiquiti", "Ubiquiti"),
    (r"^Netgear", "Netgear"),
    (r"^ASUSTek", "ASUS"),
    (r"^Hon Hai|^Foxconn", "Foxconn"),
    (r"^Intel\b", "Intel"),
    (r"^Xiaomi|^Beijing Xiaomi", "Xiaomi"),
    (r"^Huawei Device", "Huawei"),
    (r"^Huawei", "Huawei Technologies"),
    (r"^Synology", "Synology"),
    (r"^QNAP", "QNAP"),
    (r"^Signify|^Philips Lighting", "Philips Hue (Signify)"),
    (r"^Philips\b", "Philips"),
    (r"^Roku\b", "Roku"),
    (r"^Nintendo", "Nintendo"),
    (r"^Sony Interactive", "Sony PlayStation"),
    (r"^Sony\b", "Sony"),
    (r"^LG Electronics|^LG Innotek", "LG"),
    (r"^AVM\b", "AVM"),
    (r"^Hewlett[ -]Packard|^HP Inc", "HP"),
    (r"^Murata", "Murata"),
    (r"^Lite-?on", "Liteon"),
    (r"^AzureWave", "AzureWave"),
    (r"^Tuya", "Tuya"),
    (r"^Allterco|^Shelly", "Shelly"),
    (r"^Nest Labs", "Nest"),
    (r"^Microsoft", "Microsoft"),
    (r"^Dell\b", "Dell"),
    (r"^Cisco Meraki", "Cisco Meraki"),
    (r"^Cisco", "Cisco"),
    (r"^Motorola Mobility", "Motorola"),
    (r"^OnePlus", "OnePlus"),
    (r"^Guangdong Oppo|^OPPO", "OPPO"),
    (r"^vivo Mobile", "vivo"),
    (r"^Nokia\b", "Nokia"),
    (r"^Lenovo", "Lenovo"),
    (r"^Brother Industries", "Brother"),
    (r"^Canon\b", "Canon"),
    (r"^Seiko Epson", "Epson"),
    (r"^Panasonic", "Panasonic"),
    (r"^Arcadyan", "Arcadyan"),
    (r"^Sagemcom", "Sagemcom"),
    (r"^zte\b", "ZTE"),
]
OVERRIDES = [(re.compile(p, re.IGNORECASE), v) for p, v in OVERRIDES]


def titlecase_word(w: str) -> str:
    # Only touch ALL-CAPS words longer than 4 letters; keep acronyms like HP, LG, ZTE, QNAP.
    letters = [c for c in w if c.isalpha()]
    if len(letters) > 4 and all(c.isupper() for c in letters):
        return "-".join(p[:1].upper() + p[1:].lower() for p in w.split("-"))
    return w


def clean(name: str) -> str:
    name = " ".join(name.split())  # trim + collapse whitespace
    for rx, value in OVERRIDES:
        if rx.search(name):
            return value
    prev = None
    while prev != name:
        prev = name
        name = _suffix_re.sub("", name).strip(" ,.;-")
    if not name:
        name = " ".join(prev.split())
    return " ".join(titlecase_word(w) for w in name.split(" "))


def main(src: str, dst: str) -> None:
    entries = {}
    with open(src, newline="", encoding="utf-8", errors="replace") as f:
        for row in csv.DictReader(f):
            prefix = (row.get("Assignment") or "").strip().upper()
            org = (row.get("Organization Name") or "").strip()
            if len(prefix) != 6 or not all(c in "0123456789ABCDEF" for c in prefix) or not org:
                continue
            name = clean(org).replace("\t", " ")
            if name:
                entries[prefix] = name
    with open(dst, "w", encoding="utf-8", newline="\n") as out:
        for prefix in sorted(entries):
            out.write(f"{prefix}\t{entries[prefix]}\n")
    print(f"wrote {len(entries)} entries to {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: oui_clean.py <oui.csv> <out.tsv>")
    main(sys.argv[1], sys.argv[2])
