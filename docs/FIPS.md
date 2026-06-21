# FIPS-140-3 Status — graph-storage

**REQ-ID:** REQ-FIPS-EXEMPT-001 — non-security crypto/hash/RNG sites are
allow-listed (exempt) from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** The **non-security** cryptographic, hashing, and random-number
operations in this library are **exempt** from the workspace FIPS-140-3
routing requirement (see `fips` package spec
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). The exempt sites
below produce, protect, or verify no secret, key, credential, authentication
tag, or signature; therefore none is routed through the `crypto_backend` seam
and none links the OpenSSL FIPS provider. When a consumer builds with
`-Dfips=true`, these sites are unaffected: this annotation work adds no
`-Dfips` flag and changes no behavior.

## Exempt call sites

| File:Line | Primitive | Use | Why non-security (exempt) |
|-----------|-----------|-----|---------------------------|
| `src/shard_uuid.zig:11` | BLAKE3 (`std.crypto.hash.Blake3`) | Deterministic per-shard UUID derivation | Collision-resistant naming; not a secret, key, or auth tag |
| `src/property_chain_index.zig:103,112,159` | `std.hash.Wyhash` | Property value fingerprint for index equality lookup | Lookup key only; not a secret |
| `src/page.zig:52` | CRC32C (`std.hash.crc.Crc32Iscsi`) | Page-body corruption check | Corruption detection; not authentication |
| `src/wal_record.zig:58,178` | CRC32C (`std.hash.crc.Crc32Iscsi`) | WAL record corruption check | Corruption detection; not authentication |
| `src/registry.zig:6` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/btree.zig:6` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/label_dict.zig:6` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/migration.zig:16` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/index_snapshot.zig:9` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/index_catalog.zig:6` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication |
| `src/backup.zig:23` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication (HMAC auth on backups is separate — see below) |
| `src/manifest.zig:6` | CRC32C alias | On-disk record integrity | Corruption detection; not authentication (HMAC manifest auth is separate — see below) |
| `src/recovery.zig:1165` | CRC32C alias (test) | On-disk record integrity in recovery test | Corruption detection; not authentication |
| `src/verify.zig:835` | CRC32C alias (test) | On-disk record integrity in verify test | Corruption detection; not authentication |

Annotating the file-scope `const Crc32 = ...` alias covers every `Crc32.hash(...)`
/ `Crc32.init()` use in that file; the alias is the single declaration the
zlint rule keys on. Line numbers are pre-annotation approximations.

## Security crypto NOT exempt (deferred to the security-routing plan)

The following are genuine security primitives and are **explicitly NOT touched**
by this annotation work. They are deferred to the separate incidental
route-through-seam plan, which routes them through the `crypto_backend` seam
under `-Dfips=true`:

- `src/encryption.zig` — AES-256-GCM transparent data encryption (TDE)
  confidentiality.
- `src/manifest.zig` / `src/backup.zig` — HMAC-SHA256 + `timing_safe` manifest
  and backup authentication.
- Key-buffer `secureZero` calls in `src/recovery.zig`, `src/file_manager.zig`,
  `src/config.zig`, `src/encryption.zig`, `src/backup.zig` — key-material
  hygiene, which belongs with the security path.

These are documented here only to delimit scope; they carry no `fips-exempt`
annotation because they are NOT exempt.

## zlint allow-list

Every non-security site above carries an inline
`// fips-exempt: non-security — <reason>` annotation so the `zlint` FIPS rule
treats it as allow-listed rather than a violation. Adding a new non-security
`std.crypto` / `std.hash` / `std.Random` use to this library REQUIRES adding
both the inline annotation and a row in the table above.
