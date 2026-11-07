import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Edge of a square tile, in device pixels.
const int kPdfTileSize = 512;

/// One tile of a PDF-backed image at a zoom level: [level] doubles the base
/// raster density each step, ([col], [row]) index the level's tile grid.
@immutable
class PdfTileKey {
  final String assetPath;
  final int level;
  final int col;
  final int row;
  const PdfTileKey(this.assetPath, this.level, this.col, this.row);

  @override
  bool operator ==(Object other) =>
      other is PdfTileKey &&
      other.assetPath == assetPath &&
      other.level == level &&
      other.col == col &&
      other.row == row;

  @override
  int get hashCode => Object.hash(assetPath, level, col, row);

  @override
  String toString() => 'PdfTileKey($assetPath L$level $col,$row)';
}

/// Raster geometry of one image element backed by a PDF page.
@immutable
class PdfTileGrid {
  /// Element size in page points.
  final double widthPt;
  final double heightPt;

  /// Device pixels per page point of the stored PNG (level 0's parent).
  final double baseDensity;

  const PdfTileGrid({
    required this.widthPt,
    required this.heightPt,
    required this.baseDensity,
  });

  /// Pixels per point at [level] (level 1 = twice the PNG).
  double densityAt(int level) => baseDensity * math.pow(2, level);

  /// Full raster size at [level], in pixels.
  ({double w, double h}) fullSize(int level) {
    final d = densityAt(level);
    return (w: widthPt * d, h: heightPt * d);
  }

  /// Level whose density first reaches [screenDensity], or null when the PNG
  /// is already sharp enough. [maxDensity] px/pt caps the request.
  int? levelFor(double screenDensity, {double maxDensity = 16}) {
    final want = math.min(screenDensity, maxDensity);
    if (want <= baseDensity * 1.15) return null;
    var level = 1;
    while (densityAt(level) < want * 0.999) {
      level++;
    }
    return level;
  }

  /// Tiles of [level] covering [visiblePt] (element-local points), grown by
  /// [marginTiles] on every side, nearest to the visible centre first.
  List<(int col, int row)> tilesFor(int level, ui.Rect visiblePt,
      {int marginTiles = 0}) {
    final full = fullSize(level);
    final d = densityAt(level);
    final cols = (full.w / kPdfTileSize).ceil();
    final rows = (full.h / kPdfTileSize).ceil();
    final clip = visiblePt.intersect(ui.Rect.fromLTWH(0, 0, widthPt, heightPt));
    if (clip.isEmpty || cols == 0 || rows == 0) return const [];
    final c0 =
        math.max(0, (clip.left * d / kPdfTileSize).floor() - marginTiles);
    final r0 = math.max(0, (clip.top * d / kPdfTileSize).floor() - marginTiles);
    final c1 = math.min(cols - 1,
        ((clip.right * d - 1e-6) / kPdfTileSize).floor() + marginTiles);
    final r1 = math.min(rows - 1,
        ((clip.bottom * d - 1e-6) / kPdfTileSize).floor() + marginTiles);
    final cx = clip.center.dx * d / kPdfTileSize - 0.5;
    final cy = clip.center.dy * d / kPdfTileSize - 0.5;
    final out = <(int, int)>[
      for (var r = r0; r <= r1; r++)
        for (var c = c0; c <= c1; c++) (c, r),
    ];
    double dist((int, int) t) =>
        (t.$1 - cx) * (t.$1 - cx) + (t.$2 - cy) * (t.$2 - cy);
    out.sort((a, b) => dist(a).compareTo(dist(b)));
    return out;
  }

  /// Pixel rectangle of a tile inside the level's full raster.
  ui.Rect tilePixels(int level, int col, int row) {
    final full = fullSize(level);
    final x = (col * kPdfTileSize).toDouble();
    final y = (row * kPdfTileSize).toDouble();
    return ui.Rect.fromLTRB(x, y, math.min(x + kPdfTileSize, full.w),
        math.min(y + kPdfTileSize, full.h));
  }

  /// Where a tile lands, in element-local points.
  ui.Rect tilePoints(int level, int col, int row) {
    final px = tilePixels(level, col, row);
    final d = densityAt(level);
    return ui.Rect.fromLTRB(
        px.left / d, px.top / d, px.right / d, px.bottom / d);
  }
}

/// A rendered tile and where it goes, in element-local points.
class PdfTile {
  final PdfTileKey key;
  final ui.Image image;
  final ui.Rect dest;
  PdfTile(this.key, this.image, this.dest);

  int get bytes => image.width * image.height * 4;
}

/// LRU of rendered tiles bounded by decoded bytes.
class PdfTileCache {
  final int maxBytes;
  final LinkedHashMap<PdfTileKey, PdfTile> _tiles = LinkedHashMap();
  int _bytes = 0;

  PdfTileCache({required this.maxBytes});

  int get bytes => _bytes;
  int get length => _tiles.length;

  PdfTile? peek(PdfTileKey key) => _tiles[key];

  bool contains(PdfTileKey key) => _tiles.containsKey(key);

  /// Marks [key] as recently used.
  void touch(PdfTileKey key) {
    final t = _tiles.remove(key);
    if (t != null) _tiles[key] = t;
  }

