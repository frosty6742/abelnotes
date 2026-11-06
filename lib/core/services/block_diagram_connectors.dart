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

/// Bounds of [element] on the page, stroke width and rotation included.
/// Shared by the notifier and the painter so a live drag routes arrows
/// exactly where the drop will.
Rect? elementBounds(ContentElement element) {
  Rect getRotatedBounds(Rect rect, double rotation) {
    if (rotation == 0.0) return rect;
    final c = rect.center;
    final cosA = cos(rotation);
    final sinA = sin(rotation);
    Offset r(Offset p) {
      final dx = p.dx - c.dx;
      final dy = p.dy - c.dy;
      return Offset(c.dx + dx * cosA - dy * sinA, c.dy + dx * sinA + dy * cosA);
    }
    final pts = [r(rect.topLeft), r(rect.topRight), r(rect.bottomLeft), r(rect.bottomRight)];
    final xs = pts.map((p) => p.dx);
    final ys = pts.map((p) => p.dy);
    return Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
  }

  return element.map(unknown: (_) => null,
    stroke: (e) {
      if (e.data.points.isEmpty) return null;
      final xs = e.data.points.map((p) => p.x);
      final ys = e.data.points.map((p) => p.y);
      final halfW = e.data.baseWidth / 2.0;
      return Rect.fromLTRB(xs.reduce(min) - halfW, ys.reduce(min) - halfW, xs.reduce(max) + halfW, ys.reduce(max) + halfW);
    },
    text: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
    image: (e) {
      final rect = Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height);
      return getRotatedBounds(rect, e.data.rotation);
    },
    shape: (e) {
      final halfW = e.data.strokeWidth / 2.0;
      // An elbow can run outside its two ends (a U under a row).
      if (e.data.elbow != null && isConnector(e.data)) {
        final pts = connectorRoute(e.data);
        var r = Rect.fromPoints(pts.first, pts.first);
        for (final p in pts) {
          r = r.expandToInclude(Rect.fromPoints(p, p));
        }
        return r.inflate(halfW);
      }
      final baseRect = Rect.fromPoints(Offset(e.data.x1, e.data.y1), Offset(e.data.x2, e.data.y2)).inflate(halfW);
      return getRotatedBounds(baseRect, e.data.rotation);
    },
    math: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
  );
}

bool isConnector(ShapeData d) => d.shapeType == 'arrow' || d.shapeType == 'line';

