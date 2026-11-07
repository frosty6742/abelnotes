# Sharp zoom of imported PDF pages

An imported PDF page is stored as a PNG (150 DPI, less for long PDFs), so
zooming in enlarges the bitmap. Since 0.37.10 the import also keeps the PDF,
and once a pinch or pan settles the visible part is rendered again from it,
in tiles, at the density the screen needs.

## Storage

Next to `pages/` and `assets/`, both in the local store and in the server's
delta folder:

```
sources/<importId>.pdf    the imported pages only, password removed
sources/<importId>.json   {"v":1,"pdf":"<importId>.pdf","pages":{"<asset key>": <page>}}
```

* **Old builds never see it.** Builds before 0.37.10 only list `pages/` and
  `assets/` and only delete files in those two, so they neither download,
  decode, flag as corrupt nor prune a `sources/` file. Nothing inside
  `assets/` would be safe: old builds decode every asset and prune the
  unreferenced ones.
* **The link is a separate file, not a field on the image.** Freezed drops
  unknown keys, so an old build re-saving the page would lose a field; it
  never rewrites `sources/<id>.json`.
* **Files are immutable**, one pair per import, so devices never conflict:
  sync just copies what each side lacks, PDF before index.
* The `.abelnote` package carries `sources/` too. A package that doesn't
  (written by an old build, or rebuilt from memory) never removes the copy
  already on disk, and the server's delta folder still has it.

## Rendering

* `PdfTileGrid` picks a level that doubles the PNG density each step until it
  reaches the screen's, capped at 16 px/pt; tiles are 512 px.
* `PdfTileScheduler` renders the visible tiles nearest-first, then a one-tile
  ring for panning, one at a time; a new viewport drops the stale queue.
* `PdfTileCache` holds decoded tiles under a byte cap (48 MB on phones and
  tablets, 128 MB elsewhere), least recently used out first.
* The painter draws the PNG, then the cached tiles of the wanted level and the
  coarser ones over it, clipped to the image. The page picture is re-recorded
  when tiles land, at most every 60 ms.
* Rotated images keep the PNG.

## Cleanup

An import none of whose pages is left is retired: `<id>.gone` replaces its
files, and every device that syncs deletes its copies instead of uploading
them back. Only imports older than seven days, and only while this copy
matches the server with every page loaded: a device that hasn't pulled a
fresh import's pages yet must not take them for deleted. A wrong call costs
only the sharp zoom; the pages keep their PNG.

## Not covered

* Pages imported before 0.37.10 stay PNG-only until imported again.
* A page copied into another notebook through the pages tray keeps the PNG
  only. A duplicated notebook copies `sources/` along (same asset keys).
