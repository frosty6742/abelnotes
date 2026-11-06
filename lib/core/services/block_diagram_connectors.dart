// The geometry behind block diagrams, free of any state: what counts as a
// block, where a connector attaches, how it re-snaps when a block moves, and
// how a selection is tidied. The notifier supplies the state/undo plumbing
// and the screen supplies the gestures; both call in here so the rules live
// (and are tested) in one place.

import 'dart:math';
import 'dart:ui';

import 'package:abelnotes/shared/models/ncnote_format.dart';

/// Bounds of an element on the page (includes stroke width), or null.
typedef BoundsOf = Rect? Function(ContentElement);

/// Smallest side, in page units, for something to count as a block.
const _minBlockSide = 14.0;

String elementId(ContentElement e) => e.map(
    unknown: (u) => u.id,
    stroke: (e) => e.id,
    text: (e) => e.id,
    image: (e) => e.id,
    shape: (e) => e.id,
    math: (e) => e.id);

bool isConnector(ShapeData d) => d.shapeType == 'arrow' || d.shapeType == 'line';

/// What a connector can attach to: a rectangle/circle/triangle, or a closed
/// outline (box, diamond…) — not a loose scribble or another arrow.
bool isBlockBody(ContentElement e) => e.map(
      unknown: (_) => false,
      text: (_) => false,
      image: (_) => false,
      math: (_) => false,
      shape: (s) =>
          const {'rectangle', 'circle', 'triangle'}.contains(s.data.shapeType),
      stroke: (s) {
        final p = s.data.points;
        return p.length >= 8 &&
            (p.first.x - p.last.x).abs() < 6 &&
            (p.first.y - p.last.y).abs() < 6;
      },
    );

Rect pointsRect(List<StrokePoint> pts) {
  final xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
  return Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
}

/// Outline box of a closed-outline block (no stroke width), or null.
Rect? blockStrokeRect(ContentElement e) =>
    e.mapOrNull(stroke: (s) => isBlockBody(e) ? pointsRect(s.data.points) : null);

/// Outline box of any block (no stroke width), or null if [e] isn't one.
Rect? blockOutlineRect(ContentElement e) => e.mapOrNull(
      shape: (s) => isBlockBody(e)
          ? Rect.fromPoints(Offset(s.data.x1, s.data.y1), Offset(s.data.x2, s.data.y2))
          : null,
      stroke: (_) => blockStrokeRect(e),
    );

/// Outline boxes of every block on the page except [except].
List<Rect> blockRects(List<ContentElement> content, {String? except}) {
  final out = <Rect>[];
  for (final e in content) {
    final r = elementId(e) == except ? null : blockOutlineRect(e);
    if (r != null) out.add(r);
  }
  return out;
}

/// Recolours [e] to the pen colour [pen]; anything that has a fill gets a
/// see-through fill of the same colour. Text, images and maths are left.
ContentElement tintElement(ContentElement e, int pen) {
  final fill = (pen & 0xFFFFFF) | 0x33000000;
  return e.map(
    unknown: (u) => u,
    text: (t) => t,
    image: (i) => i,
    math: (m) => m,
    stroke: (x) => ContentElement.stroke(
        id: x.id,
        zIndex: x.zIndex,
        data: x.data.copyWith(
            color: pen,
            fillColor: x.data.fillColor == null ? null : fill)),
    shape: (x) => ContentElement.shape(
        id: x.id,
        zIndex: x.zIndex,
        data: x.data.copyWith(
            strokeColor: pen,
            fillColor: x.data.fillColor == null ? null : fill)),
  );
}

/// The smallest block (at least 14×14) whose box, grown a little, holds [p]:
/// where a freshly drawn arrow end attaches.
ContentElement? blockAt(List<ContentElement> content, Offset p, BoundsOf boundsOf) {
  ContentElement? best;
  var bestArea = double.infinity;
  for (final e in content) {
    if (!isBlockBody(e)) continue;
    final b = boundsOf(e);
    if (b == null || b.width < _minBlockSide || b.height < _minBlockSide) continue;
    if (!b.inflate(8).contains(p)) continue;
    if (b.width * b.height < bestArea) {
      best = e;
      bestArea = b.width * b.height;
    }
  }
  return best;
}

