# Identification database sources

Generated on 2026-10-02 by `pineapple-pager/tools/gen_btdb.py`. The raw
downloads are not committed; only the derived gzip'd TSV tables in this
directory (embedded into RF-BUDDY with `//go:embed`).

| Table | Source URL | Entries |
|-------|------------|---------|
| `companies.tsv.gz` | https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/company_identifiers/company_identifiers.yaml | 4041 |
| `members.tsv.gz` | https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/uuids/member_uuids.yaml | 715 |
| `services.tsv.gz` | https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/uuids/service_uuids.yaml | 76 |
| `appearance.tsv.gz` | https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/core/appearance_values.yaml | 342 (categories + subcategories) |
| `oui.tsv.gz` | https://www.wireshark.org/download/automated/data/manuf (IEEE OUI registry) | 39905 (24-bit prefixes; private/IEEE placeholder rows skipped) |

Total embedded size is about 318 KB (limit 1.5 MB).

## Regenerating

Use the `tools/gen_btdb.py` generator from the project repository
(https://github.com/ninedter/DEFCON-DEFENSE), run from its `pineapple-pager/`
directory:

    python3 tools/gen_btdb.py --download --src /tmp/btsrc --out <RF-BUDDY>/ui/btdb

Output is deterministic (sorted rows, gzip mtime 0): the same sources always
produce byte-identical files. Without `--download`, `--src` must already hold
`company_identifiers.yaml`, `member_uuids.yaml`, `service_uuids.yaml`,
`appearance_values.yaml` and `manuf`.

Brands follow the normalization rules in
`docs/superpowers/plans/2026-10-02-rf-buddy-bt-identification.md`.
