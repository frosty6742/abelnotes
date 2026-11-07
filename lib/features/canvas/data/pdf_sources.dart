import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:abelnotes/core/platform/io.dart';

/// Folder, next to `pages/` and `assets/`, holding the PDFs that imported
/// pages were rendered from. Builds before 0.37.10 never list it, so they
/// neither download, decode nor delete what is inside. See
/// lib/features/canvas/data/PDF_SOURCES.md.
const String kPdfSourcesDir = 'sources';

/// Suffix of the marker that retires an import (see [PdfSourceIndex.goneName]).
const String kGoneSuffix = '.gone';

/// Import id of a file in `sources/`: `<id>.pdf`, `<id>.json`, `<id>.gone`.
String pdfSourceIdOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// One PDF import: the PDF file and which page each image asset shows.
/// Written once at import and never edited, so devices can't conflict on it.
@immutable
class PdfSourceIndex {
  /// Import id; the files are `<id>.json` and [pdf].
  final String id;
  final String pdf;

  /// Image asset key → zero-based page index in [pdf].
  final Map<String, int> pages;

  /// Import time, ms since epoch; null in indexes written before it existed.
  final int? createdMs;

  const PdfSourceIndex(
      {required this.id,
      required this.pdf,
      required this.pages,
      this.createdMs});

  String get fileName => '$id.json';

  /// Marker left when the import is cleaned up, so devices that still hold
  /// the files delete them instead of uploading them back.
  String get goneName => '$id$kGoneSuffix';

  Map<String, dynamic> toJson() => {
        'v': 1,
        'pdf': pdf,
        'pages': pages,
        if (createdMs != null) 't': createdMs
      };

  static PdfSourceIndex? tryParse(String id, Uint8List bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final pdf = j['pdf'] as String?;
      final pages = (j['pages'] as Map?)
          ?.map((k, v) => MapEntry(k as String, (v as num).toInt()));
      if (pdf == null || pages == null || !isSafeName(pdf)) return null;
      return PdfSourceIndex(
          id: id, pdf: pdf, pages: pages, createdMs: (j['t'] as num?)?.toInt());
    } catch (_) {
      return null;
    }
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// File names come from other devices: a plain name, nothing that walks
  /// out of the folder.
  static bool isSafeName(String name) =>
      name.isNotEmpty &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      name != '.' &&
      name != '..';
}

/// Where an image asset's page lives.
@immutable
class PdfSourceLink {
  final String pdf;
  final int page;
  const PdfSourceLink(this.pdf, this.page);

  @override
  bool operator ==(Object other) =>
      other is PdfSourceLink && other.pdf == pdf && other.page == page;

  @override
  int get hashCode => Object.hash(pdf, page);
}

/// Asset key → page, over every import of a notebook. A later import of the
/// same bytes (deduplicated asset) points at an equally good copy, so any
/// entry wins.
Map<String, PdfSourceLink> pdfSourceLinks(Iterable<PdfSourceIndex> indexes) => {
      for (final i in indexes)
        for (final e in i.pages.entries) e.key: PdfSourceLink(i.pdf, e.value),
    };

/// The `sources/` folder of one notebook's local store.
class PdfSourceStore {
  final String dir;
  PdfSourceStore(String storeDir) : dir = p.join(storeDir, kPdfSourcesDir);

  Future<void> writeFile(String name, Uint8List bytes) async {
    if (!PdfSourceIndex.isSafeName(name)) {
      throw ArgumentError.value(name, 'name', 'not a plain file name');
    }
    await Directory(dir).create(recursive: true);
    final tmp = File(p.join(dir, '$name.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(p.join(dir, name));
  }

  /// PDF first: an index on disk always has its PDF.
  Future<void> save(PdfSourceIndex index, Uint8List pdfBytes) async {
    await writeFile(index.pdf, pdfBytes);
    await writeFile(index.fileName, index.encode());
  }

  Future<Uint8List?> read(String name) async {
    if (!PdfSourceIndex.isSafeName(name)) return null;
    final f = File(p.join(dir, name));
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Names of the finished files in the folder.
  Future<Set<String>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return {};
    return {
      await for (final e in d.list())
        if (e is File && !e.path.endsWith('.tmp')) p.basename(e.path),
    };
  }

  Future<List<PdfSourceIndex>> loadIndexes() async {
    final out = <PdfSourceIndex>[];
    for (final name in await list()) {
      if (!name.endsWith('.json')) continue;
      final bytes = await read(name);
      if (bytes == null) continue;
      final idx = PdfSourceIndex.tryParse(
          name.substring(0, name.length - '.json'.length), bytes);
      // An index whose PDF hasn't arrived yet is skipped until it does.
      if (idx != null && await File(p.join(dir, idx.pdf)).exists()) {
        out.add(idx);
      }
    }
    return out;
  }

  /// Copies every live import (index and PDF, not retire markers) into
  /// [other], PDF first; for a duplicated notebook, whose asset keys match.
  Future<void> copyTo(PdfSourceStore other) async {
    for (final idx in await loadIndexes()) {
      final pdf = await read(idx.pdf);
      final index = await read(idx.fileName);
      if (pdf == null || index == null) continue;
      await other.writeFile(idx.pdf, pdf);
      await other.writeFile(idx.fileName, index);
    }
  }

  /// Retires [index]: leaves the marker, then removes its files.
  Future<void> retire(PdfSourceIndex index) async {
    await writeFile(index.goneName, Uint8List(0));
    await delete(index.fileName);
    await delete(index.pdf);
  }

  Future<void> delete(String name) async {
    if (!PdfSourceIndex.isSafeName(name)) return;
    final f = File(p.join(dir, name));
    if (await f.exists()) await f.delete();
  }
}