/// Id of the smallest closed outline block that encloses [pos], or null.
/// A click inside an unfilled outline selects it the way a click inside a
/// filled box does; callers use it only after every other element missed, so
/// text or ink drawn inside a loop is still picked first.
String? closedBlockAt(List<ContentElement> content, Offset pos) {
  String? best;
  var bestArea = double.infinity;
  for (final e in content) {
    final r = blockStrokeRect(e);
    if (r == null || r.width < _minBlockSide || r.height < _minBlockSide) continue;
    if (!r.contains(pos)) continue;
    final pts = e.mapOrNull(stroke: (s) => s.data.points)!;
    var inside = false; // even-odd ray cast
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      final a = pts[i], b = pts[j];
      if ((a.y > pos.dy) != (b.y > pos.dy) &&
          pos.dx < (b.x - a.x) * (pos.dy - a.y) / (b.y - a.y) + a.x) {
        inside = !inside;
      }
    }
    if (inside && r.width * r.height < bestArea) {
      bestArea = r.width * r.height;
      best = elementId(e);
    }
  }
  return best;
}

/// Where the ray from the centre of [r] towards [toward] leaves [r].
Offset edgePoint(Rect r, Offset toward) {
  final c = r.center;
  final dx = toward.dx - c.dx, dy = toward.dy - c.dy;
  if (dx == 0 && dy == 0) return c;
  final t = min(dx == 0 ? double.infinity : r.width / 2 / dx.abs(),
      dy == 0 ? double.infinity : r.height / 2 / dy.abs());
  return Offset(c.dx + dx * t, c.dy + dy * t);
}

/// Puts each attached end of [d] on its block, facing the other end.
///
/// Straight connectors run centre-to-centre and leave through the block's
/// edge. Elbow connectors leave and enter through the middle of the sides
/// that face each other, along whichever axis the blocks are further apart
/// on, and record that axis in [ShapeData.elbow].
///
/// shortcut: the edge is the block's bounding box — exact for horizontal and
/// vertical runs, a few px off a diamond/circle corner on diagonals.
ShapeData snapConnector(
    ShapeData d, Map<String, ContentElement> byId, BoundsOf boundsOf) {
  Rect? box(String? id) =>
      id == null || byId[id] == null ? null : boundsOf(byId[id]!);
  final a = box(d.startId), b = box(d.endId);
  if (a == null && b == null) return d;
  final p1 = Offset(d.x1, d.y1), p2 = Offset(d.x2, d.y2);
  if (d.elbow != null) {
    final ca = a?.center ?? p1, cb = b?.center ?? p2;
    final horiz = (cb.dx - ca.dx).abs() >= (cb.dy - ca.dy).abs();
    final n1 = a == null
        ? p1
        : horiz
            ? Offset(cb.dx >= ca.dx ? a.right : a.left, ca.dy)
            : Offset(ca.dx, cb.dy >= ca.dy ? a.bottom : a.top);
    final n2 = b == null
        ? p2
        : horiz
            ? Offset(cb.dx >= ca.dx ? b.left : b.right, cb.dy)
            : Offset(cb.dx, cb.dy >= ca.dy ? b.top : b.bottom);
    return d.copyWith(
        x1: n1.dx, y1: n1.dy, x2: n2.dx, y2: n2.dy, elbow: horiz ? 'h' : 'v');
  }
  final n1 = a == null ? p1 : edgePoint(a, b?.center ?? p2);
  final n2 = b == null ? p2 : edgePoint(b, a?.center ?? p1);
  return d.copyWith(x1: n1.dx, y1: n1.dy, x2: n2.dx, y2: n2.dy);
}

