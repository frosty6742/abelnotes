import 'dart:math';
import 'dart:ui';

import 'package:abelnotes/core/providers/canvas_state.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

/// Built-in "Block diagram" library: the blocks and arrows you reach for
/// first, placed with one tap from the symbol panel and drawn in the current
/// pen colour (then dragged/resized with the lasso it lands in). Unlabelled
/// and small: write the name next to it.
///
/// Ids are fixed so the library merges across devices and notebooks without
/// duplicating, and deleting it (or one block) sticks via the usual
/// tombstones. The id carries a version because a library a device already
/// stored wins over a restyled one on merge: restyling means a new id, with
/// the old one tombstoned.
const blockDiagramLibraryId = 'builtin-block-diagram-v4';

/// Earlier versions of this library. A stored copy would win over a restyled
/// one on merge, so a new version gets a new id and the old id is tombstoned.
const retiredBlockDiagramLibraryIds = {'builtin-block-diagram', 'builtin-block-diagram-v2', 'builtin-block-diagram-v3'};

const _w = 40.0, _h = 20.0;

// Navy ink on a pale blue-grey fill, thin lines: the look of hand-drawn
// block diagrams on dotted paper.
const _ink = 0xFF1B3F7A, _fill = 0xFFD4DCE8, _lw = 1.0;

SymbolLibrary blockDiagramLibrary() {
  final created = DateTime.utc(2026);
  var n = 0;
  ReusableSymbol sym(String key, String name, List<ContentElement> els,
          Rect bounds) =>
      ReusableSymbol(
        id: 'builtin-bd4-$key',
        name: name,
        elements: els,
        bounds: bounds,
        createdAt: created,
      );

  // Element ids/zIndex are re-assigned on insert, so any unique value works.
  ContentElement shape(String type, double x1, double y1, double x2, double y2,
          {bool filled = false}) =>
      ContentElement.shape(
        id: 'bd${n++}',
        zIndex: n,
        data: ShapeData(
          shapeType: type,
          x1: x1, y1: y1, x2: x2, y2: y2,
          strokeColor: _ink,
          strokeWidth: _lw,
          fillColor: filled ? _fill : null,
        ),
      );

  // Densely sampled so the renderer's spline smoothing can't cut corners.
  ContentElement outline(List<Offset> pts) => ContentElement.stroke(
        id: 'bd${n++}',
        zIndex: n,
        data: StrokeData(
          points: [for (final p in pts) StrokePoint(x: p.dx, y: p.dy)],
          color: _ink,
          baseWidth: _lw,
          fillColor: _fill,
        ),
      );

  /// Rounded rectangle perimeter with corner radius [r], closed.
  List<Offset> rounded(double r) {
    final pts = <Offset>[];
    // Four corner arcs, each preceded by the straight edge that leads to it.
    final corners = [
      (Offset(_w - r, r), -pi / 2),
      (Offset(_w - r, _h - r), 0.0),
      (Offset(r, _h - r), pi / 2),
      (Offset(r, r), pi),
    ];
    for (final (c, from) in corners) {
      final start = Offset(c.dx + r * cos(from), c.dy + r * sin(from));
      if (pts.isNotEmpty) {
        final a = pts.last;
        final steps = max(1, ((start - a).distance / 4).ceil());
        for (var i = 1; i < steps; i++) {
          pts.add(Offset.lerp(a, start, i / steps)!);
        }
      }
      for (var i = 0; i <= 8; i++) {
        final a = from + i * pi / 16;
        pts.add(Offset(c.dx + r * cos(a), c.dy + r * sin(a)));
      }
    }
    // Close back along the top edge to the first point.
    final a = pts.last, end = pts.first;
    final steps = max(1, ((end - a).distance / 4).ceil());
    for (var i = 1; i <= steps; i++) {
      pts.add(Offset.lerp(a, end, i / steps)!);
    }
    return pts;
  }

  /// Closed polygon through [corners], sampled along each edge.
  List<Offset> polygon(List<Offset> corners) {
    final pts = <Offset>[];
    for (var i = 0; i < corners.length; i++) {
      final a = corners[i], b = corners[(i + 1) % corners.length];
      final steps = max(1, ((b - a).distance / 4).ceil());
      for (var j = 0; j < steps; j++) {
        pts.add(Offset.lerp(a, b, j / steps)!);
      }
    }
    return [...pts, pts.first];
  }

  Rect box(double w, double h) => Rect.fromLTWH(0, 0, w, h);
  const hMid = _h / 2;

  return SymbolLibrary(
    id: blockDiagramLibraryId,
    name: 'Block diagram',
    symbols: [
      sym('block', 'Block',
          [shape('rectangle', 0, 0, _w, _h, filled: true)], box(_w, _h)),
      sym('rounded', 'Rounded block',
          [outline(rounded(5))], box(_w, _h)),
      sym('terminator', 'Start / End',
          [outline(rounded(hMid))], box(_w, _h)),
      sym('decision', 'Decision',
          [outline(polygon([const Offset(_w / 2, 0), const Offset(_w, hMid), const Offset(_w / 2, _h), const Offset(0, hMid)]))],
          box(_w, _h)),
      sym('io', 'Input / Output',
          [outline(polygon([const Offset(5, 0), const Offset(_w, 0), const Offset(_w - 5, _h), const Offset(0, _h)]))],
          box(_w, _h)),
      sym('circle', 'Node',
          [shape('circle', 0, 0, 22, 22, filled: true)], box(22, 22)),
      sym('arrow-r', 'Arrow →', [shape('arrow', 0, 0, 28, 0)], const Rect.fromLTWH(0, -1, 28, 2)),
      sym('arrow-d', 'Arrow ↓', [shape('arrow', 0, 0, 0, 28)], const Rect.fromLTWH(-1, 0, 2, 28)),
      sym('arrow-l', 'Arrow ←', [shape('arrow', 28, 0, 0, 0)], const Rect.fromLTWH(0, -1, 28, 2)),
      sym('arrow-u', 'Arrow ↑', [shape('arrow', 0, 28, 0, 0)], const Rect.fromLTWH(-1, 0, 2, 28)),
      sym('line', 'Line', [shape('line', 0, 0, 28, 0)], const Rect.fromLTWH(0, -1, 28, 2)),
    ],
  );
}

/// The library's blocks, without the arrows and the line: what the "add a
/// block here" chooser offers.
List<ReusableSymbol> blockDiagramBlocks() => [
      for (final s in blockDiagramLibrary().symbols)
        if (!s.id.contains('-arrow-') && !s.id.endsWith('-line')) s
    ];
