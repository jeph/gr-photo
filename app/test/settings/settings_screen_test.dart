import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grphoto/src/data/settings.dart';
import 'package:grphoto/src/settings/settings_screen.dart';
import 'package:grphoto/src/theme/tokens.dart';
import 'package:grphoto/src/widgets/gr_dialog.dart';

import '../support/test_app.dart';

void main() {
  for (final colors in [GrColors.light, GrColors.dark]) {
    testWidgets('settings change and persist on a phone screen '
        '(${colors.brightness.name})', (tester) async {
      tester.view
        ..physicalSize = const Size(1170, 2532)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final app = (await tester.runAsync(createTestApp))!;
      final settings = app.models.settings;
      await app.pumpWithin(tester, const SettingsScreen(), colors: colors);

      await tester.tap(find.byKey(const ValueKey('theme:dark')));
      await tester.pump();
      expect(settings.theme, AppTheme.dark);
      await tester.tap(find.byKey(const ValueKey('theme:cyanotype')));
      await tester.pump();
      expect(settings.theme, AppTheme.cyanotype);

      expect(settings.autoDisconnect, AutoDisconnect.fiveMinutes);
      expect(find.text('5 min'), findsOneWidget);
      await tester.tap(find.byKey(const Key('setting-auto-disconnect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-disconnect:never')));
      await tester.pumpAndSettle();
      expect(settings.autoDisconnect, AutoDisconnect.never);
      expect(find.text('Never'), findsOneWidget);

      expect(settings.connectWhenNearby, isTrue);
      await tester.tap(find.byKey(const Key('setting-connect-nearby-switch')));
      await tester.pump();
      expect(settings.connectWhenNearby, isFalse);

      await tester.scrollUntilVisible(find.text('Licenses'), 200);
      expect(find.text('Licenses'), findsOneWidget);

      final notAffiliated = find.byKey(const Key('setting-not-affiliated'));
      await tester.scrollUntilVisible(notAffiliated, 200);
      expect(
        tester.widget<Text>(notAffiliated).data,
        contains('not affiliated with or endorsed by Ricoh'),
      );

      // The version the platform reports (`AppServices.appVersion`).
      final version = find.byKey(const Key('setting-version'));
      await tester.scrollUntilVisible(version, 200);
      expect(tester.widget<Text>(version).data, 'Version 1.2.3');

      // The writes started in fake time, so they finish by pumping, not
      // inside runAsync.
      var flushed = false;
      unawaited(settings.flush().whenComplete(() => flushed = true));
      await pumpUntil(tester, () => flushed, reason: 'settings write');
      final reloaded = (await tester.runAsync(
        () => SettingsController.load(app.models.services.dataDir),
      ))!;
      expect(reloaded.theme, AppTheme.cyanotype);
      expect(reloaded.autoDisconnect, AutoDisconnect.never);
      expect(reloaded.connectWhenNearby, isFalse);

      await app.dispose();
    });
  }

  testWidgets('the album downloads are saved to is that of the build until '
      'the user names another', (tester) async {
    final app = (await tester.runAsync(createTestApp))!;
    final models = app.models;
    await app.pumpWithin(tester, const SettingsScreen());
    final row = find.byKey(const Key('setting-album'));
    await tester.scrollUntilVisible(row, 200);
    // `flutter test` is unflavored, which saves to the dev album.
    expect(models.downloads.album(), 'GR Photo Dev');
    expect(
      find.descendant(of: row, matching: find.text('GR Photo Dev')),
      findsOneWidget,
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('album-name-field'));
    final save = find.byKey(const Key('album-name-save'));
    // A name with nothing a folder can be called cannot be saved.
    await tester.enterText(field, ' . ');
    await tester.pump();
    expect(tester.widget<GrDialogAction>(save).onPressed, isNull);
    // What a folder name cannot hold is not typed.
    await tester.enterText(field, ' Street/Tokyo ');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(models.settings.albumName, 'StreetTokyo');
    expect(models.downloads.album(), 'StreetTokyo');
    expect(
      find.descendant(of: row, matching: find.text('StreetTokyo')),
      findsOneWidget,
    );

    var flushed = false;
    unawaited(models.settings.flush().whenComplete(() => flushed = true));
    await pumpUntil(tester, () => flushed, reason: 'settings write');
    final reloaded = (await tester.runAsync(
      () => SettingsController.load(models.services.dataDir),
    ))!;
    expect(reloaded.albumName, 'StreetTokyo');

    await app.dispose();
  });
}