/// After the elements in [moved] changed: re-snap every connector attached
/// to one of them, and detach a moved connector's end whose block stayed.
List<ContentElement> snapConnectors(
    List<ContentElement> content, Set<String> moved, BoundsOf boundsOf) {
  final byId = {for (final e in content) elementId(e): e};
  return [
    for (final e in content)
      e.maybeMap(
        shape: (s) {
          var d = s.data;
          if (d.startId == null && d.endId == null) return e;
          if (moved.contains(s.id)) {
            d = d.copyWith(
              startId: moved.contains(d.startId) ? d.startId : null,
              endId: moved.contains(d.endId) ? d.endId : null,
            );
          }
          if (moved.contains(d.startId) || moved.contains(d.endId)) {
            d = snapConnector(d, byId, boundsOf);
          }
          return ContentElement.shape(id: s.id, zIndex: s.zIndex, data: d);
        },
        orElse: () => e,
      ),
  ];
}

/// Copies got new ids, so a copied connector must point at the copied blocks
/// — or at nothing if its block wasn't copied — never at the originals.
/// [originals] and [copies] are parallel lists.
List<ContentElement> remapConnectors(
    List<ContentElement> originals, List<ContentElement> copies) {
  final ids = {
    for (var i = 0; i < originals.length; i++)
      elementId(originals[i]): elementId(copies[i])
  };
  return [
    for (final e in copies)
      e.maybeMap(
        shape: (s) => s.data.startId == null && s.data.endId == null
            ? e
            : ContentElement.shape(
                id: s.id,
                zIndex: s.zIndex,
                data: s.data.copyWith(
                    startId: ids[s.data.startId], endId: ids[s.data.endId])),
        orElse: () => e,
      ),
  ];
}

/// How far each block must move to tidy [blocks] (id → outline box): blocks
/// roughly in one row share a centre line, blocks roughly in one column share
/// another. "Roughly" is within 60% of the typical block height / width, so a
/// deliberately offset block keeps its place.
Map<String, Offset> tidyDeltas(Map<String, Rect> blocks) {
  if (blocks.length < 2) return {for (final id in blocks.keys) id: Offset.zero};
  double median(Iterable<double> v) {
    final l = v.toList()..sort();
    return l[l.length ~/ 2];
  }

  /// New value per id: consecutive values within [tol] share their mean.
  Map<String, double> cluster(double Function(Rect) of, double tol) {
    final ids = blocks.keys.toList()
      ..sort((a, b) => of(blocks[a]!).compareTo(of(blocks[b]!)));
    final out = <String, double>{};
    var group = <String>[];
    void flush() {
      if (group.isEmpty) return;
      final mean =
          group.map((i) => of(blocks[i]!)).reduce((a, b) => a + b) / group.length;
      for (final i in group) {
        out[i] = mean;
      }
      group = [];
    }

    for (final id in ids) {
      if (group.isNotEmpty && of(blocks[id]!) - of(blocks[group.first]!) > tol) {
        flush();
      }
      group.add(id);
    }
    flush();
    return out;
  }

  final ys = cluster((r) => r.center.dy, 0.6 * median(blocks.values.map((r) => r.height)));
  final xs = cluster((r) => r.center.dx, 0.6 * median(blocks.values.map((r) => r.width)));
  return {
    for (final e in blocks.entries)
      e.key: Offset(xs[e.key]! - e.value.center.dx, ys[e.key]! - e.value.center.dy)
  };
}

/// The move of the smallest block in [blocks] that contains [elementBounds]'
/// centre — what handwriting inside a block does when the block is tidied —
/// or zero if it sits in no block.
Offset hostDelta(
    Rect elementBounds, Map<String, Rect> blocks, Map<String, Offset> delta) {
  String? host;
  var hostArea = double.infinity;
  for (final e in blocks.entries) {
    final r = e.value;
    if (r.contains(elementBounds.center) && r.width * r.height < hostArea) {
      host = e.key;
      hostArea = r.width * r.height;
    }
  }
  return host == null ? Offset.zero : delta[host]!;
}
