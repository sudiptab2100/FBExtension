import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/local_db.dart';
import '../core/storage/prefs.dart';
import '../core/storage/secure_store.dart';

/// Overridden in `main()` after the async [Prefs] load completes.
final prefsProvider = Provider<Prefs>(
  (ref) => throw UnimplementedError('prefsProvider must be overridden in main()'),
);

/// Secure per-instance token storage.
final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

/// The local SQLite database (opened lazily; used by the backup engine).
final localDbProvider = FutureProvider<LocalDb>((ref) => LocalDb.open());
