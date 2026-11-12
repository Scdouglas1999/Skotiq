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
hash above. `built_in_catalogs_test.dart` fails while they disagree.
