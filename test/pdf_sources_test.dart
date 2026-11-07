import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as gen;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import 'package:abelnotes/features/canvas/data/pdf_source_renderer.dart';
import 'package:abelnotes/features/canvas/data/pdf_sources.dart';

/// Three A4 pages; page i has a black square at (100 + 100 i, 100) pt.
Future<Uint8List> _threePages() {
  final doc = pw.Document();
  for (var i = 0; i < 3; i++) {
    doc.addPage(pw.Page(
      pageFormat: gen.PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [
        pw.Positioned(
          left: 100.0 + 100 * i,
          top: 100,
          child:
              pw.Container(width: 60, height: 60, color: gen.PdfColors.black),
        ),
      ]),
    ));
  }
  return doc.save();
}

Future<int> _red(ui.Image img, int x, int y) async {
  final data = (await img.toByteData())!;
  return data.getUint8((y * img.width + x) * 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pdfsrc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('PdfSourceIndex', () {
    test('round-trips', () {
      const idx = PdfSourceIndex(
          id: 'imp1', pdf: 'imp1.pdf', pages: {'a.png': 0, 'b.png': 2});
      final back = PdfSourceIndex.tryParse('imp1', idx.encode())!;
      expect(back.pdf, 'imp1.pdf');
      expect(back.pages, {'a.png': 0, 'b.png': 2});
    });

    test('keeps the import time; older indexes have none', () {
      const idx =
          PdfSourceIndex(id: 'i', pdf: 'i.pdf', pages: {}, createdMs: 42);
      expect(PdfSourceIndex.tryParse('i', idx.encode())!.createdMs, 42);
      final old =
          Uint8List.fromList('{"v":1,"pdf":"i.pdf","pages":{}}'.codeUnits);
      expect(PdfSourceIndex.tryParse('i', old)!.createdMs, isNull);
      expect(pdfSourceIdOf('abc.gone'), 'abc');
      expect(pdfSourceIdOf('abc.json'), 'abc');
    });

    test('rejects names that leave the folder and garbage', () {
      for (final bad in ['../x.pdf', 'a/b.pdf', r'a\b.pdf', '..', '']) {
        expect(PdfSourceIndex.isSafeName(bad), isFalse, reason: bad);
      }
      final evil =
          Uint8List.fromList('{"pdf":"../../etc/passwd","pages":{}}'.codeUnits);
      expect(PdfSourceIndex.tryParse('x', evil), isNull);
      expect(
          PdfSourceIndex.tryParse('x', Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('links cover every import', () {
      final links = pdfSourceLinks(const [
        PdfSourceIndex(id: '1', pdf: '1.pdf', pages: {'a': 0}),
        PdfSourceIndex(id: '2', pdf: '2.pdf', pages: {'b': 4}),
      ]);
      expect(links['a'], const PdfSourceLink('1.pdf', 0));
      expect(links['b'], const PdfSourceLink('2.pdf', 4));
    });
  });

  group('PdfSourceStore', () {
    test('saves, lists and loads; an index waits for its PDF', () async {
      final store = PdfSourceStore(tmp.path);
      await store.save(
          const PdfSourceIndex(id: 'i1', pdf: 'i1.pdf', pages: {'a': 0}),
          Uint8List.fromList([1, 2, 3]));
      await store.writeFile(
          'i2.json',
          const PdfSourceIndex(id: 'i2', pdf: 'i2.pdf', pages: {'b': 0})
              .encode());
      expect(await store.list(), {'i1.pdf', 'i1.json', 'i2.json'});
      final loaded = await store.loadIndexes();
      expect(loaded.map((i) => i.id), ['i1']);
      expect(await store.read('i1.pdf'), [1, 2, 3]);
      expect(Directory('${tmp.path}/$kPdfSourcesDir').existsSync(), isTrue);
      await store.delete('i1.pdf');
      expect(await store.read('i1.pdf'), isNull);
    });

    test('copyTo carries live imports, not retire markers or half imports',
        () async {
      final from = PdfSourceStore('${tmp.path}/a');
      await from.save(
          const PdfSourceIndex(id: 'i1', pdf: 'i1.pdf', pages: {'a': 0}),
          Uint8List.fromList([1, 2, 3]));
      await from.writeFile(
          'i2.json',
          const PdfSourceIndex(id: 'i2', pdf: 'i2.pdf', pages: {'b': 0})
              .encode());
      await from.writeFile('i3$kGoneSuffix', Uint8List(0));
      final to = PdfSourceStore('${tmp.path}/b');
      await from.copyTo(to);
      expect(await to.list(), {'i1.pdf', 'i1.json'});
      expect(await to.read('i1.pdf'), [1, 2, 3]);
    });

    test('refuses unsafe names', () async {
      expect(() => PdfSourceStore(tmp.path).writeFile('../x', Uint8List(1)),
          throwsArgumentError);
    });
  });

  // PDFium is a native library the test runner doesn't ship: point
  // ABELNOTES_PDFIUM at a built bundle's lib/libpdfium.so to run these.
  final pdfium = Platform.environment['ABELNOTES_PDFIUM'];
  group('with PDFium', () {
    setUpAll(() async {
      Pdfrx.cacheDirectoryPath =
          Directory.systemTemp.createTempSync('pdfrx').path;
      Pdfrx.pdfiumModulePath = pdfium;
      await pdfrxFlutterInitialize();
    });

    test('keeps only the imported pages', () async {
      final doc = await PdfDocument.openData(await _threePages());
      final whole = await pdfSourceBytes(doc, [0, 1, 2]);
      final third = await pdfSourceBytes(doc, [2]);
      await doc.dispose();
      final a = await PdfDocument.openData(whole);
      final b = await PdfDocument.openData(third);
      expect(a.pages.length, 3);
      expect(b.pages.length, 1);
      await a.dispose();
      await b.dispose();
    });

    test('renders a tile of the right page and place', () async {
      final store = PdfSourceStore(tmp.path);
      final doc = await PdfDocument.openData(await _threePages());
      await store.save(
          const PdfSourceIndex(id: 'i', pdf: 'i.pdf', pages: {'p2': 0}),
          await pdfSourceBytes(doc, [1]));
      await doc.dispose();
      final r = PdfSourceRenderer(store,
          links: pdfSourceLinks(await store.loadIndexes()));
      // 4 px/pt: page 2's square spans 200..260 pt = 800..1040 px across.
      const d = 4.0;
      final img = await r.render('p2',
          const ui.Rect.fromLTWH(768, 384, 512, 512), 595.28 * d, 841.89 * d);
      expect(img, isNotNull);
      expect(img!.width, 512);
      expect(await _red(img, 100, 100), lessThan(30),
          reason: 'inside the square');
      expect(await _red(img, 10, 10), greaterThan(225), reason: 'paper');
      expect(
          await r.render('missing', const ui.Rect.fromLTWH(0, 0, 8, 8), 10, 10),
          isNull);
      img.dispose();
      r.dispose();
    });
  }, skip: pdfium == null ? 'set ABELNOTES_PDFIUM to run' : null);
}
