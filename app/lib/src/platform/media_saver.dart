import 'dart:io';

import 'package:flutter/services.dart';

import 'package:grphoto/src/services.dart';

/// [MediaSaver] over the `io.jeph.grphoto/media` method channel.
///
/// A shot is sent as `{files: [{path, name, kind, mimeType}]}` with either
/// `album` or `folder`, the JPEG before the DNG, because iOS makes the
/// first file of a pair the primary photo and the second its RAW alternate.
///
/// With `album`, Android writes each file as its own MediaStore entry under
/// `Pictures/<album>`, the folder gallery apps show as the album. iOS adds
/// the shot to the Photos album of that title, which takes full access to
/// Photos; with limited or add-only access it saves the shot outside the
/// album.
///
/// With `folder` (the id `pickFolder` returned), both write the files into
/// that folder under their names, never over a file already there.
final class PlatformMediaSaver implements MediaSaver {
  new({this._channel = const MethodChannel('io.jeph.grphoto/media')});

  final MethodChannel _channel;

  @override
  Future<void> saveShot(List<File> files, {required SaveDestination to}) async {
    final entries = [for (final f in files) _entry(f)]
      ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    final kinds = [for (final e in entries) e.kind];
    final supported = switch (kinds) {
      [_] => true,
      [_MediaKind.jpeg, _MediaKind.dng] => true,
      _ => false,
    };
    if (!supported) {
      throw MediaSaveException(
        MediaSaveFailure.unsupported,
        'not one shot: ${files.map((f) => _name(f.path)).join(', ')}',
      );
    }
    await _invoke<void>('saveShot', {
      ...switch (to) {
        SaveToAlbum(:final name) => {'album': name},
        SaveFolder(:final id) => {'folder': id},
      },
      'files': [
        for (final e in entries)
          {
            'path': e.file.path,
            'name': _name(e.file.path),
            'kind': e.kind.name,
            'mimeType': e.kind.mimeType,
          },
      ],
    });
  }

  @override
  Future<SaveFolder?> pickFolder() async {
    final picked = await _invoke<Map<Object?, Object?>>('pickFolder');
    return switch (picked) {
      null => null,
      {'id': final String id, 'name': final String name} => SaveFolder(
        id: id,
        name: name,
      ),
      _ => throw MediaSaveException(
        MediaSaveFailure.failed,
        'pickFolder returned $picked',
      ),
    };
  }

  @override
  Future<void> forgetFolder(SaveFolder folder) =>
      _invoke<void>('forgetFolder', {'id': folder.id});

  /// Calls [method], turning what the platform reports into a
  /// [MediaSaveException].
  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      final failure = switch (e.code) {
        'permissionDenied' => MediaSaveFailure.permissionDenied,
        'folderUnavailable' => MediaSaveFailure.folderUnavailable,
        'unsupported' => MediaSaveFailure.unsupported,
        _ => MediaSaveFailure.failed,
      };
      throw MediaSaveException(failure, [e.code, ?e.message].join(': '));
    } on MissingPluginException {
      throw const MediaSaveException(
        MediaSaveFailure.unsupported,
        'no media channel on this platform',
      );
    }
  }

  static ({File file, _MediaKind kind}) _entry(File file) {
    final name = _name(file.path);
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final kind = switch (ext) {
      'jpg' || 'jpeg' => _MediaKind.jpeg,
      'dng' => _MediaKind.dng,
      'mov' => _MediaKind.movie,
      _ => throw MediaSaveException(
        MediaSaveFailure.unsupported,
        'not a JPEG, DNG or MOV file: $name',
      ),
    };
    return (file: file, kind: kind);
  }

  static String _name(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// Declaration order is the order files are sent in.
enum _MediaKind {
  jpeg('image/jpeg'),
  dng('image/x-adobe-dng'),
  movie('video/quicktime');

  new(this.mimeType);

  final String mimeType;
}
