# Saving downloads: the photo library or a folder

Where GR Photo puts a downloaded shot on the phone, what each platform lets an app do there, and what was seen when it was tried. It is about the phone, not the camera; nothing here changes the camera protocol.

Status of each statement: **observed** (2026-11-18, GR Photo's `dev` build in demo mode, on an Android 16 emulator with a Google Play system image and on an iOS 27.0 iPhone simulator), **found in code** (Android's or Apple's documentation, or GR Photo's own code), **inferred**, **[design]** (our choice) or **unknown**. Nothing here has been tried on a real phone, with an SD card or with a cloud storage app.

## 1. The two destinations

[design] Settings › Downloads decides where a shot goes at the moment it is saved (`DownloadEngine.destination`, `app/lib/src/downloads/download_engine.dart`):

- **The photo library**, in an album the user can rename. This is what every install does until the user changes it. Android writes one MediaStore entry per file under `Pictures/<album>`; iOS adds one Photos asset per shot (a RAW+JPEG pair is a JPEG with the DNG as its RAW alternate) and puts it in the album of that title.
- **A folder**, once Save to a folder is switched on and a folder picked with the system's folder picker. Shots are then plain files under the camera's file names, and the photo library is not touched. The two are exclusive: a shot is never saved twice.

The folder is a file export on both platforms. GR Photo promises nothing about the phone's photo app showing what is saved there, and Settings says so under the switch.

## 2. Android

Found in Android's documentation ("Access documents and other files from shared storage", read 2026-11-18):

- `ACTION_OPEN_DOCUMENT_TREE` lets the user pick a folder of any documents provider, "including external storage volumes and cloud-based storage", and gives the app access to it without a permission.
- Files written this way are described as stored outside the media store, the index gallery apps read.
- On Android 11 and later the picker refuses the root of internal storage, the root of an SD card and the `Download` directory. A folder inside them can be picked.
- The access lasts across restarts only after `takePersistableUriPermission`.

Observed on the emulator, through `MediaChannel.kt` (`app/android/app/src/main/kotlin/io/jeph/grphoto/`):

- The picker opened at the root of internal storage with "Can't use this folder". A folder under `Documents` could be picked, after Android's own question whether GR Photo may access the files in it.
- `dumpsys activity permissions` listed the grant as a tree URI of `com.android.externalstorage.documents`. It was still held after the app was force-stopped and started again, and saving went on working. Switching Save to a folder off (`releasePersistableUriPermission`) removed it.
- `DocumentsContract.createDocument` kept the names of a JPEG (`image/jpeg`), a DNG (`image/x-adobe-dng`) and a MOV (`video/quicktime`) as sent, without adding an extension.
- A RAW+JPEG pair downloaded a second time became `<name> (1).JPG` and `<name> (1).DNG`: the local storage provider picks the new name, and nothing was overwritten.
- After the folder was deleted from outside the app, the next save failed as `folderUnavailable` (the grant was still listed, but the folder's own document could not be queried), and the Library explained it once.
- Leaving the picker with Back answered "no folder", and the setting stayed as it was.

Unknown:

- Whether a gallery app shows files saved to a picked folder of local storage. MediaStore may index them even though the documentation calls them outside it; not checked.
- A folder on an SD card, and a folder of a cloud storage app: how long a write takes, whether it works while GR Photo is not in front, and what name the provider gives a file whose name is taken. A provider is not required to rename.
- A pair of which only one name is taken would get different names for its two files, because each file is named by the provider on its own. Not seen; it needs a folder that holds one half only.
- [inferred] `DocumentsContract.createDocument` returns null for most provider failures, a revoked grant among them, so `MediaChannel` asks whether the folder is still there before calling a null a plain failure.

## 3. iOS

Found in Apple's documentation ("Providing access to directories"): `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` returns a security-scoped URL to the folder picked, in the Files app's own storage or in another app's file provider. The URL is good only between `startAccessingSecurityScopedResource` and `stopAccessingSecurityScopedResource`, and a bookmark made while it is being accessed carries the access to later launches. No usage description in `Info.plist` is needed, and Photos is not involved.

[design] `MediaPlugin.swift` (`app/ios/Runner/`) keeps each bookmark as a file of its own under `Application Support/save-folders/`, named by a UUID that is the folder's id on the Dart side. It is not kept in `UserDefaults`, which is one of the APIs Apple wants a declared reason for. Files are copied inside a coordinated write on the folder, because a file provider may be working on it at the same time. When a name is taken, every file of the shot gets the same ` (1)`, ` (2)`, … before its extension, so a pair keeps one base name.

Observed on the simulator:

- "On My iPhone" itself could be picked with Open. Its name came back as `File Provider Storage`, from `URLResourceKey.localizedNameKey` and from `FileManager.displayName` alike, so that is what Settings shows for it. A folder inside it has its own name. Unknown: a public way to get "On My iPhone" for the root.
- A JPEG, a RAW+JPEG pair and a MOV were saved as plain files under their names, without iOS asking for Photos access.
- After the app was terminated and started again the bookmark resolved and saving went on working.
- The pair downloaded a second time became `<name> (1).JPG` and `<name> (1).DNG`.
- With the bookmark file removed, the next save failed as `folderUnavailable` and the Library explained it once.
- Picking again made a new bookmark and removed the old one; switching Save to a folder off removed the bookmark.
- Swiping the picker down called `documentPickerWasCancelled`: the setting stayed as it was and the picker opened again on the next tap.

Unknown:

- A folder in iCloud Drive or in another app's file provider, on a real iPhone: whether the bookmark resolves after a restart of the phone, how long a coordinated write waits, and whether it works while GR Photo runs its continued processing task with the app off screen (`protocol/connection-lifecycle.md` §9).
- A stale bookmark (the folder moved or renamed): the code replaces it when iOS reports one, which has not been seen happen.

## 4. When the folder cannot be used

[design] Both platforms report a folder whose access is gone, that was deleted or whose storage is not there as `folderUnavailable` (`MediaSaveFailure`, `app/lib/src/services.dart`). Like a refused Photos permission it fails every waiting download, since each would fail the same way, and the Library says what to do once. GR Photo does not fall back to the photo library: shots would end up in two places without the user knowing. The downloads stay in the queue as failed and are saved by Retry once a folder is picked again or Save to a folder is switched off.
