import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/storage/prefs.dart';
import '../data/models/ld_instance.dart';
import '../data/services/backup_session_actions.dart';
import 'core_providers.dart';

/// The set of known servers plus which one is active.
class ConnectionState {
  const ConnectionState({this.instances = const [], this.activeId});

  final List<LdInstance> instances;
  final String? activeId;

  LdInstance? get active {
    if (activeId == null) return null;
    for (final i in instances) {
      if (i.id == activeId) return i;
    }
    return null;
  }

  ConnectionState copyWith({
    List<LdInstance>? instances,
    String? activeId,
    bool clearActive = false,
  }) => ConnectionState(
    instances: instances ?? this.instances,
    activeId: clearActive ? null : (activeId ?? this.activeId),
  );
}

/// Owns the saved-server list and the active selection, persisted to [Prefs].
class ConnectionController extends Notifier<ConnectionState> {
  @override
  ConnectionState build() {
    final prefs = ref.watch(prefsProvider);
    return ConnectionState(
      instances: prefs.readInstances(),
      activeId: prefs.activeInstanceId,
    );
  }

  Prefs get _prefs => ref.read(prefsProvider);

  Future<void> _persist() async {
    await _prefs.writeInstances(state.instances);
    await _prefs.setActiveInstanceId(state.activeId);
  }

  /// Add a new instance or merge into an existing one (matched by id), then
  /// optionally make it active. Returns the stored instance.
  Future<LdInstance> addOrUpdate(
    LdInstance instance, {
    bool activate = false,
  }) async {
    final list = [...state.instances];
    final idx = list.indexWhere((i) => i.id == instance.id);
    LdInstance stored;
    if (idx >= 0) {
      stored = list[idx].copyWith(
        name: instance.name,
        hostname: instance.hostname,
        addresses: instance.addresses.isNotEmpty ? instance.addresses : null,
        httpsPort: instance.httpsPort,
        source: instance.source,
        trustSelfSigned: instance.trustSelfSigned || list[idx].trustSelfSigned,
      );
      list[idx] = stored;
    } else {
      stored = instance;
      list.add(instance);
    }
    if (activate && stored.id != state.activeId) {
      await _pauseActiveBackup();
    }
    state = state.copyWith(
      instances: list,
      activeId: activate ? stored.id : state.activeId,
    );
    await _persist();
    return stored;
  }

  Future<void> setActive(String? id) async {
    if (id == state.activeId) return;
    await _pauseActiveBackup();
    state = state.copyWith(activeId: id, clearActive: id == null);
    await _prefs.setActiveInstanceId(id);
  }

  Future<void> remove(String id) async {
    for (final account in _prefs.accounts(id)) {
      await stopAccountBackup(
        prefs: _prefs,
        instanceId: id,
        userId: account.userId,
        discard: true,
        blockNewWork: true,
        invalidateSession:
            state.activeId == id &&
            _prefs.activeAccount(id) == account.username,
      );
    }
    final list = state.instances.where((i) => i.id != id).toList();
    state = ConnectionState(
      instances: list,
      activeId: state.activeId == id ? null : state.activeId,
    );
    await _persist();
    // Purge every stored token (legacy + per-account) and the accounts registry.
    final usernames = _prefs.accounts(id).map((a) => a.username).toList();
    await ref.read(secureStoreProvider).deleteInstanceTokens(id, usernames);
    await _prefs.clearAccounts(id);
  }

  Future<void> markConnected(String id) async {
    final idx = state.instances.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final list = [...state.instances];
    list[idx] = list[idx].copyWith(
      lastConnectedAt: DateTime.now().toIso8601String(),
    );
    state = state.copyWith(instances: list);
    await _persist();
  }

  Future<void> _pauseActiveBackup() async {
    final id = state.activeId;
    if (id == null) {
      await _prefs.invalidateBackupSession();
      return;
    }
    final username = _prefs.activeAccount(id);
    final account = _prefs
        .accounts(id)
        .where((value) => value.username == username)
        .firstOrNull;
    await stopAccountBackup(
      prefs: _prefs,
      instanceId: id,
      userId: account?.userId,
    );
  }
}

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

/// The currently active server, or null when none is selected.
final activeInstanceProvider = Provider<LdInstance?>(
  (ref) => ref.watch(connectionControllerProvider).active,
);
