// The pure rules behind block diagrams: what a block is, where connectors
// attach, hit-testing inside outlines, tidy maths. No notifier, no widgets.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/services/block_diagram_connectors.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

ContentElement rect(String id, double x, double y, double w, double h) =>
    ContentElement.shape(
        id: id,
        zIndex: 0,
        data: ShapeData(shapeType: 'rectangle', x1: x, y1: y, x2: x + w, y2: y + h));

ContentElement arrow(String id, String? from, String? to, {String? elbow}) =>
    ContentElement.shape(
        id: id,
        zIndex: 1,
        data: ShapeData(
            shapeType: 'arrow',
            x1: 0, y1: 0, x2: 1, y2: 1,
            startId: from,
            endId: to,
            elbow: elbow));

/// A closed outline through [corners], sampled so it has enough points.
ContentElement outline(String id, List<Offset> corners) {
  final pts = <StrokePoint>[];
  for (var i = 0; i < corners.length; i++) {
    final a = corners[i], b = corners[(i + 1) % corners.length];
    for (var j = 0; j < 10; j++) {
      final p = Offset.lerp(a, b, j / 10)!;
      pts.add(StrokePoint(x: p.dx, y: p.dy));
    }
  }
  pts.add(pts.first);
  return ContentElement.stroke(id: id, zIndex: 0, data: StrokeData(points: pts));
}

Rect? plainBounds(ContentElement e) => blockOutlineRect(e);

ShapeData shapeOf(List<ContentElement> c, String id) =>
    c.map((e) => e.mapOrNull(shape: (x) => x)).firstWhere((x) => x?.id == id)!.data;

