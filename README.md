# Pixel Agency Library

`ImageLibrary`, the job ledger and asset library behind [Pixel Agency Desktop](https://github.com/xocialize/pixel-agency-desktop),
as a Swift package. Both share one SQLite file (GRDB), so "the job succeeded" and "its outputs exist" commit in one
transaction, and the bytes live beside it in a content-addressed blob store.

It was ML[X] Image Server's (`Packages/ImageServerKit`, at c96e6dc). It moved here because the Image Server retires when
Gaea's image phase exits, and nothing Desktop links may retire until it lives in a shared library (Gaea decision G-20,
AB-D-0182; work order AB-T-0358).

## Install

```swift
.package(url: "https://github.com/xocialize/pixel-agency-library.git", from: "0.1.0"),
// target dependency:
.product(name: "ImageLibrary", package: "pixel-agency-library"),
```

macOS 26. Its dependencies are GRDB and the wire types from
[mlx-image-runtime](https://github.com/xocialize/mlx-image-runtime) (`ImageServerAPI`, with MLXToolKit's vocabulary).
Nothing it links builds MLX.

## What is in it

Most of it is `AssetLibrary` and its extensions, one file per area.

| File | What it holds |
|---|---|
| `ServerDatabase.swift` | `ServerDatabase`, the one SQLite file and its migrations (`v1-ledger-library` through `v5-duplicate-dismissals`), and `SettingsStore`. |
| `BlobStore.swift` | `BlobStore`: content-addressed files at `blobs/sha256/ab/cd/<hex>.<ext>`, written to `tmp/` and renamed in, so a crash leaves at most an orphan file. |
| `AssetLibrary.swift`, `LibraryCMS.swift`, `CMSSchema.swift` | Assets, generation provenance, companies and projects, tags, uploads and their rights, edits. |
| `JobLedger.swift` | `JobLedger` and `LedgerEntry`: the persisted job table a scheduler writes through on every state change. |
| `BrandKits.swift` | Revisioned brand kits per company, importing `style.json` (marquee-brand-spec 1.1). |
| `Collections.swift` | Folders (manual, nestable) and smart collections (a saved query, evaluated live). |
| `LibrarySearch.swift` | FTS5 search (BM25 with column weights), structured filters and facet counts. |
| `Duplicates.swift` | Identical bytes, or 64-bit perceptual hashes within a few bits, grouped transitively. |
| `Descriptions.swift` | What a vision model wrote for an asset, kept with the model and its licence. |
| `ImageFacts.swift`, `ImageEncoding.swift` | Facts computed once per blob (type, size, alpha, dHash, palette, EXIF/IPTC); ImageIO encode and decode that writes provenance into the file; `ThumbnailCache`. |
| `Sweeper.swift` | Retention: expired uploads go to the trash, and the trash is purged after 30 days. |

## Tests

```bash
swift test
```

## Licence

MIT. Parts are adapted from the author's MarqueeDataKit and were re-licensed MIT in ML[X] Image Server.
