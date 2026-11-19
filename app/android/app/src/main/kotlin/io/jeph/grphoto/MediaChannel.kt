package io.jeph.grphoto

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * `io.jeph.grphoto/media`: copies downloaded camera files to one of two
 * destinations.
 *
 * The photo library: MediaStore, one entry per file, under
 * `Pictures/<album>`. Gallery apps show a folder as an album under the
 * folder's name, so movies go there too rather than to `Movies/<album>`,
 * which would be a second album of the same name. Apps may insert their
 * own media on Android 10+ without any storage permission.
 *
 * A folder the user picked (`pickFolder`): plain files written through the
 * Storage Access Framework, which is the only way to write outside the
 * app's own directories and the media collections. The folder's id is its
 * tree URI, and the grant to it is persisted so that it survives restarts
 * until `forgetFolder` or until the user revokes it in Android's settings.
 */
class MediaChannel(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private companion object {
        const val PICK_FOLDER_REQUEST = 2
        const val FOLDER_GRANT =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }

    /** A provider's refusal that means the folder itself is out of reach, not this one file. */
    private class FolderUnavailableException(message: String) : IOException(message)

    // From the application, so that a save still running on `io` does not
    // hold on to a destroyed activity.
    private val resolver: ContentResolver = activity.applicationContext.contentResolver
    private val channel = MethodChannel(messenger, "io.jeph.grphoto/media")
    private val main = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor()

    /** The reply owed for the folder picker that is open, if one is. Main thread only. */
    private var pick: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        // The Dart side that asked is gone; the picker's answer has nowhere to go.
        pick = null
        io.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "forgetFolder" -> forgetFolder(call, result)
            "saveShot" -> saveShot(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * The folder picker's answer, forwarded by the activity. Returns whether
     * the result was this channel's.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FOLDER_REQUEST) return false
        val result = pick ?: return true
        pick = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        try {
            // Without this the grant ends when the device restarts.
            resolver.takePersistableUriPermission(tree, FOLDER_GRANT)
        } catch (e: SecurityException) {
            result.error("failed", "Android did not grant lasting access to the folder: ${e.message}", null)
            return true
        }
        result.success(mapOf("id" to tree.toString(), "name" to folderName(tree)))
        return true
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pick != null) {
            result.error("failed", "a folder is being picked already", null)
            return
        }
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_FOLDER_REQUEST)
        } catch (e: ActivityNotFoundException) {
            result.error("failed", "this device has no folder picker: ${e.message}", null)
            return
        }
        pick = result
    }

    private fun forgetFolder(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id == null) {
            result.error("failed", "forgetFolder needs an id", null)
            return
        }
        try {
            resolver.releasePersistableUriPermission(Uri.parse(id), FOLDER_GRANT)
        } catch (ignored: SecurityException) {
            // Not held any more, which is what was asked for.
        }
        result.success(null)
    }

    private fun saveShot(call: MethodCall, result: MethodChannel.Result) {
        val album = call.argument<String>("album")
        val folder = call.argument<String>("folder")
        val files = call.argument<List<Map<String, Any?>>>("files")?.map(::fileArgs)
        if (files == null || files.isEmpty() || files.any { it == null }) {
            malformedShot(result)
            return
        }
        val shot = files.filterNotNull()
        when {
            album != null && folder == null -> onIo(result) { libraryError(album, shot) }
            folder != null && album == null -> onIo(result) { folderError(Uri.parse(folder), shot) }
            else -> malformedShot(result)
        }
    }

    private fun malformedShot(result: MethodChannel.Result) {
        result.error(
            "failed",
            "saveShot needs either an album or a folder, and files with path, name, kind and mimeType",
            null,
        )
    }

    /** Runs a save off the main thread and replies on it with the error the save returns, if any. */
    private fun onIo(result: MethodChannel.Result, save: () -> Pair<String, String>?) {
        io.execute {
            val error = save()
            main.post {
                if (error == null) result.success(null) else result.error(error.first, error.second, null)
            }
        }
    }

    private fun libraryError(album: String, files: List<FileArgs>): Pair<String, String>? {
        return try {
            saveToLibrary(album, files)
            null
        } catch (e: SecurityException) {
            "permissionDenied" to "Android refused access to the photo library: ${e.message}"
        } catch (e: Exception) {
            "failed" to "saving to the photo library failed: ${e.message}"
        }
    }

    private fun folderError(tree: Uri, files: List<FileArgs>): Pair<String, String>? {
        return try {
            saveToFolder(tree, files)
            null
        } catch (e: FolderUnavailableException) {
            "folderUnavailable" to "the folder cannot be reached: ${e.message}"
        } catch (e: Exception) {
            "failed" to "saving to the folder failed: ${e.message}"
        }
    }

    private data class FileArgs(val path: String, val name: String, val kind: String, val mimeType: String)

    private fun fileArgs(map: Map<String, Any?>): FileArgs? {
        val path = map["path"] as? String ?: return null
        val name = map["name"] as? String ?: return null
        val kind = map["kind"] as? String ?: return null
        val mimeType = map["mimeType"] as? String ?: return null
        return FileArgs(path, name, kind, mimeType)
    }

    /** All files of the shot land, or none: entries already written are removed on failure. */
    private fun saveToLibrary(album: String, files: List<FileArgs>) {
        val inserted = mutableListOf<Uri>()
        try {
            for (file in files) inserted += save(album, file)
        } catch (e: Exception) {
            for (uri in inserted) {
                try {
                    resolver.delete(uri, null, null)
                } catch (ignored: Exception) {
                    // The original failure is what the caller needs to see.
                }
            }
            throw e
        }
    }

    private fun save(album: String, file: FileArgs): Uri {
        val video = file.kind == "movie"
        val collection = if (video) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val albumPath = "${Environment.DIRECTORY_PICTURES}/$album"
        val source = File(file.path)
        if (!source.isFile) throw IOException("${file.name} is missing")

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(MediaStore.MediaColumns.MIME_TYPE, file.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, albumPath)
            // Hidden from other apps until the copy is complete.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore refused ${file.name}")
        try {
            val out = resolver.openOutputStream(uri) ?: throw IOException("cannot write ${file.name}")
            out.use { sink -> source.inputStream().use { it.copyTo(sink) } }
            val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, publish, null, null)
        } catch (e: Exception) {
            try {
                resolver.delete(uri, null, null)
            } catch (ignored: Exception) {
                // The copy failure is what the caller needs to see.
            }
            throw e
        }
        return uri
    }

    /**
     * All files of the shot land, or none: files already written are removed
     * on failure. The provider picks another name when one is taken, so
     * nothing in the folder is overwritten.
     */
    private fun saveToFolder(tree: Uri, files: List<FileArgs>) {
        if (!folderAvailable(tree)) throw FolderUnavailableException("no access to it, or it is gone")
        val created = mutableListOf<Uri>()
        try {
            for (file in files) write(tree, file, created)
        } catch (e: Exception) {
            for (document in created) deleteQuietly(document)
            throw e
        }
    }

    /**
     * Whether the grant is still held and the folder still exists. A grant
     * outlives its folder (deleted, or on storage that was taken out), so
     * the folder is asked for as well.
     */
    private fun folderAvailable(tree: Uri): Boolean {
        if (resolver.persistedUriPermissions.none { it.uri == tree && it.isWritePermission }) return false
        return try {
            val folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            resolver.query(folder, columns, null, null, null)?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Writes one file, adding its document to [created] as soon as it
     * exists, so that the caller removes it whatever fails after that.
     */
    private fun write(tree: Uri, file: FileArgs, created: MutableList<Uri>) {
        val source = File(file.path)
        if (!source.isFile) throw IOException("${file.name} is missing")
        val folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        // Opened before anything is created, and outside `inFolder`: failing
        // to read the source says nothing about the folder.
        source.inputStream().use { input ->
            val document = inFolder { DocumentsContract.createDocument(resolver, folder, file.mimeType, file.name) }
            if (document == null) {
                // Android reports most provider failures only as "nothing
                // created", a revoked grant among them.
                if (!folderAvailable(tree)) throw FolderUnavailableException("no access to it, or it is gone")
                throw IOException("the folder refused ${file.name}")
            }
            created += document
            val out = inFolder { resolver.openOutputStream(document) }
                ?: throw IOException("cannot write ${file.name}")
            out.use { input.copyTo(it) }
        }
    }

    /** Runs a call into the folder's provider, whose refusals mean the folder is out of reach. */
    private inline fun <T> inFolder(call: () -> T): T {
        return try {
            call()
        } catch (e: SecurityException) {
            throw FolderUnavailableException("Android refused access: ${e.message}")
        } catch (e: FileNotFoundException) {
            throw FolderUnavailableException("not found: ${e.message}")
        }
    }

    private fun deleteQuietly(document: Uri) {
        try {
            DocumentsContract.deleteDocument(resolver, document)
        } catch (ignored: Exception) {
            // The original failure is what the caller needs to see.
        }
    }

    /** The folder's name as the user knows it, for showing where shots go. */
    private fun folderName(tree: Uri): String {
        val id = DocumentsContract.getTreeDocumentId(tree)
        val named = try {
            val folder = DocumentsContract.buildDocumentUriUsingTree(tree, id)
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            resolver.query(folder, columns, null, null, null)?.use {
                if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
        if (!named.isNullOrEmpty()) return named
        // Ids of local storage read `<volume>:<path>`.
        return id.substringAfterLast('/').substringAfterLast(':').ifEmpty { id }
    }
}