/// What a connector can attach to: a rectangle/circle/triangle, or a closed
/// filled outline (box, diamond…) — not handwriting or another arrow.
bool isBlockBody(ContentElement e) => e.map(
      unknown: (_) => false,
      text: (_) => false,
      image: (_) => false,
      math: (_) => false,
      shape: (s) =>
          const {'rectangle', 'circle', 'triangle'}.contains(s.data.shapeType),
      stroke: (s) {
        final p = s.data.points;
        // Only filled outlines (the library's) — a handwritten "o" or "0"
        // is a closed loop too, and must not grab arrows or chain buttons.
        return s.data.fillColor != null &&
            p.length >= 8 &&
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

/// The polyline a line/arrow is drawn along: the straight segment, or for an
/// elbow connector a route with right angles whose middle leg runs halfway
/// between the ends, shifted by [ShapeData.lane]. An elbow whose ends line
/// up degenerates to a straight run.
List<Offset> connectorRoute(ShapeData d) {
  final a = Offset(d.x1, d.y1), b = Offset(d.x2, d.y2);
  final lane = d.lane ?? 0;
  switch (d.elbow) {
    case 'h':
      final mx = (a.dx + b.dx) / 2 + lane;
      return [a, Offset(mx, a.dy), Offset(mx, b.dy), b];
    case 'v':
      final my = (a.dy + b.dy) / 2 + lane;
      return [a, Offset(a.dx, my), Offset(b.dx, my), b];
    default:
      return [a, b];
  }
}

/// Space kept between a detouring arrow and the blocks it goes around.
const _laneGap = 10.0;

/// Puts each attached end of [d] on its block.
///
/// Straight connectors run centre-to-centre and leave through the block's
/// edge. Elbow connectors leave and enter through the middle of a side, with
/// right angles, and never cut through a block:
///  * by default along whichever axis the blocks are further apart on,
///    through the sides that face each other;
///  * if that route crosses a block, or it is the back arrow of a pair of
///    blocks joined both ways (it would lie on the forward arrow), the
///    shortest clear detour — under the row first, then over, then round
///    the sides — with the ends leaving through the sides facing the detour;
///  * a middle leg the user dragged ([ShapeData.bend]) stays where it was
///    put, relative to the blocks, and keeps its axis.
///
/// The route actually used is written to [ShapeData.lane], so drawing and
/// hit-testing need no knowledge of other blocks.
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
  if (d.elbow == null) {
    final n1 = a == null ? p1 : edgePoint(a, b?.center ?? p2);
    final n2 = b == null ? p2 : edgePoint(b, a?.center ?? p1);
    // The ends are page points, so a rotation left on the arrow would swing them off.
    return d.copyWith(x1: n1.dx, y1: n1.dy, x2: n2.dx, y2: n2.dy, rotation: 0);
  }

  final ca = a?.center ?? p1, cb = b?.center ?? p2;
  final autoHoriz = (cb.dx - ca.dx).abs() >= (cb.dy - ca.dy).abs();

  /// The route along [horiz] whose middle leg is at page coordinate [at]
  /// (x for 'h', y for 'v'); null = halfway between the facing sides.
  ShapeData route(bool horiz, double? at) {
    Offset end(Rect? r, Offset c, Offset free, double toward) {
      if (r == null) return free;
      return horiz
          ? Offset(toward >= c.dx ? r.right : r.left, c.dy)
          : Offset(c.dx, toward >= c.dy ? r.bottom : r.top);
    }

    final Offset n1, n2;
    if (at == null) {
      n1 = end(a, ca, p1, horiz ? cb.dx : cb.dy);
      n2 = end(b, cb, p2, horiz ? ca.dx : ca.dy);
    } else {
      n1 = end(a, ca, p1, at);
      n2 = end(b, cb, p2, at);
    }
    final mid = horiz ? (n1.dx + n2.dx) / 2 : (n1.dy + n2.dy) / 2;
    return d.copyWith(
        x1: n1.dx, y1: n1.dy, x2: n2.dx, y2: n2.dy,
        elbow: horiz ? 'h' : 'v',
        lane: at == null ? null : at - mid,
        rotation: 0);
  }

  if (d.bend != null) {
    final horiz = d.elbow == 'h';
    final ref = horiz ? (ca.dx + cb.dx) / 2 : (ca.dy + cb.dy) / 2;
    return route(horiz, ref + d.bend!);
  }

  // Every other block is something to go round, with a margin so a route
  // can't graze its edge; the arrow's own blocks too, without one (a route
  // starts on their edge but may not double back through them).
  final obstacles = <Rect>[
    for (final e in byId.values)
      if (isBlockBody(e))
        if (boundsOf(e) case final r? when r.width > 2 && r.height > 2)
          elementId(e) == d.startId || elementId(e) == d.endId
              ? r.deflate(1)
              : r.inflate(_laneGap / 2),
  ];
  bool clear(ShapeData r) {
    final pts = connectorRoute(r);
    for (var i = 0; i + 1 < pts.length; i++) {
      final seg = Rect.fromPoints(pts[i], pts[i + 1]);
      for (final o in obstacles) {
        if (seg.overlaps(o)) return false;
      }
    }
    return true;
  }

  double length(ShapeData r) {
    final pts = connectorRoute(r);
    var l = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      l += (pts[i + 1] - pts[i]).distance;
    }
    return l;
  }

  // The back arrow of a two-way pair: the one pointing left (or up).
  final isBack = a != null &&
      b != null &&
      (autoHoriz ? cb.dx < ca.dx : cb.dy < ca.dy) &&
      byId.values.any((e) =>
          e is ShapeElement &&
          isConnector(e.data) &&
          e.data.startId == d.endId &&
          e.data.endId == d.startId);

  final straight = route(autoHoriz, null);
  if (!isBack && clear(straight)) return straight;

  /// The lane past every block in the way, starting just outside the ends'
  /// blocks on side [sign] (+1 = below/right) of axis [horiz]'s cross axis.
  ShapeData detour(bool horiz, int sign) {
    double edge(Rect r) => horiz
        ? (sign > 0 ? r.right : r.left)
        : (sign > 0 ? r.bottom : r.top);
    double far(double x, double y) => sign > 0 ? max(x, y) : min(x, y);
    var at = far(edge(a ?? Rect.fromCenter(center: p1, width: 0, height: 0)),
            edge(b ?? Rect.fromCenter(center: p2, width: 0, height: 0))) +
        sign * _laneGap;
    var r = route(horiz, at);
    for (var i = 0; i < 12 && !clear(r); i++) {
      // Push the lane past the furthest block the route hits.
      final pts = connectorRoute(r);
      double? next;
      for (var k = 0; k + 1 < pts.length; k++) {
        final seg = Rect.fromPoints(pts[k], pts[k + 1]);
        for (final o in obstacles) {
          if (seg.overlaps(o)) {
            final e = edge(o) + sign * _laneGap;
            next = next == null ? e : far(next, e);
          }
        }
      }
      if (next == null || next == at) break;
      at = far(at, next);
      r = route(horiz, at);
    }
    return r;
  }

  final candidates = [
    if (!isBack) route(!autoHoriz, null),
    detour(false, 1), // under the row
    detour(false, -1), // over it
    detour(true, 1), // round the right
    detour(true, -1), // round the left
  ].where(clear).toList();
  if (candidates.isEmpty) return isBack ? detour(!autoHoriz, 1) : straight;
  // Stable: on a tie the earlier (under the row) wins.
  var best = candidates.first;
  for (final c in candidates.skip(1)) {
    if (length(c) < length(best) - 0.5) best = c;
  }
  return best;
}

