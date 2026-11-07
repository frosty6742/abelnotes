import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/features/canvas/data/pdf_tiles.dart';

Future<ui.Image> _img(int w, int h) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000));
  return rec.endRecording().toImage(w, h);
}

// A4 imported at 150 DPI: 1240 px across 595 pt.
const _a4 = PdfTileGrid(widthPt: 595, heightPt: 842, baseDensity: 1240 / 595);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PdfTileGrid', () {
    test('no tiles while the PNG is sharp enough', () {
      expect(_a4.levelFor(1.0), isNull);
      expect(_a4.levelFor(_a4.baseDensity * 1.1), isNull);
    });

    test('picks the first level that reaches the screen density', () {
      expect(_a4.levelFor(_a4.baseDensity * 1.5), 1);
      expect(_a4.levelFor(_a4.baseDensity * 2), 1);
      expect(_a4.levelFor(_a4.baseDensity * 2.1), 2);
      expect(_a4.levelFor(_a4.baseDensity * 7), 3);
    });

    test('caps the density', () {
      final level = _a4.levelFor(1000, maxDensity: 16)!;
      expect(_a4.densityAt(level), greaterThanOrEqualTo(16));
      expect(_a4.densityAt(level - 1), lessThan(16));
    });

    test('visible tiles come nearest-to-centre first and cover the view', () {
      const view = ui.Rect.fromLTWH(200, 300, 100, 80);
      final tiles = _a4.tilesFor(3, view);
      expect(tiles, isNotEmpty);
      final covered = tiles
          .map((t) => _a4.tilePoints(3, t.$1, t.$2))
          .reduce((a, b) => a.expandToInclude(b));
      expect(covered.contains(view.topLeft), isTrue);
      expect(covered.contains(view.bottomRight - const ui.Offset(1e-3, 1e-3)),
          isTrue);
      final first = _a4.tilePoints(3, tiles.first.$1, tiles.first.$2);
      expect(first.contains(view.center), isTrue);
    });

    test('margin adds a ring, clipped to the page', () {
      const corner = ui.Rect.fromLTWH(0, 0, 10, 10);
      expect(_a4.tilesFor(2, corner), [(0, 0)]);
      expect(_a4.tilesFor(2, corner, marginTiles: 1).toSet(),
          {(0, 0), (1, 0), (0, 1), (1, 1)});
    });

    test('last tile is cut to the raster edge', () {
      final full = _a4.fullSize(1);
      final cols = (full.w / kPdfTileSize).ceil();
      final px = _a4.tilePixels(1, cols - 1, 0);
      expect(px.right, closeTo(full.w, 1e-9));
      expect(_a4.tilePoints(1, cols - 1, 0).right, closeTo(595, 1e-9));
    });

    test('off-page view needs nothing', () {
      expect(
          _a4.tilesFor(1, const ui.Rect.fromLTWH(700, 900, 10, 10)), isEmpty);
    });
  });

  group('PdfTileCache', () {
    test('evicts least recently used past the byte cap and disposes it',
        () async {
      final cache = PdfTileCache(maxBytes: 3 * 64);
      final imgs = [for (var i = 0; i < 4; i++) await _img(4, 4)];
      for (var i = 0; i < 3; i++) {
        cache.put(PdfTile(PdfTileKey('a', 1, i, 0), imgs[i], ui.Rect.zero));
      }
      cache.touch(const PdfTileKey('a', 1, 0, 0));
      cache.put(PdfTile(const PdfTileKey('a', 1, 3, 0), imgs[3], ui.Rect.zero));
      expect(cache.contains(const PdfTileKey('a', 1, 1, 0)), isFalse);
      expect(imgs[1].debugDisposed, isTrue);
      expect(cache.contains(const PdfTileKey('a', 1, 0, 0)), isTrue);
      expect(cache.bytes, 3 * 64);
    });

    test('tilesOf returns coarse levels first, none above the cap', () async {
      final cache = PdfTileCache(maxBytes: 1 << 20);
      for (final l in [3, 1, 2]) {
        cache.put(
            PdfTile(PdfTileKey('a', l, 0, 0), await _img(2, 2), ui.Rect.zero));
      }
      cache.put(PdfTile(
          const PdfTileKey('b', 1, 0, 0), await _img(2, 2), ui.Rect.zero));
      expect(cache.tilesOf('a', 2).map((t) => t.key.level), [1, 2]);
    });
  });

  group('PdfTileScheduler', () {
    test('renders the visible tiles once and repaints', () async {
      final calls = <ui.Rect>[];
      final s = PdfTileScheduler(
        cache: PdfTileCache(maxBytes: 64 << 20),
        render: (asset, px, fw, fh) async {
          calls.add(px);
          return _img(px.width.ceil(), px.height.ceil());
        },
      );
      final req = PdfTileRequest(
        assetPath: 'a',
        grid: _a4,
        visiblePt: const ui.Rect.fromLTWH(100, 100, 50, 50),
        screenDensity: _a4.baseDensity * 4,
      );
      final v0 = s.version.value;
      s.update([req]);
      await pumpEventQueue(times: 50);
      expect(s.wantedLevel('a'), 2);
      expect(calls, isNotEmpty);
      expect(s.tilesFor('a'), hasLength(calls.length));
      expect(s.version.value, greaterThan(v0));

      final n = calls.length;
      s.update([req]);
      await pumpEventQueue(times: 50);
      expect(calls.length, n, reason: 'cached tiles are not rendered again');
      s.dispose();
    });

    test('a new viewport drops the stale queue', () async {
      final rendered = <PdfTileKey>[];
      late PdfTileScheduler s;
      s = PdfTileScheduler(
        cache: PdfTileCache(maxBytes: 64 << 20),
        render: (asset, px, fw, fh) async {
          rendered.add(PdfTileKey(asset, 0, px.left ~/ 512, px.top ~/ 512));
          return _img(1, 1);
        },
      );
      PdfTileRequest at(ui.Rect r) => PdfTileRequest(
          assetPath: 'a', grid: _a4, visiblePt: r, screenDensity: 16);
      s.update([at(const ui.Rect.fromLTWH(0, 0, 595, 842))]);
      s.update([at(const ui.Rect.fromLTWH(0, 0, 5, 5))]);
      await pumpEventQueue(times: 50);
      // Only the first tile of the big view slipped in before the switch.
      expect(rendered.length, lessThanOrEqualTo(1 + 4));
      s.dispose();
    });

    test('zooming out below the PNG density paints nothing', () async {
      final s = PdfTileScheduler(
        cache: PdfTileCache(maxBytes: 64 << 20),
        render: (a, px, fw, fh) => _img(1, 1),
      );
      s.update([
        const PdfTileRequest(
            assetPath: 'a',
            grid: _a4,
            visiblePt: ui.Rect.fromLTWH(0, 0, 50, 50),
            screenDensity: 8),
      ]);
      await pumpEventQueue(times: 50);
      expect(s.tilesFor('a'), isNotEmpty);
      s.update([
        const PdfTileRequest(
            assetPath: 'a',
            grid: _a4,
            visiblePt: ui.Rect.fromLTWH(0, 0, 595, 842),
            screenDensity: 1),
      ]);
      expect(s.tilesFor('a'), isEmpty);
      s.dispose();
    });
  });
}
