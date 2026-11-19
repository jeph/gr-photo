import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grphoto/src/platform/media_saver.dart';
import 'package:grphoto/src/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.jeph.grphoto/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) reply;

  setUp(() {
    calls = [];
    reply = (_) async => null;
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  File file(String name) => File('/cache/downloads/$name');
  const album = SaveToAlbum('GR Photo');

  List<Map<Object?, Object?>> sentFiles() =>
      ((calls.single.arguments as Map<Object?, Object?>)['files']!
              as List<Object?>)
          .cast<Map<Object?, Object?>>();

  test('a RAW+JPEG pair is sent JPEG first, DNG second', () async {
    await PlatformMediaSaver().saveShot([
      file('R0001234.DNG'),
      file('R0001234.JPG'),
    ], to: album);

    expect(calls.single.method, 'saveShot');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['album'], 'GR Photo');
    expect(args.containsKey('folder'), isFalse);
    expect(sentFiles(), [
      {
        'path': '/cache/downloads/R0001234.JPG',
        'name': 'R0001234.JPG',
        'kind': 'jpeg',
        'mimeType': 'image/jpeg',
      },
      {
        'path': '/cache/downloads/R0001234.DNG',
        'name': 'R0001234.DNG',
        'kind': 'dng',
        'mimeType': 'image/x-adobe-dng',
      },
    ]);
  });

  test('single files carry their kind and MIME type', () async {
    final saver = PlatformMediaSaver();
    await saver.saveShot([file('R0001235.jpeg')], to: album);
    await saver.saveShot([file('R0001236.dng')], to: album);
    await saver.saveShot([file('R0001237.MOV')], to: album);

    expect(
      [
        for (final c in calls)
          for (final f
              in ((c.arguments as Map<Object?, Object?>)['files']!
                      as List<Object?>)
                  .cast<Map<Object?, Object?>>())
            (f['kind'], f['mimeType']),
      ],
      [
        ('jpeg', 'image/jpeg'),
        ('dng', 'image/x-adobe-dng'),
        ('movie', 'video/quicktime'),
      ],
    );
  });

  test('files that are not one shot are refused before the channel', () async {
    final saver = PlatformMediaSaver();
    for (final shot in [
      <File>[],
      [file('R0001234.JPG'), file('R0001235.JPG')],
      [file('R0001234.DNG'), file('R0001234.MOV')],
      [file('R0001234.JPG'), file('R0001234.DNG'), file('R0001234.MOV')],
      [file('R0001234.TIF')],
      [file('README')],
    ]) {
      await expectLater(
        saver.saveShot(shot, to: album),
        throwsA(
          isA<MediaSaveException>().having(
            (e) => e.failure,
            'failure',
            MediaSaveFailure.unsupported,
          ),
        ),
        reason: shot.map((f) => f.path).join(', '),
      );
    }
    expect(calls, isEmpty);
  });

  test('a native permission denial maps to permissionDenied', () async {
    reply = (_) async => throw PlatformException(
      code: 'permissionDenied',
      message: 'GR Photo may not add to Photos',
    );
    await expectLater(
      PlatformMediaSaver().saveShot([file('R0001234.JPG')], to: album),
      throwsA(
        isA<MediaSaveException>()
            .having(
              (e) => e.failure,
              'failure',
              MediaSaveFailure.permissionDenied,
            )
            .having((e) => e.blocksEverySave, 'blocksEverySave', isTrue)
            .having(
              (e) => e.detail,
              'detail',
              'permissionDenied: GR Photo may not add to Photos',
            ),
      ),
    );
  });

  test('unknown native errors map to failed', () async {
    reply = (_) async => throw PlatformException(code: 'IOException');
    await expectLater(
      PlatformMediaSaver().saveShot([file('R0001234.JPG')], to: album),
      throwsA(
        isA<MediaSaveException>()
            .having((e) => e.failure, 'failure', MediaSaveFailure.failed)
            .having((e) => e.blocksEverySave, 'blocksEverySave', isFalse),
      ),
    );
  });

  test('a missing native side is reported as unsupported', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      PlatformMediaSaver().saveShot([file('R0001234.JPG')], to: album),
      throwsA(
        isA<MediaSaveException>().having(
          (e) => e.failure,
          'failure',
          MediaSaveFailure.unsupported,
        ),
      ),
    );
  });

  test('a shot for a folder is sent with the id the picker gave', () async {
    await PlatformMediaSaver().saveShot([
      file('R0001234.JPG'),
    ], to: const SaveFolder(id: 'folder-1', name: 'Imports'));

    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['folder'], 'folder-1');
    expect(args.containsKey('album'), isFalse);
    expect(sentFiles().single['name'], 'R0001234.JPG');
  });

  test('a folder that can no longer be written to maps to '
      'folderUnavailable, which blocks every save', () async {
    reply = (_) async => throw PlatformException(code: 'folderUnavailable');
    await expectLater(
      PlatformMediaSaver().saveShot([
        file('R0001234.JPG'),
      ], to: const SaveFolder(id: 'folder-1', name: 'Imports')),
      throwsA(
        isA<MediaSaveException>()
            .having(
              (e) => e.failure,
              'failure',
              MediaSaveFailure.folderUnavailable,
            )
            .having((e) => e.blocksEverySave, 'blocksEverySave', isTrue),
      ),
    );
  });

  test('picking a folder returns its id and name', () async {
    reply = (_) async => {'id': 'folder-1', 'name': 'Imports'};
    final folder = await PlatformMediaSaver().pickFolder();

    expect(calls.single.method, 'pickFolder');
    expect(folder?.id, 'folder-1');
    expect(folder?.name, 'Imports');
  });

  test('leaving the folder picker without a folder returns none', () async {
    expect(await PlatformMediaSaver().pickFolder(), isNull);
  });

  test('a picker answer that is no folder is a failure', () async {
    reply = (_) async => {'id': 'folder-1'};
    await expectLater(
      PlatformMediaSaver().pickFolder(),
      throwsA(
        isA<MediaSaveException>().having(
          (e) => e.failure,
          'failure',
          MediaSaveFailure.failed,
        ),
      ),
    );
  });

  test('a picker the platform could not show is a failure', () async {
    reply = (_) async => throw PlatformException(code: 'failed');
    await expectLater(
      PlatformMediaSaver().pickFolder(),
      throwsA(
        isA<MediaSaveException>().having(
          (e) => e.failure,
          'failure',
          MediaSaveFailure.failed,
        ),
      ),
    );
  });

  test('forgetting a folder sends its id', () async {
    await PlatformMediaSaver().forgetFolder(
      const SaveFolder(id: 'folder-1', name: 'Imports'),
    );

    expect(calls.single.method, 'forgetFolder');
    expect(calls.single.arguments, {'id': 'folder-1'});
  });
}