  void put(PdfTile tile) {
    final old = _tiles.remove(tile.key);
    if (old != null) {
      _bytes -= old.bytes;
      if (!identical(old.image, tile.image)) old.image.dispose();
    }
    _tiles[tile.key] = tile;
    _bytes += tile.bytes;
    while (_bytes > maxBytes && _tiles.length > 1) {
      final k = _tiles.keys.first;
      final t = _tiles.remove(k)!;
      _bytes -= t.bytes;
      t.image.dispose();
    }
  }

  /// Tiles of [assetPath] at levels up to [maxLevel], coarse first, so the
  /// sharper ones paint over them.
  List<PdfTile> tilesOf(String assetPath, int maxLevel) {
    final out = [
      for (final t in _tiles.values)
        if (t.key.assetPath == assetPath && t.key.level <= maxLevel) t,
    ];
    out.sort((a, b) => a.key.level.compareTo(b.key.level));
    return out;
  }

  void clear() {
    for (final t in _tiles.values) {
      t.image.dispose();
    }
    _tiles.clear();
    _bytes = 0;
  }
}

/// Renders one tile: the [pixels] rectangle of the page raster whose full
/// size is [fullW] x [fullH]. Null when the page can't be rendered.
typedef PdfTileRenderer = Future<ui.Image?> Function(
    String assetPath, ui.Rect pixels, double fullW, double fullH);

/// What the viewport needs from one PDF-backed element.
@immutable
class PdfTileRequest {
  final String assetPath;
  final PdfTileGrid grid;

  /// Visible part of the element, in element-local points.
  final ui.Rect visiblePt;

  /// Device pixels per page point on screen.
  final double screenDensity;

  const PdfTileRequest({
    required this.assetPath,
    required this.grid,
    required this.visiblePt,
    required this.screenDensity,
  });
}

/// Keeps the visible tiles of PDF-backed images rendered: one tile at a
/// time, newest viewport first, stale work dropped.
class PdfTileScheduler {
  final PdfTileCache cache;
  final PdfTileRenderer render;

  /// Bumped when tiles land; the painter repaints on it.
  final ValueNotifier<int> version = ValueNotifier(0);

  final Map<String, int> _wantedLevel = {};
  List<(PdfTileKey, PdfTileGrid)> _queue = const [];
  bool _running = false;
  bool _disposed = false;
  Timer? _bump;

  PdfTileScheduler({required this.cache, required this.render});

  /// Level painted for [assetPath] right now, or null for PNG only.
  int? wantedLevel(String assetPath) => _wantedLevel[assetPath];

  /// Tiles to paint over the PNG of [assetPath], coarse first.
  List<PdfTile> tilesFor(String assetPath) {
    final level = _wantedLevel[assetPath];
    if (level == null) return const [];
    return cache.tilesOf(assetPath, level);
  }

  /// New viewport. Replaces the pending queue.
  void update(List<PdfTileRequest> requests) {
    if (_disposed) return;
    final queue = <(PdfTileKey, PdfTileGrid)>[];
    final wanted = <String, int>{};
    for (final r in requests) {
      final level = r.grid.levelFor(r.screenDensity);
      if (level == null) continue;
      wanted[r.assetPath] = level;
      // Visible tiles first, then a one-tile ring for panning.
      final visible = r.grid.tilesFor(level, r.visiblePt);
      final ring = r.grid
          .tilesFor(level, r.visiblePt, marginTiles: 1)
          .where((t) => !visible.contains(t));
      for (final (c, row) in [...visible, ...ring]) {
        final key = PdfTileKey(r.assetPath, level, c, row);
        if (cache.contains(key)) {
          cache.touch(key);
        } else {
          queue.add((key, r.grid));
        }
      }
    }
    final changed = !mapEquals(wanted, _wantedLevel);
    _wantedLevel
      ..clear()
      ..addAll(wanted);
    _queue = queue;
    if (changed) version.value++;
    _pump();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        final (key, grid) = _queue.first;
        _queue = _queue.sublist(1);
        if (cache.contains(key)) continue;
        final full = grid.fullSize(key.level);
        final px = grid.tilePixels(key.level, key.col, key.row);
        ui.Image? img;
        try {
          img = await render(key.assetPath, px, full.w, full.h);
        } catch (e) {
          debugPrint('[PdfTiles] render failed for $key: $e');
        }
        if (img == null) continue;
        if (_disposed) {
          img.dispose();
          return;
        }
        cache.put(
            PdfTile(key, img, grid.tilePoints(key.level, key.col, key.row)));
        _scheduleBump();
      }
    } finally {
      _running = false;
    }
    if (!_disposed) _flushBump();
  }

  // Repaints re-record the page picture: batch them instead of one per tile.
  void _scheduleBump() {
    _bump ??= Timer(const Duration(milliseconds: 60), _flushBump);
  }

  void _flushBump() {
    _bump?.cancel();
    _bump = null;
    if (!_disposed) version.value++;
  }

  void dispose() {
    _disposed = true;
    _bump?.cancel();
    _queue = const [];
    cache.clear();
    version.dispose();
  }
}
