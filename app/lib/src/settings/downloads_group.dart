import 'dart:async';

import 'package:flutter/services.dart';
import 'package:grphoto/l10n/l10n.dart';
import 'package:grphoto/src/data/settings.dart';
import 'package:grphoto/src/pairing/pairing_widgets.dart';
import 'package:grphoto/src/services.dart';
import 'package:grphoto/src/widgets/gr_dialog.dart';
import 'package:grphoto/src/widgets/gr_text_field.dart';
import 'package:grphoto/src/widgets/group.dart';
import 'package:grphoto/src/widgets/toast.dart';
import 'package:material_ui/material_ui.dart';

/// Settings' Downloads group: where downloads are saved. They go to the
/// phone's photo library, into an album the user can rename, until Save to
/// a folder is switched on, which asks for a folder with the system's
/// folder picker and then shows it in place of the album.
class DownloadsGroup extends StatelessWidget {
  const new({
    required this.settings,
    required this.media,
    required this.album,
    super.key,
  });

  final SettingsController settings;

  /// Asks for the folder and holds the access to it.
  final MediaSaver media;

  /// The album downloads are saved to while no folder is picked: the
  /// user's, or the build's own while they named none.
  final String album;

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _AlbumNameDialog(initial: album),
    );
    if (name == null) return;
    settings.albumName = name;
  }

  /// Asks for the folder downloads are saved to. Leaving the picker without
  /// one changes nothing.
  Future<void> _pickFolder(BuildContext context) async {
    final toasts = Toasts.of(context);
    final l10n = context.l10n;
    final SaveFolder? picked;
    try {
      picked = await media.pickFolder();
    } on MediaSaveException catch (e) {
      debugPrint('Picking a folder for downloads failed: $e');
      toasts.failed(l10n.settingsFolderPickFailed);
      return;
    }
    if (picked == null) return;
    final previous = settings.saveFolder;
    settings.saveFolder = picked;
    // Android knows a folder picked again by the id it had, and that
    // access is the one just taken.
    if (previous != null && previous.id != picked.id) await _forget(previous);
  }

  Future<void> _saveToPhotoLibrary() async {
    final folder = settings.saveFolder;
    if (folder == null) return;
    settings.saveFolder = null;
    await _forget(folder);
  }

  /// Gives up the access to [folder], which downloads no longer go to. A
  /// failure only leaves the platform with access GR Photo does not use.
  Future<void> _forget(SaveFolder folder) async {
    try {
      await media.forgetFolder(folder);
    } on MediaSaveException catch (e) {
      debugPrint('Giving up the access to a downloads folder failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final folder = settings.saveFolder;
    void toggle() => unawaited(
      folder == null ? _pickFolder(context) : _saveToPhotoLibrary(),
    );
    return GroupBox(
      children: [
        GroupRow(
          key: const Key('setting-save-to-folder'),
          icon: Icons.folder_outlined,
          title: l10n.settingsSaveToFolder,
          subtitle: l10n.settingsSaveToFolderSubtitle,
          trailing: Switch(
            key: const Key('setting-save-to-folder-switch'),
            value: folder != null,
            onChanged: (_) => toggle(),
          ),
          onTap: toggle,
        ),
        if (folder == null)
          GroupRow(
            key: const Key('setting-album'),
            icon: Icons.photo_album_outlined,
            title: l10n.settingsAlbum,
            subtitle: l10n.settingsAlbumSubtitle,
            trailing: TrailingFit.value(context, album),
            chevron: true,
            onTap: () => unawaited(_rename(context)),
          )
        else
          GroupRow(
            key: const Key('setting-folder'),
            icon: Icons.folder_open_outlined,
            title: l10n.settingsFolder,
            trailing: TrailingFit.value(context, folder.name),
            chevron: true,
            onTap: () => unawaited(_pickFolder(context)),
          ),
      ],
    );
  }
}

class _AlbumNameDialog extends StatefulWidget {
  const new({required this.initial});

  final String initial;

  @override
  State<_AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<_AlbumNameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final name = cleanAlbumName(_text.text);
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _text,
    builder: (context, _) => GrDialog(
      title: context.l10n.settingsAlbumTitle,
      message: context.l10n.settingsAlbumNote,
      content: GrTextField(
        key: const Key('album-name-field'),
        controller: _text,
        autofocus: true,
        maxLength: 50,
        inputFormatters: [FilteringTextInputFormatter.deny(albumNameForbidden)],
        textCapitalization: TextCapitalization.words,
        onSubmitted: (_) => _save(),
      ),
      actions: [
        GrDialogAction(
          label: context.l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        GrDialogAction.answer(
          key: const Key('album-name-save'),
          label: context.l10n.settingsAlbumSave,
          onPressed: cleanAlbumName(_text.text).isEmpty ? null : _save,
        ),
      ],
    ),
  );
}
