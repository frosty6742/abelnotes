import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/core/providers/canvas_state.dart';
import 'package:abelnotes/core/services/block_diagram_symbols.dart';
import 'package:abelnotes/core/services/symbol_library_service.dart';

void main() {
  test('ids are unique and every block survives a JSON round trip', () {
    final lib = blockDiagramLibrary();
    final ids = lib.symbols.map((s) => s.id).toSet();
    expect(ids.length, lib.symbols.length);
    for (final s in lib.symbols) {
      expect(s.elements, isNotEmpty);
      expect(s.bounds.width, greaterThan(0));
    }
    final back = SymbolCollection.fromJson(
        SymbolCollection(libraries: [lib]).toJson());
    expect(back.symbolCount, lib.symbols.length);
  });

  test('re-seeding on every open neither duplicates nor resurrects deletions', () {
    final seeded = SymbolCollection(libraries: [blockDiagramLibrary()]);
    expect(seeded.mergedWith(seeded).symbolCount, seeded.symbolCount);

    const gone = 'builtin-bd4-decision';
    final deleted = SymbolCollection(
      libraries: [
        blockDiagramLibrary().copyWith(
            symbols: blockDiagramLibrary()
                .symbols
                .where((s) => s.id != gone)
                .toList())
      ],
      deletedSymbolIds: const {gone},
    );
    final merged = deleted.mergedWith(seeded);
    expect(merged.libraries.single.symbols.any((s) => s.id == gone), isFalse);
  });
  test('the retired library is removed, the new one takes its place', () {
    const old = SymbolCollection(
        libraries: [SymbolLibrary(id: 'builtin-block-diagram', name: 'old')]);
    final merged = old.mergedWith(SymbolCollection(
        libraries: [blockDiagramLibrary()],
        deletedLibraryIds: retiredBlockDiagramLibraryIds));
    expect(merged.libraries.map((l) => l.id), [blockDiagramLibraryId]);
  });
}
