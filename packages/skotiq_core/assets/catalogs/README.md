# Built-in catalog data

`NGC.csv` is the OpenNGC database (release 2023.12), compiled by Mattia Verga
and the OpenNGC contributors: <https://github.com/mattiaverga/OpenNGC>.
It ships unmodified, byte for byte the file the Catalogs settings page
downloads (SHA-256
`840fe0c9ee1332e551b2e722a0e92726cd7b157914a3d2177602832aadd3aa9e`, pinned as
`SkyCatalog.dso.sha256` in `skotiq_astro`). On first start Skotiq installs it
into its catalog folder, so deep-sky names resolve and the sky view shows
deep-sky objects without an internet connection.

The data is licensed under the Creative Commons Attribution-ShareAlike 4.0
International license: <https://creativecommons.org/licenses/by-sa/4.0/>.
That data license does not apply to Skotiq's program code. `NOTICE.txt` is
the attribution that ships with the file; the app lists it under Settings >
About > Open-source licenses.

To move to a newer OpenNGC release, replace the file, update the version and
`sha256` of `SkyCatalog.dso` and the release asset together, and update the
hash above. `built_in_catalogs_test.dart` fails while they disagree. Then
rebuild the nebula light table (below), which is keyed by OpenNGC names.

## Nebula light table

OpenNGC files many bright nebulae as plain `Neb` or `Cl+N` (cluster with
nebula) without saying whether they glow in emission lines or reflect
starlight, which decides whether a target is imaged in narrowband or LRGB.
`nebula_light.csv` holds that class for every OpenNGC nebula that a
published emission or reflection catalog matches (Sharpless 1959, RCW 1960,
the WISE HII region catalog, Cederblad 1946, Magakian 2003). When Skotiq
loads OpenNGC, a listed nebula becomes an emission nebula, a reflection
nebula, or a cluster with an emission or reflection nebula; an unlisted one
keeps its OpenNGC type.

The table is built, never edited:
`tools/catalog_prep/nebula_light/build_nebula_light.py` reads `NGC.csv` and
the raw source files in `tools/catalog_prep/nebula_light/sources/` (each
with its URL, retrieval date, SHA-256, citation and terms of use in
`provenance.json`) and writes this file. The matching rule is stated at the
top of that script. `--check` fails when this file is not what the sources
build. The table derives from OpenNGC and carries its license; `NOTICE.txt`
credits the sources.
