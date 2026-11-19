import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import 'package:grphoto/l10n/app_localizations.dart';
import 'package:grphoto/src/data/json_file.dart';
import 'package:grphoto/src/services.dart';
import 'package:grphoto/src/theme/tokens.dart';

/// How long the camera's Wi-Fi stays connected without use before the app
/// leaves it.
enum AutoDisconnect {
  oneMinute(Duration(minutes: 1)),
  fiveMinutes(Duration(minutes: 5)),
  tenMinutes(Duration(minutes: 10)),
  fifteenMinutes(Duration(minutes: 15)),
  never(null);

  new(this.after);

  /// Null for [never].
  final Duration? after;
}

/// The Shoot tab's two modes (mock `b-remote`, `b-shoot`).
enum ShootMode {
  /// Shutter, self-timer and drive over Bluetooth alone.
  remote,

  /// The camera's picture over its Wi-Fi.
  liveView,
}

/// Characters an album name cannot hold. Android keeps the album as a
/// folder under `Pictures`, and MediaStore accepts only what a FAT file
/// name allows there; iOS takes any title, and gets the same names so a
/// name means the same on both.
final albumNameForbidden = RegExp(r'[/\\:*?"<>|\x00-\x1F\x7F]');

/// [name] as an album can be called: without [albumNameForbidden]
/// characters and without spaces or dots at either end. Android hides a
/// folder whose name starts with a dot from gallery apps, and a FAT name
/// cannot end in one. Empty when nothing of [name] is left.
String cleanAlbumName(String name) => name
    .replaceAll(albumNameForbidden, '')
    .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');

/// User settings, persisted as `settings.json` in the app data directory.
final class SettingsController extends ChangeNotifier {
  new _(this._file);

  static Future<SettingsController> load(Directory dataDir) async {
    final c = SettingsController._(
      JsonFile(File('${dataDir.path}/settings.json')),
    );
    final json = await c._file.read();
    if (json != null) {
      c._theme = AppTheme.values.asNameMap()[json[_themeKey]] ?? c._theme;
      c._autoDisconnect =
          AutoDisconnect.values.asNameMap()[json['autoDisconnect']] ??
          c._autoDisconnect;
      c._shootMode =
          ShootMode.values.asNameMap()[json['shootMode']] ?? c._shootMode;
      final connectWhenNearby = json['connectWhenNearby'];
      if (connectWhenNearby is bool) c._connectWhenNearby = connectWhenNearby;
      final debugLogging = json['debugLogging'];
      c
        .._debugLogging = debugLogging is bool ? debugLogging : null
        .._albumName = _usableAlbumName(json[_albumNameKey])
        .._saveFolder = _savedFolder(json[_saveFolderKey])
        // A language GR Photo is no longer translated into follows the phone.
        .._language = AppLocalizations.supportedLocales
            .where((locale) => locale.toLanguageTag() == json[_languageKey])
            .firstOrNull;
    }
    return c;
  }

  final JsonFile _file;

  /// Named from when the choices were Flutter's `ThemeMode`; its values are
  /// the [AppTheme] names, so a choice saved then still loads.
  static const _themeKey = 'themeMode';

  /// Holds the language's BCP 47 tag (`de`, `zh-Hant`).
  static const _languageKey = 'language';
  static const _albumNameKey = 'albumName';
  static const _saveFolderKey = 'saveFolder';

  AppTheme _theme = AppTheme.system;
  AutoDisconnect _autoDisconnect = AutoDisconnect.fiveMinutes;
  bool _connectWhenNearby = true;
  ShootMode _shootMode = ShootMode.remote;
  bool? _debugLogging;
  Locale? _language;
  String? _albumName;
  SaveFolder? _saveFolder;

  AppTheme get theme => _theme;

  /// Leave the camera's Wi-Fi after this long without use.
  AutoDisconnect get autoDisconnect => _autoDisconnect;

  /// Connect to the camera used last when the app opens and the Cameras
  /// screen sees it nearby (`CamerasScreen.autoConnect`). Off, the user
  /// connects it: from the camera card, its sheet or its pages.
  bool get connectWhenNearby => _connectWhenNearby;

  /// Shoot opens in the mode used last; the first time in Remote, which
  /// needs no Wi-Fi.
  ShootMode get shootMode => _shootMode;

  /// Whether the app keeps debug logs (Settings, "Enable debug logging");
  /// null until the user chooses, so the build's default (on in dev, off in
  /// prod) applies.
  bool? get debugLogging => _debugLogging;

  /// The language the user chose in Settings, one of
  /// [AppLocalizations.supportedLocales]; null follows the phone's
  /// languages.
  Locale? get language => _language;

  /// The photo library album downloads are saved to, when the user named
  /// one in Settings; null saves to the build's own album
  /// (`DownloadEngine.albumFor`).
  String? get albumName => _albumName;

  /// The folder downloads are saved to, when the user picked one in
  /// Settings (`MediaSaver.pickFolder`); null saves to the photo library.
  SaveFolder? get saveFolder => _saveFolder;

  set theme(AppTheme v) => _update(() => _theme = v);
  set autoDisconnect(AutoDisconnect v) => _update(() => _autoDisconnect = v);
  set connectWhenNearby(bool v) => _update(() => _connectWhenNearby = v);
  set shootMode(ShootMode v) => _update(() => _shootMode = v);
  set debugLogging(bool? v) => _update(() => _debugLogging = v);
  set language(Locale? v) => _update(() => _language = v);
  set albumName(String? v) => _update(() => _albumName = _usableAlbumName(v));
  set saveFolder(SaveFolder? v) => _update(() => _saveFolder = v);

  /// [name] cleaned ([cleanAlbumName]); null when it is no string or
  /// nothing of it is left.
  static String? _usableAlbumName(Object? name) {
    if (name is! String) return null;
    final cleaned = cleanAlbumName(name);
    return cleaned.isEmpty ? null : cleaned;
  }

  /// The folder saved as [json]; null when it is not one.
  static SaveFolder? _savedFolder(Object? json) => switch (json) {
    {'id': final String id, 'name': final String name} => SaveFolder(
      id: id,
      name: name,
    ),
    _ => null,
  };

  /// Applies [change] at once and saves every setting; a failed write goes
  /// to the debug log, and the next change writes every setting again.
  void _update(void Function() change) {
    change();
    notifyListeners();
    final snapshot = {
      _themeKey: _theme.name,
      'autoDisconnect': _autoDisconnect.name,
      'connectWhenNearby': _connectWhenNearby,
      'shootMode': _shootMode.name,
      'debugLogging': ?_debugLogging,
      _languageKey: ?_language?.toLanguageTag(),
      _albumNameKey: ?_albumName,
      if (_saveFolder case SaveFolder(:final id, :final name))
        _saveFolderKey: {'id': id, 'name': name},
    };
    unawaited(_file.save(() => snapshot));
  }

  /// Completes when every change so far is on disk; fails when the latest
  /// write did.
  Future<void> flush() => _file.flush();
}