/// [d] with its middle leg pinned at page coordinate [at] (x for an 'h'
/// elbow, y for 'v') — what dragging the leg's handle does — re-snapped.
ShapeData bendConnector(
    ShapeData d, double at, Map<String, ContentElement> byId, BoundsOf boundsOf) {
  Offset centre(String? id, Offset free) {
    final e = id == null ? null : byId[id];
    return (e == null ? null : boundsOf(e))?.center ?? free;
  }

  final ca = centre(d.startId, Offset(d.x1, d.y1));
  final cb = centre(d.endId, Offset(d.x2, d.y2));
  final ref = d.elbow == 'h' ? (ca.dx + cb.dx) / 2 : (ca.dy + cb.dy) / 2;
  return snapConnector(d.copyWith(bend: at - ref), byId, boundsOf);
}

/// Where a lasso transform takes page point [p]: scaled and rotated about
/// [center], then dragged — the same order the painter's canvas applies.
Offset lassoPoint(Offset p, Offset center, double scale, double rotation, Offset drag) {
  final v = (p - center) * scale;
  final c = cos(rotation), s = sin(rotation);
  return center + Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c) + drag;
}

/// Box around [r]'s corners after [lassoPoint]: where a lasso transform
/// puts a block (a turned block's box grows, as on the drop).
Rect lassoRect(Rect r, Offset center, double scale, double rotation, Offset drag) {
  final pts = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]
      .map((p) => lassoPoint(p, center, scale, rotation, drag))
      .toList();
  return Rect.fromPoints(pts[0], pts[3])
      .expandToInclude(Rect.fromPoints(pts[1], pts[2]));
}

/// Mid-drag routes for the connectors a drag touches (id → data to draw):
/// a moving connector's ends go through [moveEnd], then attached ends land
/// on [liveBounds] by [snapConnector] — what the drop will commit.
Map<String, ShapeData> liveConnectorRoutes(
  List<ContentElement> content,
  bool Function(String? id) isMoving,
  Offset Function(ShapeData d, Offset p) moveEnd,
  BoundsOf liveBounds,
) {
  Map<String, ContentElement>? byId;
  final routes = <String, ShapeData>{};
  for (final e in content) {
    if (e is! ShapeElement) continue;
    var d = e.data;
    if (d.startId == null && d.endId == null) continue;
    if (d.elbow == null && !isMoving(e.id) && !isMoving(d.startId) && !isMoving(d.endId)) {
      continue;
    }
    if (isMoving(e.id)) {
      final a = moveEnd(d, Offset(d.x1, d.y1)), b = moveEnd(d, Offset(d.x2, d.y2));
      d = d.copyWith(x1: a.dx, y1: a.dy, x2: b.dx, y2: b.dy);
    }
    byId ??= {for (final x in content) elementId(x): x};
    routes[e.id] = snapConnector(d, byId, liveBounds);
  }
  return routes;
}

/// After the elements in [moved] changed: re-snap every connector that moved
/// or is attached to something that moved. Attached ends never come loose —
/// a moved arrow's attached ends go back onto their blocks; only a free end
/// goes where it was dragged. Deleting the arrow is how it is unlinked.
List<ContentElement> snapConnectors(
    List<ContentElement> content, Set<String> moved, BoundsOf boundsOf) {
  final byId = {for (final e in content) elementId(e): e};
  return [
    for (final e in content)
      e.maybeMap(
        shape: (s) {
          var d = s.data;
          if (d.startId == null && d.endId == null) return e;
          // Elbows also re-route when some other block moved into their way.
          if (d.elbow != null ||
              moved.contains(s.id) ||
              moved.contains(d.startId) ||
              moved.contains(d.endId)) {
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
