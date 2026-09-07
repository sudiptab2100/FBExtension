import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/backup_job.dart';

class StagedBackupSource {
  const StagedBackupSource({
    required this.path,
    required this.directory,
    required this.size,
    required this.sha256,
  });

  final String path;
  final String directory;
  final int size;
  final String sha256;
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

/// All files here belong to a UUID job, never to the gallery or file browser.
class BackupStaging {
  BackupStaging({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const targetBytes = 512 * 1024 * 1024;
  static const maxPreparedItems = 20;
  final Future<Directory> Function() _supportDirectory;
  Directory? _root;

  Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;
    final support = await _supportDirectory();
    final directory = Directory(p.join(support.path, 'LocalDriveBackups'));
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError(
        'The backup staging directory is not an owned directory.',
      );
    }
    return _root = Directory(await directory.resolveSymbolicLinks());
  }

  Future<Directory> directoryFor(String jobId) async {
    if (!isBackupId(jobId)) {
      throw StateError('Invalid backup job staging identity.');
    }
    final directory = Directory(p.join((await root()).path, jobId));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StateError('Backup staging must not contain symbolic links.');
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> assertOwned(BackupJob job) async {
    final expected = p.join((await root()).path, job.jobId);
    if (!isBackupId(job.jobId) ||
        job.stageDirectory != expected ||
        job.localPath != p.join(expected, 'source') ||
        (job.suffixPath != null &&
            (!p.isWithin(expected, job.suffixPath!) ||
                p.dirname(job.suffixPath!) != expected))) {
      throw StateError(
        'Refusing to access a file not owned by this backup job.',
      );
    }
    for (final path in [
      expected,
      job.localPath,
      if (job.suffixPath != null) job.suffixPath!,
    ]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Refusing to follow a backup staging symbolic link.');
      }
    }
  }

  Future<StagedBackupSource> copySource({
    required String jobId,
    required File source,
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    final directory = await directoryFor(jobId);
    return _copy(
      source.openRead(),
      File(p.join(directory.path, 'source')),
      checkpoint: checkpoint,
      maximumBytes: maximumBytes,
    );
  }

  /// Finish a streamed vCard written inside this job's directory.
  Future<StagedBackupSource> adoptContacts({
    required String jobId,
    required File source,
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    final directory = await directoryFor(jobId);
    if (p.dirname(source.path) != directory.path ||
        p.basename(source.path) != 'contacts.export') {
      throw StateError('The contacts export is not owned by this job.');
    }
    final result = await _hashFile(source, checkpoint: checkpoint);
    if (maximumBytes != null && result.size > maximumBytes) {
      throw BackupFailure(
        'Waiting for staging space to finish the contacts backup.',
        code: 'staging_budget',
        waiting: true,
      );
    }
    final destination = p.join(directory.path, 'source');
    await source.rename(destination);
    return StagedBackupSource(
      path: destination,
      directory: directory.path,
      size: result.size,
      sha256: result.sha256,
    );
  }

  Future<StagedBackupSource?> recoverSource(
    BackupJob job, {
    required Future<void> Function() checkpoint,
  }) async {
    await assertOwned(job);
    final source = File(job.localPath);
    if (!await source.exists()) return null;
    return _hashFile(source, checkpoint: checkpoint);
  }

  Future<StagedBackupSource> _hashFile(
    File file, {
    required Future<void> Function() checkpoint,
  }) async {
    final digest = _DigestSink();
    final sink = sha256.startChunkedConversion(digest);
    var size = 0;
    var checked = 0;
    try {
      await for (final chunk in file.openRead()) {
        sink.add(chunk);
        size += chunk.length;
        checked += chunk.length;
        if (checked >= 8 * 1024 * 1024) {
          await checkpoint();
          checked = 0;
        }
      }
    } finally {
      sink.close();
    }
    await checkpoint();
    return StagedBackupSource(
      path: file.path,
      directory: p.dirname(file.path),
      size: size,
      sha256: digest.digest.toString(),
    );
  }

  Future<int> usedBytes({BackupJob? job}) async {
    if (job != null) await assertOwned(job);
    final directory = job == null
        ? await root()
        : Directory(job.stageDirectory!);
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<StagedBackupSource> _copy(
    Stream<List<int>> input,
    File destination, {
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    final partial = File('${destination.path}.part');
    if (await FileSystemEntity.type(partial.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Refusing a symbolic link in backup staging.');
    }
    final output = await partial.open(mode: FileMode.write);
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var size = 0;
    var sinceCheckpoint = 0;
    try {
      await checkpoint();
      await for (final chunk in input) {
        size += chunk.length;
        sinceCheckpoint += chunk.length;
        if (maximumBytes != null && size > maximumBytes) {
          throw BackupFailure(
            'Waiting for staged uploads to finish before preparing more files.',
            code: 'staging_budget',
            waiting: true,
          );
        }
        hash.add(chunk);
        await output.writeFrom(chunk);
        if (sinceCheckpoint >= 8 * 1024 * 1024) {
          await checkpoint();
          sinceCheckpoint = 0;
        }
      }
      await checkpoint();
      await output.flush();
    } catch (_) {
      await output.close();
      hash.close();
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    await output.close();
    hash.close();
    await partial.rename(destination.path);
    return StagedBackupSource(
      path: destination.path,
      directory: p.dirname(destination.path),
      size: size,
      sha256: digest.digest.toString(),
    );
  }

  Future<void> verifySource(
    BackupJob job, {
    required Future<void> Function() checkpoint,
  }) async {
    await assertOwned(job);
    final file = File(job.localPath);
    if (!await file.exists() || await file.length() != job.size) {
      throw BackupFailure(
        'The staged backup source is missing or incomplete.',
        code: 'source_missing',
      );
    }
    final digest = _DigestSink();
    final sink = sha256.startChunkedConversion(digest);
    var checked = 0;
    try {
      await for (final chunk in file.openRead()) {
        sink.add(chunk);
        checked += chunk.length;
        if (checked >= 8 * 1024 * 1024) {
          await checkpoint();
          checked = 0;
        }
      }
    } finally {
      sink.close();
    }
    await checkpoint();
    if (digest.digest.toString() != job.sha256) {
      throw BackupFailure(
        'The staged backup content changed. Cancel this job before retrying.',
        code: 'source_changed',
        retryable: false,
      );
    }
  }

  Future<String> suffix(
    BackupJob job,
    int offset, {
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    await assertOwned(job);
    if (offset < 0 || offset > job.size!) {
      throw StateError('Invalid backup suffix offset.');
    }
    if (offset == 0) return job.localPath;
    final path = p.join(job.stageDirectory!, 'suffix-$offset');
    if (job.suffixPath == path &&
        await File(path).exists() &&
        await File(path).length() == job.size! - offset) {
      return path;
    }
    await checkpoint();
    await _copy(
      File(job.localPath).openRead(offset),
      File(path),
      checkpoint: checkpoint,
      maximumBytes: maximumBytes,
    );
    return path;
  }

  Future<void> removeSuffix(BackupJob job) async {
    if (job.suffixPath == null) return;
    await assertOwned(job);
    final file = File(job.suffixPath!);
    if (await file.exists()) await file.delete();
  }

  Future<void> removeUnusedSuffixes(BackupJob job) async {
    await assertOwned(job);
    final directory = Directory(job.stageDirectory!);
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (p.basename(entity.path).startsWith('suffix-') &&
          entity is! Directory) {
        await entity.delete();
      }
    }
  }

  Future<void> cleanup(BackupJob job) async {
    if (job.stageDirectory == null) return;
    await assertOwned(job);
    final directory = Directory(job.stageDirectory!);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
