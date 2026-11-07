import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:abelnotes/features/canvas/data/pdf_sources.dart';

/// Renders tiles of imported pages from their source PDFs (PDFium).
class PdfSourceRenderer {
  final PdfSourceStore store;

  /// Asset key → page; replaced whenever the notebook's indexes change.
  Map<String, PdfSourceLink> links;

  final LinkedHashMap<String, Future<PdfDocument?>> _docs = LinkedHashMap();
  static const _maxOpenDocs = 3;
  bool _disposed = false;

  PdfSourceRenderer(this.store, {this.links = const {}});

  bool covers(String assetPath) => links.containsKey(assetPath);

  Future<ui.Image?> render(
      String assetPath, ui.Rect pixels, double fullW, double fullH) async {
    final link = links[assetPath];
    if (link == null || _disposed) return null;
    final doc = await _open(link.pdf);
    if (doc == null || _disposed || link.page >= doc.pages.length) return null;
    final img = await doc.pages[link.page].render(
      x: pixels.left.round(),
      y: pixels.top.round(),
      width: pixels.width.round(),
      height: pixels.height.round(),
      fullWidth: fullW,
      fullHeight: fullH,
      backgroundColor: 0xFFFFFFFF,
    );
    if (img == null) return null;
    try {
      return await img.createImage();
    } finally {
      img.dispose();
    }
  }

  Future<PdfDocument?> _open(String pdf) {
    final open = _docs.remove(pdf);
    if (open != null) {
      _docs[pdf] = open;
      return open;
    }
    final fresh = _load(pdf);
    _docs[pdf] = fresh;
    while (_docs.length > _maxOpenDocs) {
      final oldest = _docs.remove(_docs.keys.first)!;
      oldest.then((d) => d?.dispose());
    }
    return fresh;
  }

  Future<PdfDocument?> _load(String pdf) async {
    try {
      final bytes = await store.read(pdf);
      if (bytes == null) return null;
      await pdfrxFlutterInitialize();
      return await PdfDocument.openData(bytes, sourceName: 'source:$pdf');
    } catch (e) {
      debugPrint('[PdfSources] cannot open $pdf: $e');
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    for (final d in _docs.values) {
      d.then((doc) => doc?.dispose());
    }
    _docs.clear();
  }
}

/// The PDF to keep for an import: every source page when [pageIndexes]
/// covers them all, otherwise a copy holding just those pages. Always
/// without the password, which the user already gave at import.
Future<Uint8List> pdfSourceBytes(PdfDocument doc, List<int> pageIndexes) async {
  final all = pageIndexes.length == doc.pages.length &&
      [for (var i = 0; i < pageIndexes.length; i++) pageIndexes[i] == i]
          .every((b) => b);
  if (all) return doc.encodePdf(removeSecurity: true);
  final copy = await PdfDocument.createNew(sourceName: 'import-subset');
  try {
    copy.pages = [for (final i in pageIndexes) doc.pages[i]];
    return await copy.encodePdf(removeSecurity: true);
  } finally {
    await copy.dispose();
  }
}
