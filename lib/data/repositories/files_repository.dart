import 'package:dio/dio.dart';

import '../../core/config/constants.dart';
import '../../core/network/api.dart';
import '../models/file_entry.dart';

/// Wraps `/api/files/*` and `/api/search`. Bound to one instance's [Dio].
///
/// JSON mutations use Dio directly; binary endpoints (raw/thumb/download/zip)
/// are exposed as absolute URL builders so image widgets and the download
/// service can stream them with the bearer header.
class FilesRepository {
  FilesRepository(this._dio);
  final Dio _dio;

  String get baseUrl => _dio.options.baseUrl;

  Uri _url(String endpoint, Map<String, dynamic> query) {
    final base = Uri.parse(baseUrl);
    return base.replace(
      path: endpoint,
      queryParameters:
          query.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }

  // ---- Listing / search ----------------------------------------------------
  Future<List<FileEntry>> list(
    String drive,
    String path, {
    bool hidden = false,
  }) =>
      guard(() async {
        final res = await _dio.get(Api.filesList, queryParameters: {
          'drive': drive,
          'path': path,
          if (hidden) 'hidden': '1',
        });
        final data = res.data as Map<String, dynamic>;
        final entries = (data['entries'] as List? ?? const []);
        return entries
            .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  Future<List<SearchHit>> search(
    String query, {
    String? drive,
    bool hidden = false,
  }) =>
      guard(() async {
        final res = await _dio.get(Api.search, queryParameters: {
          'q': query,
          'drive': ?drive,
          if (hidden) 'hidden': '1',
        });
        final data = res.data as Map<String, dynamic>;
        final hits = (data['hits'] as List? ?? const []);
        return hits
            .map((e) => SearchHit.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  // ---- Mutations -----------------------------------------------------------
  Future<void> mkdir(String drive, String path, String name) => guard(() async {
        await _dio.post(Api.filesMkdir,
            data: {'drive': drive, 'path': path, 'name': name});
      });

  Future<void> rename(String drive, String path, String newName) =>
      guard(() async {
        await _dio.post(Api.filesRename,
            data: {'drive': drive, 'path': path, 'newName': newName});
      });

  Future<void> move(String drive, List<String> sources, String dest) =>
      guard(() async {
        await _dio.post(Api.filesMove,
            data: {'drive': drive, 'sources': sources, 'dest': dest});
      });

  Future<void> copy(String drive, List<String> sources, String dest) =>
      guard(() async {
        await _dio.post(Api.filesCopy,
            data: {'drive': drive, 'sources': sources, 'dest': dest});
      });

  Future<void> delete(String drive, List<String> paths) => guard(() async {
        await _dio.post(Api.filesDelete, data: {'drive': drive, 'paths': paths});
      });

  // ---- Binary URL builders -------------------------------------------------
  Uri rawUrl(String drive, String path) =>
      _url(Api.filesRaw, {'drive': drive, 'path': path});

  Uri downloadUrl(String drive, String path) =>
      _url(Api.filesDownload, {'drive': drive, 'path': path});

  Uri thumbUrl(String drive, String path, {int size = 256}) =>
      _url(Api.filesThumb, {'drive': drive, 'path': path, 'size': size});

  Uri zipUrl(String drive, List<String> paths) =>
      _url(Api.filesZip, {'drive': drive, 'paths': paths.join('\n')});

  // ---- Download to a local file -------------------------------------------
  Future<void> downloadToFile(
    String drive,
    String path,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) =>
      guard(() async {
        await _dio.download(
          Api.filesDownload,
          savePath,
          queryParameters: {'drive': drive, 'path': path},
          onReceiveProgress: onProgress,
          cancelToken: cancelToken,
          options: Options(receiveTimeout: Duration.zero),
        );
      });
}
