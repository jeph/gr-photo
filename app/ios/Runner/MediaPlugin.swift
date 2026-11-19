import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers

/// `io.jeph.grphoto/media`: saves one shot where the Dart side says, in the
/// Photos library (`album`) or in a folder the user picked (`folder`).
///
/// With `album` the shot becomes one Photos asset in the album of that
/// title, which is created when the library has none. A RAW+JPEG pair
/// becomes a JPEG photo with the DNG as its RAW alternate, a lone DNG a RAW
/// photo, a MOV a video. Photos lets only an app with full access create or
/// look up albums, so full access is what is asked for. The plugin uses it
/// to find the album by its title and reads nothing else. With limited
/// access or "Add Photos Only" the shot is still saved, outside the album.
///
/// With `folder` the shot's files are copied into a folder of the Files
/// app that `pickFolder` asked the user for, under their own names. The
/// access to that folder is kept as a bookmark in GR Photo's own storage
/// until `forgetFolder`, and Photos is not asked for anything.
final class MediaPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private struct ShotFile {
    let url: URL
    let name: String
    let kind: String
  }

  /// The answer owed to the `pickFolder` whose picker is open.
  private var pendingPick: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "io.jeph.grphoto/media", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MediaPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "saveShot":
      saveShot(args, result: result)
    case "pickFolder":
      pickFolder(result: result)
    case "forgetFolder":
      guard let id = args?["id"] as? String else {
        result(Self.failed("forgetFolder needs an id"))
        return
      }
      if let bookmark = Self.bookmarkFile(id) {
        try? FileManager.default.removeItem(at: bookmark)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func saveShot(_ args: [String: Any]?, result: @escaping FlutterResult) {
    let files = (args?["files"] as? [[String: Any]])?.compactMap { file -> ShotFile? in
      guard let path = file["path"] as? String,
        let name = file["name"] as? String,
        let kind = file["kind"] as? String
      else { return nil }
      return ShotFile(url: URL(fileURLWithPath: path), name: name, kind: kind)
    }
    let malformed = Self.failed(
      "saveShot needs an album or a folder, and files with path, name and kind")
    guard let files, !files.isEmpty, files.count == (args?["files"] as? [Any])?.count else {
      result(malformed)
      return
    }
    let reply: (FlutterError?) -> Void = { error in
      DispatchQueue.main.async { result(error) }
    }
    switch (args?["album"] as? String, args?["folder"] as? String) {
    case (let album?, nil):
      Self.saveToPhotos(files, album: album, reply: reply)
    case (nil, let folder?):
      DispatchQueue.global(qos: .userInitiated).async {
        reply(Self.save(files, inFolder: folder))
      }
    default:
      result(malformed)
    }
  }

  // MARK: Photos

  private static func saveToPhotos(
    _ files: [ShotFile], album: String, reply: @escaping (FlutterError?) -> Void
  ) {
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      if status == .authorized {
        Self.save(files, album: album, reply: reply)
        return
      }
      // Refusing access to the library leaves "Add Photos Only" in place
      // when the user chose that in Settings.
      let mayAdd =
        status == .limited || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
      guard mayAdd else {
        reply(FlutterError(
          code: "permissionDenied",
          message: "GR Photo may not add to Photos; allow it under Settings › GR Photo › Photos",
          details: nil))
        return
      }
      Self.save(files, album: nil, reply: reply)
    }
  }

  /// Saves the shot and, given an `album`, adds it to the album of that
  /// title in the same change, so the shot never lands without its album.
  private static func save(
    _ files: [ShotFile], album: String?, reply: @escaping (FlutterError?) -> Void
  ) {
    let existingAlbum = album.flatMap(findAlbum(titled:))
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      for (index, file) in files.enumerated() {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = file.name
        options.uniformTypeIdentifier = uniformType(file.kind)
        request.addResource(with: resourceType(file.kind, index: index), fileURL: file.url, options: options)
      }
      guard let album, let asset = request.placeholderForCreatedAsset else { return }
      let albumRequest =
        existingAlbum.flatMap { PHAssetCollectionChangeRequest(for: $0) }
        ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
      albumRequest.addAssets([asset] as NSArray)
    }) { success, error in
      if success {
        reply(nil)
        return
      }
      reply(Self.saveError(error))
    }
  }

  /// The user's album of this title, if the library has one. A renamed or
  /// deleted album is not found, and the next save creates it again.
  private static func findAlbum(titled title: String) -> PHAssetCollection? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title = %@", title)
    options.fetchLimit = 1
    return PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumRegular, options: options
    ).firstObject
  }

  /// The Dart side sends the JPEG before the DNG, so a DNG after the first
  /// file is the RAW half of a pair.
  private static func resourceType(_ kind: String, index: Int) -> PHAssetResourceType {
    switch kind {
    case "movie": return .video
    case "dng" where index > 0: return .alternatePhoto
    default: return .photo
    }
  }

  private static func uniformType(_ kind: String) -> String {
    switch kind {
    case "movie": return "com.apple.quicktime-movie"
    case "dng": return "com.adobe.raw-image"
    default: return "public.jpeg"
    }
  }

  private static func saveError(_ error: Error?) -> FlutterError {
    if let error = error as NSError?, error.domain == PHPhotosErrorDomain,
      error.code == PHPhotosError.Code.accessUserDenied.rawValue
        || error.code == PHPhotosError.Code.accessRestricted.rawValue
    {
      return FlutterError(
        code: "permissionDenied", message: "GR Photo may not add to Photos", details: nil)
    }
    return failed("saving to Photos failed: \(error?.localizedDescription ?? "unknown error")")
  }

  // MARK: Folder

  /// Shows the system's folder picker. The answer is `{id, name}` for the
  /// folder picked, or nil when the picker was left without one.
  private func pickFolder(result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(Self.failed("a folder picker is already open"))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(Self.failed("no window to show the folder picker in"))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    pendingPick = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let folder = urls.first else {
      result(nil)
      return
    }
    // The picker's URL is only good while it is being accessed, and the
    // bookmark made then is what carries the access to later launches.
    guard folder.startAccessingSecurityScopedResource() else {
      result(Self.failed("iOS gave no access to the folder picked"))
      return
    }
    defer { folder.stopAccessingSecurityScopedResource() }
    let id = UUID().uuidString
    do {
      guard let file = Self.bookmarkFile(id) else {
        result(Self.failed("no place to keep the access to the folder"))
        return
      }
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try folder.bookmarkData().write(to: file, options: .atomic)
    } catch {
      result(Self.failed("keeping the access to the folder failed: \(error.localizedDescription)"))
      return
    }
    let name = (try? folder.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
    result(["id": id, "name": name ?? folder.lastPathComponent])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  /// The view controller in front, which is the one that can present.
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var top = scene?.keyWindow?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  /// Where the bookmark of the folder `id` is kept: a file of its own in
  /// Application Support, named by the id, which `pickFolder` makes as a
  /// UUID. Nil for an id that is not one, so an id never names another file.
  private static func bookmarkFile(_ id: String) -> URL? {
    guard UUID(uuidString: id) != nil,
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return support.appendingPathComponent("save-folders", isDirectory: true)
      .appendingPathComponent(id)
  }

  /// Copies the shot's files into the folder `id`: all of them or none.
  private static func save(_ files: [ShotFile], inFolder id: String) -> FlutterError? {
    guard let file = bookmarkFile(id), let bookmark = try? Data(contentsOf: file) else {
      return folderUnavailable("GR Photo holds no access to the folder")
    }
    var stale = false
    guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    else {
      return folderUnavailable("the folder is no longer where it was")
    }
    guard folder.startAccessingSecurityScopedResource() else {
      return folderUnavailable("iOS no longer gives access to the folder")
    }
    defer { folder.stopAccessingSecurityScopedResource() }
    // iOS asks for a new bookmark once the folder has moved or been
    // renamed; the one held keeps working until it is replaced.
    if stale, let fresh = try? folder.bookmarkData() {
      try? fresh.write(to: file, options: .atomic)
    }
    guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
      return folderUnavailable("the folder is gone or its storage is not there")
    }
    // Coordinated, because the folder may belong to a cloud storage app
    // that is reading or changing it at the same time.
    var failure: FlutterError?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      writingItemAt: folder, options: .forMerging, error: &coordinationError
    ) { folder in
      failure = copy(files, into: folder)
    }
    if let coordinationError {
      return failed("the folder could not be written to: \(coordinationError.localizedDescription)")
    }
    return failure
  }

  /// Copies `files` into `folder` under their names, never over a file
  /// that is there: when one of the names is taken, every file of the shot
  /// gets the same ` (1)`, ` (2)`, … before its extension, so a RAW+JPEG
  /// pair keeps one base name. What was copied is removed when a later
  /// file fails.
  private static func copy(_ files: [ShotFile], into folder: URL) -> FlutterError? {
    let manager = FileManager.default
    func destination(_ file: ShotFile, _ number: Int) -> URL {
      guard number > 0 else { return folder.appendingPathComponent(file.name) }
      let name = file.name as NSString
      let numbered = "\(name.deletingPathExtension) (\(number))"
      let type = name.pathExtension
      return folder.appendingPathComponent(type.isEmpty ? numbered : "\(numbered).\(type)")
    }
    var number = 0
    while files.contains(where: { manager.fileExists(atPath: destination($0, number).path) }) {
      number += 1
    }
    var copied: [URL] = []
    do {
      for file in files {
        let target = destination(file, number)
        try manager.copyItem(at: file.url, to: target)
        copied.append(target)
      }
      return nil
    } catch {
      for url in copied { try? manager.removeItem(at: url) }
      return failed("saving to the folder failed: \(error.localizedDescription)")
    }
  }

  private static func folderUnavailable(_ message: String) -> FlutterError {
    FlutterError(code: "folderUnavailable", message: message, details: nil)
  }

  private static func failed(_ message: String) -> FlutterError {
    FlutterError(code: "failed", message: message, details: nil)
  }
}
