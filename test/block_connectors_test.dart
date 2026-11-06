// Arrows attached to blocks follow them; "chain" lays blocks out in a row.

import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:abelnotes/core/providers/canvas_provider.dart';
import 'package:abelnotes/features/canvas/data/render_engine.dart' show connectorRoute;
import 'package:abelnotes/features/canvas/presentation/canvas_painter_notifiers.dart';
import 'package:abelnotes/core/services/block_diagram_connectors.dart';
import 'package:abelnotes/core/services/block_diagram_symbols.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

ContentElement _box(String id, double x, double y) => ContentElement.shape(
    id: id,
    zIndex: 0,
    data: ShapeData(shapeType: 'rectangle', x1: x, y1: y, x2: x + 100, y2: y + 50));

ContentElement _arrow(String id, String from, String to) => ContentElement.shape(
    id: id,
    zIndex: 1,
    data: ShapeData(
        shapeType: 'arrow',
        x1: 100, y1: 25, x2: 200, y2: 25, // box a's right edge -> box b's left edge
        startId: from,
        endId: to));

ShapeData _shape(CanvasState s, String id) => s.currentPage!.layers.content
    .map((e) => e.mapOrNull(shape: (x) => x))
    .firstWhere((x) => x?.id == id)!
    .data;

CanvasState _state(List<ContentElement> content, LassoSelection? lasso) {
  final now = DateTime(2026);
  final page = PageData(
      pageId: 'p',
      pageNumber: 1,
      width: 595,
      height: 842,
      layers: RenderingLayers(content: content));
  return CanvasState(
    metadata: NotebookMetadata(id: 'n', title: 't', createdAt: now, modifiedAt: now),
    document: const DocumentStructure(
        notebookId: 'n',
        pages: [PageEntry(pageId: 'p', pageNumber: 1, fileName: 'p.json')]),
    pages: {'p.json': page},
    lassoSelection: lasso,
    remotePath: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer c;
  late CanvasNotifier n;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    c = ProviderContainer();
    n = c.read(canvasProvider.notifier);
  });
  tearDown(() => c.dispose());

  test('moving a block drags the arrow attached to it', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 0), _arrow('r', 'a', 'b')],
        const LassoSelection(selectedIds: ['b'], bounds: Rect.fromLTWH(200, 0, 100, 50)));
    n.state = n.state!.copyWith(
        lassoSelection: const LassoSelection(
            selectedIds: ['b'],
            bounds: Rect.fromLTWH(200, 0, 100, 50),
            dragOffset: Offset(0, 100)));
    n.applySelectionTransform();
    final d = _shape(n.state!, 'r');
    // b is now diagonally below-right of a: the arrow runs corner to corner.
    expect(d.x1, closeTo(100, 2)); // a's bottom-right
    expect(d.y1, closeTo(50, 2));
    expect(d.x2, closeTo(200, 2)); // b's top-left
    expect(d.y2, closeTo(100, 2));
    expect(d.startId, 'a');
    expect(d.endId, 'b');
  });

  test('moving only the arrow detaches the ends whose block stayed', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 0), _arrow('r', 'a', 'b')], null);
    n.state = n.state!.copyWith(
        lassoSelection: const LassoSelection(
            selectedIds: ['r'],
            bounds: Rect.fromLTWH(100, 25, 100, 0),
            dragOffset: Offset(0, 300)));
    n.applySelectionTransform();
    final d = _shape(n.state!, 'r');
    expect(d.startId, isNull);
    expect(d.endId, isNull);
    expect(d.y1, 325);
  });

  test('chain right copies the block and joins it with an attached arrow', () {
    n.state = _state([_box('a', 0, 0)],
        const LassoSelection(selectedIds: ['a'], bounds: Rect.fromLTWH(0, 0, 100, 50)));
    expect(n.canChainSelection, isTrue);
    n.chainSelection(const Offset(1, 0));
    final content = n.state!.currentPage!.layers.content;
    expect(content.length, 3);
    final arrow = content.last.mapOrNull(shape: (x) => x)!.data;
    expect(arrow.shapeType, 'arrow');
    expect(arrow.startId, 'a');
    expect(arrow.endId, n.state!.lassoSelection!.selectedIds.single);
    expect(arrow.x1, closeTo(100, 2)); // a's right edge
    expect(arrow.x2, closeTo(122, 2)); // copy sits one gap (22) further right
  });

  test('a duplicated arrow points at the duplicated blocks, not the originals', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 0), _arrow('r', 'a', 'b')],
        const LassoSelection(
            selectedIds: ['a', 'b', 'r'], bounds: Rect.fromLTWH(0, 0, 300, 50)));
    n.duplicateSelection();
    final content = n.state!.currentPage!.layers.content;
    final copyArrow = content.last.mapOrNull(shape: (x) => x)!.data;
    final copyIds = n.state!.lassoSelection!.selectedIds;
    expect(copyIds.contains(copyArrow.startId), isTrue);
    expect(copyIds.contains(copyArrow.endId), isTrue);
  });

  test('a loose scribble is not a block to chain', () {
    n.state = _state([
      ContentElement.stroke(
          id: 's',
          zIndex: 0,
          data: StrokeData(points: [
            for (var i = 0; i < 10; i++) StrokePoint(x: i * 10, y: 0)
          ]))
    ], const LassoSelection(selectedIds: ['s'], bounds: Rect.fromLTWH(0, 0, 90, 0)));
    expect(n.canChainSelection, isFalse);
  });
  test('a clicked (not lassoed) block chains, and the copy keeps its resized size', () {
    n.state = _state([
      const ContentElement.shape(
          id: 'a',
          zIndex: 0,
          data: ShapeData(shapeType: 'rectangle', x1: 0, y1: 0, x2: 160, y2: 30))
    ], null);
    n.state = n.state!.copyWith(selectedElementId: 'a');
    expect(n.canChainSelection, isTrue);
    n.chainSelection(const Offset(0, 1));
    final st = n.state!;
    final copy = _shape(st, st.selectedElementId!);
    expect(st.lassoSelection, isNull); // still a click-selection, now on the copy
    expect(copy.x2 - copy.x1, 160);
    expect(copy.y2 - copy.y1, 30);
    expect(copy.y1, greaterThan(30));
  });

  test('moving one clicked block drags its arrow', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 0), _arrow('r', 'a', 'b')], null);
    n.moveElement('b', const Offset(0, 100));
    final d = _shape(n.state!, 'r');
    expect(d.y2, closeTo(100, 2));
  });

  test('resizing one clicked block keeps its arrow on the edge', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 0), _arrow('r', 'a', 'b')], null);
    n.resizeElement('b', const Rect.fromLTWH(200, 0, 300, 50));
    expect(_shape(n.state!, 'r').x2, closeTo(199, 2)); // b's left edge didn't move
    n.resizeElement('a', const Rect.fromLTWH(0, 0, 60, 50));
    expect(_shape(n.state!, 'r').x1, closeTo(61, 2)); // a's right edge now at 60
  });

  test('a built-in block is placed in the pen colour with a see-through fill', () {
    n.state = _state([], null);
    n.state = n.state!.copyWith(
        toolSettings: n.state!.toolSettings.copyWith(color: 0xFFE53935));
    final block = blockDiagramLibrary().symbols.firstWhere((s) => s.id.endsWith('-block'));
    n.insertSymbol(block, const Offset(100, 100));
    final d = _shape(n.state!, n.state!.lassoSelection!.selectedIds.single);
    expect(d.strokeColor, 0xFFE53935);
    expect(d.fillColor, 0x33E53935);
  });
  test('chaining left/up goes the other way and uses the pen colour set since', () {
    n.state = _state([
      const ContentElement.shape(
          id: 'a',
          zIndex: 0,
          data: ShapeData(
              shapeType: 'rectangle',
              x1: 200, y1: 200, x2: 240, y2: 220,
              strokeColor: 0xFF000000,
              fillColor: 0x33000000))
    ], null);
    n.state = n.state!.copyWith(
        selectedElementId: 'a',
        toolSettings: n.state!.toolSettings.copyWith(color: 0xFF1E88E5));
    n.chainSelection(const Offset(-1, 0));
    var st = n.state!;
    var copy = _shape(st, st.selectedElementId!);
    expect(copy.x2, lessThan(200)); // to the left of the original
    expect(copy.strokeColor, 0xFF1E88E5);
    expect(copy.fillColor, 0x331E88E5);
    final arrow = st.currentPage!.layers.content.last.mapOrNull(shape: (x) => x)!.data;
    expect(arrow.strokeColor, 0xFF1E88E5);
    n.chainSelection(const Offset(0, -1));
    st = n.state!;
    copy = _shape(st, st.selectedElementId!);
    expect(copy.y2, lessThan(200)); // and above
  });
  test('chaining a chosen block type scales it to the source height and attaches it', () {
    n.state = _state([_box('a', 0, 0)], null); // 100 x 50
    n.state = n.state!.copyWith(selectedElementId: 'a');
    final decision =
        blockDiagramBlocks().firstWhere((s) => s.id.endsWith('-decision'));
    n.chainSelection(const Offset(1, 0), symbol: decision);
    final st = n.state!;
    final content = st.currentPage!.layers.content;
    final arrow = content.last.mapOrNull(shape: (x) => x)!.data;
    expect(arrow.startId, 'a');
    expect(arrow.endId, st.selectedElementId);
    final body = content
        .firstWhere((e) => e.mapOrNull(stroke: (x) => x.id) == st.selectedElementId)
        .mapOrNull(stroke: (x) => x)!;
    final ys = body.data.points.map((p) => p.y);
    final xs = body.data.points.map((p) => p.x);
    expect(ys.reduce((a, b) => a > b ? a : b) - ys.reduce((a, b) => a < b ? a : b),
        closeTo(50, 1)); // same height as the 50-high source
    expect(xs.reduce((a, b) => a < b ? a : b), greaterThan(100)); // to its right
    expect(arrow.x2, closeTo(xs.reduce((a, b) => a < b ? a : b), 3));
  });
  test('an outline block resizes', () {
    final decision = blockDiagramBlocks().firstWhere((s) => s.id.endsWith('-decision'));
    n.state = _state([], null);
    n.insertSymbol(decision, const Offset(100, 100));
    final id = n.state!.lassoSelection!.selectedIds.first;
    Rect rect() => blockStrokeRect(n.state!.currentPage!.layers.content
        .firstWhere((e) => e.mapOrNull(stroke: (x) => x.id) == id))!;
    final r0 = rect();
    n.resizeElement(id, Rect.fromLTWH(r0.left, r0.top, r0.width * 2, r0.height * 3));
    expect(rect().width, closeTo(r0.width * 2, 0.5));
    expect(rect().height, closeTo(r0.height * 3, 0.5));
  });
  test('centre snapping lines a block up with a neighbour, per axis, within the threshold', () {
    const other = Rect.fromLTWH(100, 0, 40, 20); // centre (120, 10)
    // 3 right of centre-x, 40 below: snaps in x only.
    expect(centerAlignmentSnap(const Rect.fromLTWH(97, 30, 40, 20) /* c (117,40) */, [other], 8),
        const Offset(3, 0));
    // Close on both axes: both snap.
    expect(centerAlignmentSnap(const Rect.fromLTWH(95, 4, 40, 20) /* c (115,14) */, [other], 8),
        const Offset(5, -4));
    // Too far: no snap.
    expect(centerAlignmentSnap(const Rect.fromLTWH(60, 60, 40, 20), [other], 8), Offset.zero);
  });

  test('a snapped drag releases when the pointer moves on (no sticking)', () {
    final t = ElementTransformNotifier()..begin('a');
    Offset snap(Offset raw) => Offset(raw.dx.abs() < 5 ? 0 : raw.dx, raw.dy);
    t.translate(const Offset(3, 0), snap: snap);
    expect(t.dragOffset.dx, 0); // snapped
    t.translate(const Offset(4, 0), snap: snap);
    expect(t.dragOffset.dx, 7); // raw 7 is past the snap range: free again
  });
  test('outline blocks are filled in the pen colour and keep the fill when moved', () {
    n.state = _state([], null);
    n.state = n.state!.copyWith(
        toolSettings: n.state!.toolSettings.copyWith(color: 0xFF2E7D32));
    final rounded = blockDiagramBlocks().firstWhere((s) => s.id.endsWith('-rounded'));
    n.insertSymbol(rounded, const Offset(100, 100));
    final id = n.state!.lassoSelection!.selectedIds.first;
    StrokeData data() => n.state!.currentPage!.layers.content
        .map((e) => e.mapOrNull(stroke: (x) => x))
        .firstWhere((x) => x?.id == id)!
        .data;
    expect(data().fillColor, 0x332E7D32);
    n.moveElement(id, const Offset(30, 0));
    expect(data().fillColor, 0x332E7D32);
    n.resizeElement(id, const Rect.fromLTWH(0, 0, 80, 40));
    expect(data().fillColor, 0x332E7D32);
  });
  test('tidy lines up a slightly crooked row and column, carrying writing and arrows', () {
    // a, b: one row, b 6 lower; c: below a, 5 to the right; "note" is written inside b.
    final note = ContentElement.stroke(
        id: 'note',
        zIndex: 5,
        data: StrokeData(points: [
          for (var i = 0; i < 4; i++) StrokePoint(x: 230.0 + i * 5, y: 36.0)
        ]));
    n.state = _state([
      _box('a', 0, 0), // centre (50, 25)
      _box('b', 200, 6), // centre (250, 31)
      _box('c', 5, 120), // centre (55, 145)
      note,
      _arrow('r', 'a', 'b'),
    ], const LassoSelection(
        selectedIds: ['a', 'b', 'c', 'note', 'r'],
        bounds: Rect.fromLTWH(0, 0, 300, 180)));
    expect(n.canTidySelection, isTrue);
    n.tidySelection();
    final st = n.state!;
    final a = _shape(st, 'a'), b = _shape(st, 'b'), c = _shape(st, 'c');
    expect((a.y1 + a.y2) / 2, closeTo((b.y1 + b.y2) / 2, 0.01)); // same row
    expect((a.x1 + a.x2) / 2, closeTo((c.x1 + c.x2) / 2, 0.01)); // same column
    final noteY = st.currentPage!.layers.content
        .map((e) => e.mapOrNull(stroke: (x) => x))
        .firstWhere((x) => x?.id == 'note')!
        .data
        .points
        .first
        .y;
    expect(noteY, closeTo(36 - 3, 0.01)); // moved with b (b went up by 3)
    final r = _shape(st, 'r');
    expect(r.y1, closeTo(r.y2, 0.5)); // the arrow is level again
    expect(r.startId, 'a');
  });

  test('tidy leaves deliberately offset blocks alone', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 90)],
        const LassoSelection(selectedIds: ['a', 'b'], bounds: Rect.fromLTWH(0, 0, 300, 140)));
    final before = n.state!.currentPage;
    n.tidySelection();
    expect(n.state!.currentPage, before);
  });
  test('an attached arrow between offset blocks is an elbow that leaves and enters by the facing sides', () {
    n.state = _state([_box('a', 0, 0), _box('b', 200, 100), _arrow('r', 'a', 'b')], null);
    n.moveElement('b', Offset.zero); // re-snap
    var d = _shape(n.state!, 'r');
    expect(d.elbow, isNull); // the fixture arrow is a straight one
    n.toggleConnectorElbow('r');
    d = _shape(n.state!, 'r');
    expect(d.elbow, 'h');
    expect(d.x1, closeTo(100, 2)); // a's right side, middle
    expect(d.y1, closeTo(25, 2));
    expect(d.x2, closeTo(200, 2)); // b's left side, middle
    expect(d.y2, closeTo(125, 2));
    final route = connectorRoute(d);
    expect(route.length, 4);
    expect(route[1].dx, route[2].dx); // vertical leg in the middle
    expect(route[1].dy, route[0].dy); // first leg horizontal
    expect(route[2].dy, route[3].dy); // last leg horizontal
    n.toggleConnectorElbow('r'); // and back
    expect(_shape(n.state!, 'r').elbow, isNull);
  });

  test('stacked blocks route vertical-first; chained arrows start out as elbows', () {
    n.state = _state([_box('a', 0, 0), _box('b', 10, 200)], null);
    n.state = n.state!.copyWith(selectedElementId: 'a');
    n.chainSelection(const Offset(0, 1));
    final arrow = n.state!.currentPage!.layers.content.last.mapOrNull(shape: (x) => x)!.data;
    expect(arrow.elbow, 'v');
    expect(connectorRoute(arrow).first.dx, closeTo(connectorRoute(arrow).last.dx, 0.5));
  });
  test('starting from an arrow: a block placed on its tip is attached and sits ahead of it', () {
    const arrowRight = ContentElement.shape(
        id: 'r',
        zIndex: 0,
        data: ShapeData(shapeType: 'arrow', x1: 0, y1: 100, x2: 44, y2: 100));
    n.state = _state([arrowRight], null);
    n.state = n.state!.copyWith(selectedElementId: 'r');
    expect(n.canAddBlockAtConnector('r', atEnd: true), isTrue);
    expect(n.canAddBlockAtConnector('r', atEnd: false), isTrue);
    final block = blockDiagramBlocks().firstWhere((s) => s.id.endsWith('-block'));
    n.addBlockAtConnector('r', block, atEnd: true);
    final st = n.state!;
    final arrow = _shape(st, 'r');
    expect(arrow.endId, st.selectedElementId); // attached, and selected for chaining
    expect(arrow.startId, isNull); // the start is still free
    final body = _shape(st, st.selectedElementId!);
    expect(body.x1, greaterThan(40)); // ahead of the tip, not behind it
    expect(arrow.x2, closeTo(body.x1, 2)); // the tip meets the block's near side
    expect(n.canAddBlockAtConnector('r', atEnd: true), isFalse); // that end is taken
    expect(n.canAddBlockAtConnector('r', atEnd: false), isTrue);
  });

  test('a block at the arrow start goes behind it, and a downward arrow gets one below', () {
    const down = ContentElement.shape(
        id: 'd',
        zIndex: 0,
        data: ShapeData(shapeType: 'arrow', x1: 50, y1: 0, x2: 50, y2: 44));
    n.state = _state([down], null);
    final block = blockDiagramBlocks().firstWhere((s) => s.id.endsWith('-block'));
    n.addBlockAtConnector('d', block, atEnd: true);
    var body = _shape(n.state!, n.state!.selectedElementId!);
    expect(body.y1, greaterThan(40)); // below the tip
    n.addBlockAtConnector('d', block, atEnd: false);
    body = _shape(n.state!, n.state!.selectedElementId!);
    expect(body.y2, lessThan(5)); // above the start
  });
  test('an empty arrow off a block is attached at its start, free at the tip, and selected', () {
    n.state = _state([_box('a', 0, 0)], null); // 100 x 50
    n.state = n.state!.copyWith(selectedElementId: 'a');
    n.chainSelection(const Offset(1, 0), arrowOnly: true);
    final st = n.state!;
    expect(st.currentPage!.layers.content.length, 2); // no extra block
    final arrowId = st.selectedElementId!;
    final arrow = _shape(st, arrowId);
    expect(arrow.shapeType, 'arrow');
    expect(arrow.startId, 'a');
    expect(arrow.endId, isNull);
    expect(arrow.x1, closeTo(100, 2)); // leaves a's right side
    expect(arrow.x2, greaterThan(arrow.x1 + 20)); // pointing right, tip free
    expect(n.canAddBlockAtConnector(arrowId, atEnd: true), isTrue);
    // ...and the tip can then take a block, which finishes the chain.
    n.addBlockAtConnector(arrowId, blockDiagramBlocks().first, atEnd: true);
    expect(_shape(n.state!, arrowId).endId, n.state!.selectedElementId);
  });
}
