import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite storage for the backup ledger (dedupe) and the upload queue.
///
/// Kept intentionally small; the schema is versioned so later phases can extend
/// it without data loss.
class LocalDb {
  LocalDb._(this._db);

  final Database _db;
  Database get raw => _db;

  static Future<LocalDb> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'localdrive.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
    return LocalDb._(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
    // A record of every asset already backed up, so re-runs skip duplicates.
    await db.execute('''
      CREATE TABLE backup_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        instance_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        name TEXT,
        size INTEGER,
        hash TEXT,
        remote_drive TEXT,
        remote_path TEXT,
        backed_up_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_ledger_asset
        ON backup_ledger (instance_id, asset_id)
    ''');

    // Pending / in-flight uploads (resumable via tus URL), survives relaunch.
    await db.execute('''
      CREATE TABLE upload_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        instance_id TEXT NOT NULL,
        drive TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        filename TEXT NOT NULL,
        local_path TEXT NOT NULL,
        size INTEGER,
        status TEXT NOT NULL DEFAULT 'pending',
        tus_url TEXT,
        error TEXT,
        created_at TEXT NOT NULL
      )
    ''');
  }

  // ---- Backup ledger -------------------------------------------------------
  Future<bool> isBackedUp(String instanceId, String assetId) async {
    final rows = await _db.query(
      'backup_ledger',
      columns: const ['id'],
      where: 'instance_id = ? AND asset_id = ?',
      whereArgs: [instanceId, assetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> markBackedUp({
    required String instanceId,
    required String assetId,
    String? name,
    int? size,
    String? hash,
    String? remoteDrive,
    String? remotePath,
  }) async {
    await _db.insert(
      'backup_ledger',
      {
        'instance_id': instanceId,
        'asset_id': assetId,
        'name': name,
        'size': size,
        'hash': hash,
        'remote_drive': remoteDrive,
        'remote_path': remotePath,
        'backed_up_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> backedUpCount(String instanceId) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM backup_ledger WHERE instance_id = ?',
      [instanceId],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  // ---- Upload queue --------------------------------------------------------
  Future<int> enqueueUpload({
    required String instanceId,
    required String drive,
    required String remotePath,
    required String filename,
    required String localPath,
    int? size,
  }) {
    return _db.insert('upload_queue', {
      'instance_id': instanceId,
      'drive': drive,
      'remote_path': remotePath,
      'filename': filename,
      'local_path': localPath,
      'size': size,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> pendingUploads(String instanceId) {
    return _db.query(
      'upload_queue',
      where: "instance_id = ? AND status IN ('pending','error')",
      whereArgs: [instanceId],
      orderBy: 'id ASC',
    );
  }

  Future<void> updateUpload(int id, Map<String, Object?> values) {
    return _db.update('upload_queue', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearCompletedUploads(String instanceId) {
    return _db.delete(
      'upload_queue',
      where: "instance_id = ? AND status = 'done'",
      whereArgs: [instanceId],
    );
  }
}
