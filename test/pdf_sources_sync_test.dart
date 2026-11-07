// Source PDFs of imported pages live in `sources/`, a folder builds before
// 0.37.10 never look at. These tests pin both halves of that bargain: new
// builds mirror it between devices, and the old sync and package paths leave
// it alone.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:abelnotes/config/app_config.dart';
import 'package:abelnotes/core/services/file_service.dart';
import 'package:abelnotes/core/services/sync_service.dart';
import 'package:abelnotes/features/canvas/data/pdf_sources.dart';
import 'package:abelnotes/shared/models/ncnote_format.dart';

import 'support/fake_remote_store.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

const _src = '/AbelNotes/${AppConfig.deltaSyncDir}nb/sources/';
final _pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 fake'));
const _index = PdfSourceIndex(id: 'imp', pdf: 'imp.pdf', pages: {'a.png': 0});

void main() {
  late Directory tmp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('pdfsync'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final metadata = NotebookMetadata(
    id: 'nb',
    title: 'T',
    createdAt: DateTime.utc(2020),
    modifiedAt: DateTime.utc(2020),
  );
  const document = DocumentStructure(notebookId: 'nb', pages: []);

  group('syncPdfSources', () {
    test('uploads the PDF before its index, then the other device gets both',
        () async {
      final server = FakeRemoteStore();
      final a = PdfSourceStore(p.join(tmp.path, 'a'));
      await a.save(_index, _pdf);

      expect(await SyncService(server).syncPdfSources('nb', a), isFalse);
      final uploads =
          server.calls.where((c) => c.startsWith('upload')).toList();
      expect(uploads.indexWhere((c) => c.contains('imp.pdf')),
          lessThan(uploads.indexWhere((c) => c.contains('imp.json'))));
      expect(server.files.keys,
          containsAll(['${_src}imp.pdf', '${_src}imp.json']));

      final b = PdfSourceStore(p.join(tmp.path, 'b'));
      expect(await SyncService(server).syncPdfSources('nb', b), isTrue);
      expect(await b.read('imp.pdf'), _pdf);
      expect((await b.loadIndexes()).single.pages, {'a.png': 0});

      final before = server.calls.length;
      expect(await SyncService(server).syncPdfSources('nb', b), isFalse);
      expect(server.calls.skip(before).where((c) => c.startsWith('upload')),
          isEmpty);
    });

    test('a retired import goes everywhere and never comes back', () async {
      final server = FakeRemoteStore();
      final a = PdfSourceStore(p.join(tmp.path, 'a'));
      final b = PdfSourceStore(p.join(tmp.path, 'b'));
      await a.save(_index, _pdf);
      await SyncService(server).syncPdfSources('nb', a);
      await SyncService(server).syncPdfSources('nb', b);
      expect(await b.list(), {'imp.pdf', 'imp.json'});

      await a.retire(_index);
      expect(await SyncService(server).syncPdfSources('nb', a), isFalse);
      expect(server.files.keys.where((k) => k.startsWith(_src)),
          ['${_src}imp.gone']);

      // B still holds the files: it drops them instead of uploading them.
      expect(await SyncService(server).syncPdfSources('nb', b), isTrue);
      expect(await b.list(), {'imp.gone'});
      expect(server.files.keys.where((k) => k.startsWith(_src)),
          ['${_src}imp.gone']);
      expect(await b.loadIndexes(), isEmpty);
    });

    test('nothing on either side touches nothing', () async {
      final server = FakeRemoteStore();
      final local = PdfSourceStore(p.join(tmp.path, 'a'));
      expect(await SyncService(server).syncPdfSources('nb', local), isFalse);
      expect(server.directories, isNot(contains(_src)));
    });

    test('ignores remote names that would leave the folder', () async {
      final server = FakeRemoteStore();
      final local = PdfSourceStore(p.join(tmp.path, 'a'));
      server.directories
        ..add('/AbelNotes/')
        ..add('/AbelNotes/${AppConfig.deltaSyncDir}')
        ..add('/AbelNotes/${AppConfig.deltaSyncDir}nb/')
        ..add(_src);
      server.files['${_src}half.pdf.tmp'] = _pdf;
      expect(await SyncService(server).syncPdfSources('nb', local), isFalse);
      expect(await local.list(), isEmpty);
    });
  });

  test('an old-style delta sync leaves the server copy alone', () async {
    final server = FakeRemoteStore();
    final local = PdfSourceStore(p.join(tmp.path, 'a'));
    await local.save(_index, _pdf);
    final sync = SyncService(server);
    await sync.syncPdfSources('nb', local);
    await sync.syncDelta(
      notebookId: 'nb',
      metadata: metadata,
      document: document,
      dirtyPages: const {},
      dirtyAssets: {
        'a.png': Uint8List.fromList([1])
      },
    );
    await sync.syncDelta(
      notebookId: 'nb',
      metadata: metadata,
      document: document,
      dirtyPages: const {},
      deletedAssetFileNames: const ['a.png'],
    );
    expect(
        server.files.keys, containsAll(['${_src}imp.pdf', '${_src}imp.json']));
    expect(
        server.calls
            .where((c) => c.startsWith('delete') && c.contains('sources')),
        isEmpty);
  });

  group('local package', () {
    late FileService fs;
    setUp(() async {
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      fs = FileService();
      await fs.init();
    });

    Uint8List zip({bool withSources = false}) {
      final a = Archive();
      void add(String name, List<int> b) =>
          a.addFile(ArchiveFile(name, b.length, b));
      add(AppConfig.metadataFile, utf8.encode(jsonEncode(metadata.toJson())));
      add(AppConfig.documentFile, utf8.encode(jsonEncode(document.toJson())));
      if (withSources) add('$kPdfSourcesDir/imp.pdf', _pdf);
      return Uint8List.fromList(ZipEncoder().encode(a)!);
    }

    test('a package without sources keeps the ones on disk', () async {
      await fs.explodeZipToLooseStore('nb', zip());
      final store = PdfSourceStore(fs.notebookStoreDir('nb'));
      await store.save(_index, _pdf);
      await fs.explodeZipToLooseStore('nb', zip());
      expect(await store.list(), {'imp.pdf', 'imp.json'});
    });

    test('packing carries sources to other devices', () async {
      await fs.explodeZipToLooseStore('nb', zip());
      await PdfSourceStore(fs.notebookStoreDir('nb')).save(_index, _pdf);
      final packed = (await fs.assembleZipFromLooseStore('nb'))!;
      final names = ZipDecoder().decodeBytes(packed).files.map((f) => f.name);
      expect(names, containsAll(['sources/imp.pdf', 'sources/imp.json']));
    });
  });
}
