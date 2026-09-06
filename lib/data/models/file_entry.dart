import '../../core/utils/json.dart';

/// A single file or directory entry, mirroring the server's `FileEntry`.
///
/// `path` is a POSIX path relative to the caller's scope root (starts at "/"),
/// using "/" separators.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.mtimeMs,
    this.mime,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int mtimeMs;
  final String? mime;

  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(mtimeMs);

  bool get isImage => (mime ?? '').startsWith('image/');
  bool get isVideo => (mime ?? '').startsWith('video/');
  bool get isAudio => (mime ?? '').startsWith('audio/');

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        name: asString(json['name']),
        path: asString(json['path']),
        isDir: asBool(json['isDir']),
        size: asInt(json['size']),
        mtimeMs: asDouble(json['mtimeMs']).round(),
        mime: asStringOrNull(json['mime']),
      );
}

/// A search hit: a [FileEntry] annotated with the drive it lives on.
class SearchHit extends FileEntry {
  const SearchHit({
    required this.drive,
    required super.name,
    required super.path,
    required super.isDir,
    required super.size,
    required super.mtimeMs,
    super.mime,
  });

  final String drive;

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        drive: asString(json['drive']),
        name: asString(json['name']),
        path: asString(json['path']),
        isDir: asBool(json['isDir']),
        size: asInt(json['size']),
        mtimeMs: asDouble(json['mtimeMs']).round(),
        mime: asStringOrNull(json['mime']),
      );
}