void main() {
  group('what counts as a block', () {
    test('shapes and closed outlines are blocks; scribbles, open strokes, arrows are not', () {
      expect(isBlockBody(rect('r', 0, 0, 40, 20)), isTrue);
      expect(isBlockBody(outline('d', const [Offset(20, 0), Offset(40, 10), Offset(20, 20), Offset(0, 10)])), isTrue);
      final open = ContentElement.stroke(
          id: 'o',
          zIndex: 0,
          data: StrokeData(points: [for (var i = 0; i < 12; i++) StrokePoint(x: i * 5.0, y: 0)]));
      expect(isBlockBody(open), isFalse);
      expect(isBlockBody(arrow('a', null, null)), isFalse);
    });
  });

  group('clicking inside an outline', () {
    final diamond = outline('d', const [Offset(50, 0), Offset(100, 25), Offset(50, 50), Offset(0, 25)]);

    test('selects it from the middle, but not from a bbox corner outside the diamond', () {
      expect(closedBlockAt([diamond], const Offset(50, 25)), 'd');
      expect(closedBlockAt([diamond], const Offset(5, 3)), isNull); // in the bbox, outside the shape
      expect(closedBlockAt([diamond], const Offset(300, 300)), isNull);
    });

    test('the smallest enclosing outline wins', () {
      final inner = outline('inner', const [Offset(40, 15), Offset(60, 15), Offset(60, 35), Offset(40, 35)]);
      expect(closedBlockAt([diamond, inner], const Offset(50, 25)), 'inner');
    });

    test('tiny loops are ignored', () {
      final tiny = outline('t', const [Offset(0, 0), Offset(8, 0), Offset(8, 8), Offset(0, 8)]);
      expect(closedBlockAt([tiny], const Offset(4, 4)), isNull);
    });
  });

  group('attaching a drawn arrow', () {
    test('blockAt takes the smallest block near the point and ignores slivers', () {
      final big = rect('big', 0, 0, 200, 200);
      final small = rect('small', 80, 80, 40, 20);
      final sliver = rect('sliver', 90, 85, 4, 4);
      expect(elementId(blockAt([big, small, sliver], const Offset(100, 90), plainBounds)!), 'small');
      expect(blockAt([big], const Offset(500, 500), plainBounds), isNull);
      // 8 units of slack around a block, so an arrow tip that just misses still attaches.
      expect(blockAt([small], const Offset(125, 90), plainBounds), isNotNull);
      expect(blockAt([small], const Offset(135, 90), plainBounds), isNull);
    });
  });

  group('snapping connectors', () {
    final a = rect('a', 0, 0, 40, 20), b = rect('b', 100, 60, 40, 20);
    final byId = {'a': a, 'b': b};

    test('straight: ends leave through the edges, along the line between the centres', () {
      final d = snapConnector(shapeOf([arrow('r', 'a', 'b')], 'r'), byId, plainBounds);
      // Centres (20,10) -> (120,70): the line exits a's bottom edge at x = 20 + 10*100/60.
      expect(d.x1, closeTo(36.67, 0.05));
      expect(d.y1, closeTo(20, 1e-9));
      expect(d.elbow, isNull);
    });

    test('elbow: horizontal-first when blocks are further apart sideways', () {
      final d = snapConnector(shapeOf([arrow('r', 'a', 'b', elbow: 'h')], 'r'), byId, plainBounds);
      expect(d.elbow, 'h');
      expect([d.x1, d.y1], [40, 10]); // a's right side, middle
      expect([d.x2, d.y2], [100, 70]); // b's left side, middle
    });

    test('elbow: vertical-first when stacked, and it flips when the order flips', () {
      final top = rect('t', 0, 0, 40, 20), below = rect('u', 5, 100, 40, 20);
      final down = snapConnector(shapeOf([arrow('r', 't', 'u', elbow: 'h')], 'r'),
          {'t': top, 'u': below}, plainBounds);
      expect(down.elbow, 'v');
      expect(down.y1, 20); // bottom of the upper block
      expect(down.y2, 100); // top of the lower block
      final up = snapConnector(shapeOf([arrow('r', 'u', 't', elbow: 'h')], 'r'),
          {'t': top, 'u': below}, plainBounds);
      expect(up.y1, 100); // leaves the lower block's top
      expect(up.y2, 20);
    });

    test('a connector with no live ends is left alone', () {
      final d = shapeOf([arrow('r', 'gone', 'also-gone')], 'r');
      expect(snapConnector(d, byId, plainBounds), d);
    });

    test('moving a block re-snaps only the connectors attached to it', () {
      final other = arrow('x', null, null);
      final out = snapConnectors([a, b, arrow('r', 'a', 'b', elbow: 'h'), other], {'b'}, plainBounds);
      expect(shapeOf(out, 'r').x2, 100);
      expect(identical(out.last, other), isTrue);
    });

    test('a moved arrow detaches from the block that stayed', () {
      final out = snapConnectors([a, b, arrow('r', 'a', 'b')], {'r', 'b'}, plainBounds);
      expect(shapeOf(out, 'r').startId, isNull);
      expect(shapeOf(out, 'r').endId, 'b');
    });
  });

  group('copies', () {
    test('a copied connector points at the copied blocks, or nowhere', () {
      final originals = [rect('a', 0, 0, 40, 20), rect('b', 100, 0, 40, 20), arrow('r', 'a', 'b'), arrow('s', 'a', 'elsewhere')];
      final copies = [rect('a2', 0, 0, 40, 20), rect('b2', 100, 0, 40, 20), arrow('r2', 'a', 'b'), arrow('s2', 'a', 'elsewhere')];
      final out = remapConnectors(originals, copies);
      expect([shapeOf(out, 'r2').startId, shapeOf(out, 'r2').endId], ['a2', 'b2']);
      expect([shapeOf(out, 's2').startId, shapeOf(out, 's2').endId], ['a2', null]);
    });
  });

  group('tinting', () {
    test('recolours ink and gives a see-through fill only to what had one', () {
      const filled = ContentElement.shape(
          id: 'f',
          zIndex: 0,
          data: ShapeData(shapeType: 'rectangle', x1: 0, y1: 0, x2: 9, y2: 9, fillColor: 0xFFAAAAAA));
      final bare = rect('b', 0, 0, 9, 9);
      expect(shapeOf([tintElement(filled, 0xFF2E7D32)], 'f').fillColor, 0x332E7D32);
      expect(shapeOf([tintElement(bare, 0xFF2E7D32)], 'b').fillColor, isNull);
      expect(shapeOf([tintElement(bare, 0xFF2E7D32)], 'b').strokeColor, 0xFF2E7D32);
    });
  });

  group('tidy', () {
    test('rows and columns line up; a deliberate offset is kept', () {
      final d = tidyDeltas({
        'a': const Rect.fromLTWH(0, 0, 40, 20), // row 1
        'b': const Rect.fromLTWH(100, 6, 40, 20), // row 1, 6 low
        'c': const Rect.fromLTWH(5, 100, 40, 20), // column of a, 5 right
        'far': const Rect.fromLTWH(300, 300, 40, 20), // alone
      });
      expect(d['a']!.dy, closeTo(3, 1e-9)); // meets b halfway
      expect(d['b']!.dy, closeTo(-3, 1e-9));
      expect(d['a']!.dx, closeTo(2.5, 1e-9)); // meets c halfway
      expect(d['c']!.dx, closeTo(-2.5, 1e-9));
      expect(d['far']!, Offset.zero);
    });

    test('writing inside a block follows it; writing elsewhere stays', () {
      final blocks = {'a': const Rect.fromLTWH(0, 0, 100, 50), 'inner': const Rect.fromLTWH(10, 10, 30, 20)};
      final delta = {'a': const Offset(5, 0), 'inner': const Offset(0, 7)};
      expect(hostDelta(const Rect.fromLTWH(15, 15, 5, 5), blocks, delta), const Offset(0, 7)); // smallest host
      expect(hostDelta(const Rect.fromLTWH(60, 20, 5, 5), blocks, delta), const Offset(5, 0));
      expect(hostDelta(const Rect.fromLTWH(500, 500, 5, 5), blocks, delta), Offset.zero);
    });

    test('a single block has nothing to tidy', () {
      expect(tidyDeltas({'a': const Rect.fromLTWH(0, 0, 40, 20)}), {'a': Offset.zero});
    });
  });

  test('edgePoint leaves a box on the ray towards a target', () {
    const r = Rect.fromLTWH(0, 0, 40, 20);
    expect(edgePoint(r, const Offset(200, 10)), const Offset(40, 10));
    expect(edgePoint(r, const Offset(20, -300)), const Offset(20, 0));
    expect(edgePoint(r, r.center), r.center);
  });
}
