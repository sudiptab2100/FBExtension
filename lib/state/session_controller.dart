import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../core/network/api_exception.dart';
import '../core/network/dio_client.dart';
import '../data/models/account.dart';
import '../data/models/ld_instance.dart';
import '../data/models/user.dart';
import '../data/repositories/auth_repository.dart';
import '../data/services/backup_errors.dart';
import '../data/services/backup_session_actions.dart';
import 'api_providers.dart';
import 'connection_controller.dart';
import 'core_providers.dart';

enum SessionStatus { loading, unauthenticated, pending, authenticated }

/// Authentication state for the *active* instance.
class SessionState {
  const SessionState({
    this.status = SessionStatus.loading,
    this.user,
    this.token,
    this.viewMode = ViewCookie.admin,
    this.message,
    this.accounts = const [],
  });

  final SessionStatus status;
  final AppUser? user;
  final String? token;

  /// Admin-only view scope: 'admin' (whole share) or 'user' (own space).
  final String viewMode;
  final String? message;

  /// Every account currently signed in on the active server (for the in-app
  /// user switcher). The active one is [user].
  final List<Account> accounts;

  bool get isAuthenticated => status == SessionStatus.authenticated;
  bool get isAdmin => user?.isAdmin ?? false;

  /// The effective scope actually applied by the server for this session.
  String get effectiveViewMode => isAdmin ? viewMode : ViewCookie.user;

  /// True when more than one account is available to switch between.
  bool get hasMultipleAccounts => accounts.length > 1;

  SessionState copyWith({
    SessionStatus? status,
    AppUser? user,
    String? token,
    String? viewMode,
    String? message,
    List<Account>? accounts,
    bool clearMessage = false,
  }) => SessionState(
    status: status ?? this.status,
    user: user ?? this.user,
    token: token ?? this.token,
    viewMode: viewMode ?? this.viewMode,
    message: clearMessage ? null : (message ?? this.message),
    accounts: accounts ?? this.accounts,
  );
}

/// Manages login/register/logout, session restore, and multi-account switching
/// for the active instance. Several users can stay signed in on the same server
/// (a token is kept per username) and be switched without re-entering passwords.
class SessionController extends Notifier<SessionState> {
  bool _checkingSwitchedAccount = false;
  Future<void> _credentialMutations = Future<void>.value();
  int _restoreRevision = 0;

  @override
  SessionState build() {
    final active = ref.watch(activeInstanceProvider);
    if (active == null) {
      return const SessionState(status: SessionStatus.unauthenticated);
    }
    final prefs = ref.read(prefsProvider);
    final vm = prefs.viewMode(active.id);
    final accounts = prefs.accounts(active.id);
    // Restore the active account's token and verify it in the background.
    _bootstrap(active, ++_restoreRevision);
    return SessionState(
      status: SessionStatus.loading,
      viewMode: vm,
      accounts: accounts,
    );
  }

  bool _current(LdInstance instance, int revision) =>
      ref.mounted &&
      revision == _restoreRevision &&
      ref.read(activeInstanceProvider)?.id == instance.id;

  Future<T> _withCredentials<T>(Future<T> Function() action) async {
    final previous = _credentialMutations;
    final release = Completer<void>();
    _credentialMutations = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<T> _withAuth<T>(
    LdInstance instance,
    String? token,
    Future<T> Function(AuthRepository auth) action,
  ) async {
    final dio = buildDio(
      baseUrl: instance.baseUrl,
      trustSelfSigned: instance.trustSelfSigned,
      token: () => token,
    );
    try {
      return await action(AuthRepository(dio));
    } finally {
      dio.close();
    }
  }

  // ---- Session restore -----------------------------------------------------

  Future<void> _bootstrap(LdInstance active, int revision) async {
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    var accounts = prefs.accounts(active.id);

    // One-time migration from the legacy single-token-per-instance layout.
    if (accounts.isEmpty) {
      final legacy = await store.readToken(active.id);
      if (!_current(active, revision)) return;
      if (legacy == null || legacy.isEmpty) {
        state = _unauth(const []);
        return;
      }
      try {
        final user = await _withAuth(active, legacy, (auth) => auth.me());
        if (!_current(active, revision)) return;
        await _withCredentials(() async {
          if (!_current(active, revision)) return;
          await store.writeUserToken(active.id, user.username, legacy);
          await store.deleteToken(active.id);
        });
        if (!_current(active, revision)) return;
        accounts = [Account.fromUser(user)];
        await prefs.writeAccounts(active.id, accounts);
        await prefs.setActiveAccount(active.id, user.username);
        if (!_current(active, revision)) return;
        state = _authed(user, legacy, accounts);
        await _configureBackgroundAccess(active, user);
      } on ApiException catch (e) {
        if (!_current(active, revision)) return;
        if (e.isAuth) await store.deleteToken(active.id);
        state = _unauth(const [], message: e.isAuth ? null : e.message);
      }
      return;
    }

    // Multi-account: resolve the active account's token.
    var username = prefs.activeAccount(active.id);
    if (username == null || !accounts.any((a) => a.username == username)) {
      username = accounts.first.username;
      await prefs.setActiveAccount(active.id, username);
    }
    final selectedUsername = username;
    final account = accounts.where((item) => item.username == username).first;
    if (account.userId != null &&
        prefs.backupAccountBlocked(active.id, account.userId!)) {
      if (_current(active, revision)) {
        state = _unauth(
          accounts,
          message: 'Please sign in again as $username.',
        );
      }
      return;
    }
    final token = await store.readUserToken(active.id, username);
    if (!_current(active, revision)) return;
    if (token == null || token.isEmpty) {
      // A listed account without a stored token — require re-login but keep it.
      state = _unauth(accounts);
      return;
    }
    try {
      final user = await _withAuth(active, token, (auth) => auth.me());
      if (!_current(active, revision)) return;
      accounts = _upsert(accounts, Account.fromUser(user));
      await prefs.writeAccounts(active.id, accounts);
      if (!_current(active, revision)) return;
      state = _authed(user, token, accounts);
      await _configureBackgroundAccess(active, user);
    } on ApiException catch (e) {
      if (!_current(active, revision)) return;
      if (e.isAuth) {
        await _withCredentials(() async {
          if (await store.readUserToken(active.id, selectedUsername) == token) {
            await store.deleteUserToken(active.id, selectedUsername);
          }
        });
        if (!_current(active, revision)) return;
        state = _unauth(accounts);
      } else {
        state = _unauth(accounts, message: e.message);
      }
    }
  }

  // ---- Sign in / register --------------------------------------------------

  /// Sign in. Throws [ApiException] on failure (including `pending` accounts).
  /// The account is added to this server's registry and made active without
  /// dropping any other signed-in accounts.
  Future<void> login(String username, String password) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) throw ApiException('No server selected');
    final res = await _withAuth(
      active,
      null,
      (auth) => auth.login(username, password),
    );
    if (res.token == null || res.user == null) {
      throw ApiException('Login failed');
    }
    await _activate(active, res.user!, res.token!);
  }

  /// Register. Returns the [AuthResult]; when auto-approved the user is signed
  /// in immediately, otherwise the account is pending admin approval.
  Future<AuthResult> register(String username, String password) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) throw ApiException('No server selected');
    final res = await _withAuth(
      active,
      null,
      (auth) => auth.register(username, password),
    );
    if (!res.pending && res.token != null && res.user != null) {
      await _activate(active, res.user!, res.token!);
    }
    return res;
  }

  /// Persist a freshly authenticated account and make it the active session.
  Future<void> _activate(LdInstance active, AppUser user, String token) =>
      _withCredentials(() => _activateLocked(active, user, token));

  Future<void> _activateLocked(
    LdInstance active,
    AppUser user,
    String token,
  ) async {
    if (!ref.mounted || ref.read(activeInstanceProvider)?.id != active.id) {
      throw ApiException('The server changed. Sign in to the selected server.');
    }
    final revision = ++_restoreRevision;
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    if ((state.user?.username != user.username || state.user?.id != user.id) &&
        !await _stopBackupBeforeAccountChange(active)) {
      throw ApiException(
        state.message ?? 'Could not pause the previous backup.',
      );
    }
    await store.writeUserToken(active.id, user.username, token);
    if (!_current(active, revision)) return;
    final accounts = _upsert(prefs.accounts(active.id), Account.fromUser(user));
    await prefs.writeAccounts(active.id, accounts);
    await prefs.setActiveAccount(active.id, user.username);
    await prefs.setBackupAccountBlocked(active.id, user.id, false);
    if (!_current(active, revision)) return;
    state = _authed(user, token, accounts);
    await _configureBackgroundAccess(active, user);
    await ref
        .read(connectionControllerProvider.notifier)
        .markConnected(active.id);
    // Refresh downstream data (drives, files, stats) for the new identity.
    ref.invalidate(dioProvider);
  }

  // ---- Account switching ---------------------------------------------------

  /// Instantly switch to another already-signed-in account on this server.
  Future<void> switchAccount(String username) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) return;
    final prev = state;
    if (prev.isAuthenticated && prev.user?.username == username) return;
    final revision = ++_restoreRevision;

    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    final accounts = prefs.accounts(active.id);
    final savedAccount = accounts
        .where((account) => account.username == username)
        .firstOrNull;
    final blocked =
        savedAccount?.userId != null &&
        prefs.backupAccountBlocked(active.id, savedAccount!.userId!);
    final token = blocked
        ? null
        : await store.readUserToken(active.id, username);
    if (!_current(active, revision)) return;
    if (!await _stopBackupBeforeAccountChange(active)) return;
    if (!_current(active, revision)) return;

    if (token == null || token.isEmpty) {
      // The account has no stored token — needs a fresh login.
      await prefs.setActiveAccount(active.id, username);
      state = _unauth(accounts, message: 'Please sign in again as $username.');
      ref.invalidate(dioProvider);
      return;
    }

    await prefs.setActiveAccount(active.id, username);
    // Verify with an identity-bound client; do not lend the target user's token
    // to requests belonging to the still-visible previous session.
    _checkingSwitchedAccount = true;
    try {
      final user = await _withAuth(active, token, (auth) => auth.me());
      if (!_current(active, revision)) return;
      final updated = _upsert(accounts, Account.fromUser(user));
      await prefs.writeAccounts(active.id, updated);
      if (!_current(active, revision)) return;
      state = _authed(user, token, updated);
      await _configureBackgroundAccess(active, user);
      ref.invalidate(dioProvider);
    } on ApiException catch (e) {
      if (!_current(active, revision)) return;
      if (e.isAuth) {
        await _withCredentials(() async {
          if (await store.readUserToken(active.id, username) == token) {
            await store.deleteUserToken(active.id, username);
          }
        });
      }
      if (!_current(active, revision)) return;
      // Revert to the previous account and surface the failure.
      await prefs.setActiveAccount(active.id, prev.user?.username);
      state = prev.copyWith(
        message: e.isAuth
            ? 'Could not switch to $username — the session expired.'
            : e.message,
      );
    } finally {
      _checkingSwitchedAccount = false;
    }
  }

  // ---- Sign out ------------------------------------------------------------

  /// Sign out a single account. If it's the active one, fall back to another
  /// signed-in account (or the login screen when none remain).
  Future<void> signOutAccount(String username) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) return;
    final fallback = await _withCredentials(
      () => _signOutLocked(active, username),
    );
    if (fallback != null && _current(active, fallback.$2)) {
      await switchAccount(fallback.$1);
    }
  }

  Future<(String, int)?> _signOutLocked(
    LdInstance active,
    String username,
  ) async {
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    final isActive =
        ref.read(activeInstanceProvider)?.id == active.id &&
        prefs.activeAccount(active.id) == username;
    final revision = isActive ? ++_restoreRevision : _restoreRevision;
    final account = prefs
        .accounts(active.id)
        .where((value) => value.username == username)
        .firstOrNull;
    final oldToken = await store.readUserToken(active.id, username);
    if (isActive && _current(active, revision)) {
      state = SessionState(
        status: SessionStatus.loading,
        viewMode: state.viewMode,
        accounts: prefs.accounts(active.id),
      );
    }
    try {
      await stopAccountBackup(
        prefs: prefs,
        instanceId: active.id,
        userId: account?.userId,
        discard: true,
        blockNewWork: true,
        invalidateSession: isActive,
      );
    } catch (error) {
      if (ref.mounted && ref.read(activeInstanceProvider)?.id == active.id) {
        state = isActive
            ? _unauth(
                prefs.accounts(active.id),
                message: backupFailureMessage(error),
              )
            : state.copyWith(message: backupFailureMessage(error));
      }
      return null;
    }

    if (isActive) {
      try {
        await _withAuth(active, oldToken, (auth) => auth.logout());
      } on ApiException catch (error) {
        await prefs.setBackgroundError(error.message);
      }
    }
    await store.deleteUserToken(active.id, username);
    final remaining = prefs
        .accounts(active.id)
        .where((a) => a.username != username)
        .toList();
    await prefs.writeAccounts(active.id, remaining);

    if (!isActive) {
      if (ref.mounted && ref.read(activeInstanceProvider)?.id == active.id) {
        state = state.copyWith(accounts: remaining);
      }
      return null;
    }
    if (!_current(active, revision)) return null;
    if (remaining.isNotEmpty) {
      await prefs.setActiveAccount(active.id, null);
      state = SessionState(
        status: SessionStatus.loading,
        viewMode: state.viewMode,
        accounts: remaining,
      );
      return (remaining.first.username, revision);
    } else {
      await prefs.setActiveAccount(active.id, null);
      state = _unauth(const []);
      ref.invalidate(dioProvider);
    }
    return null;
  }

  /// Top-level "Sign out" — signs out the active account (falling back to any
  /// other signed-in account on this server).
  Future<void> logout() async {
    final username = state.user?.username;
    if (username != null) {
      await signOutAccount(username);
      return;
    }
    final active = ref.read(activeInstanceProvider);
    if (active == null) {
      state = _unauth(const []);
      return;
    }
    await ref.read(prefsProvider).setActiveAccount(active.id, null);
    state = _unauth(ref.read(prefsProvider).accounts(active.id));
  }

  // ---- View scope + hooks --------------------------------------------------

  /// Toggle the admin view scope (persisted per instance).
  Future<void> setViewMode(String mode) async {
    final active = ref.read(activeInstanceProvider);
    if (active != null) {
      await ref.read(prefsProvider).setViewMode(active.id, mode);
    }
    state = state.copyWith(viewMode: mode);
  }

  /// Called by the Dio 401 hook — drop the active account's token so the router
  /// shows login. The account stays listed for easy re-authentication.
  void handleUnauthorized() {
    if (_checkingSwitchedAccount ||
        state.status != SessionStatus.authenticated) {
      return;
    }
    final active = ref.read(activeInstanceProvider);
    final username = state.user?.username;
    if (active != null && username != null) {
      _cancelUnauthorizedBackup(active, username, state.user?.id, state.token);
    }
    final accounts = active == null
        ? const <Account>[]
        : ref.read(prefsProvider).accounts(active.id);
    state = SessionState(
      status: SessionStatus.unauthenticated,
      viewMode: state.viewMode,
      accounts: accounts,
      message: 'Session expired. Please sign in again.',
    );
  }

  /// Re-run session restore (e.g. after a transient network error).
  Future<void> retry() async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) return;
    state = SessionState(
      status: SessionStatus.loading,
      viewMode: state.viewMode,
      accounts: state.accounts,
    );
    await _bootstrap(active, ++_restoreRevision);
  }

  // ---- Helpers -------------------------------------------------------------

  Future<bool> _stopBackupBeforeAccountChange(LdInstance active) async {
    final prefs = ref.read(prefsProvider);
    final previousName = prefs.activeAccount(active.id);
    final previous = prefs
        .accounts(active.id)
        .where((account) => account.username == previousName)
        .firstOrNull;
    try {
      await stopAccountBackup(
        prefs: prefs,
        instanceId: active.id,
        userId: previous?.userId,
      );
      return true;
    } catch (error) {
      state = state.copyWith(message: backupFailureMessage(error));
      return false;
    }
  }

  Future<void> _configureBackgroundAccess(
    LdInstance active,
    AppUser user,
  ) async {
    final prefs = ref.read(prefsProvider);
    try {
      final backup = prefs.readBackupSettings(active.id, user.id);
      await ref
          .read(secureStoreProvider)
          .setBackgroundAccess(
            active.id,
            user.username,
            enabled: backup.enabled || prefs.notificationsEnabled,
          );
      await prefs.setBackgroundError(null);
    } catch (error) {
      final message = backupFailureMessage(error);
      await prefs.setBackgroundError(message);
      state = state.copyWith(message: message);
    }
  }

  Future<void> _cancelUnauthorizedBackup(
    LdInstance active,
    String username,
    int? userId,
    String? expiredToken,
  ) => _withCredentials(() async {
    final prefs = ref.read(prefsProvider);
    final store = ref.read(secureStoreProvider);
    if (expiredToken == null ||
        await store.readUserToken(active.id, username) != expiredToken) {
      return;
    }
    try {
      await stopAccountBackup(
        prefs: prefs,
        instanceId: active.id,
        userId: userId,
        blockNewWork: true,
      );
    } catch (error) {
      await prefs.setBackgroundError(backupFailureMessage(error));
    } finally {
      await store.deleteUserToken(active.id, username);
    }
  });

  SessionState _authed(AppUser user, String token, List<Account> accounts) =>
      SessionState(
        status: SessionStatus.authenticated,
        user: user,
        token: token,
        viewMode: state.viewMode,
        accounts: accounts,
      );

  SessionState _unauth(List<Account> accounts, {String? message}) =>
      SessionState(
        status: SessionStatus.unauthenticated,
        viewMode: state.viewMode,
        accounts: accounts,
        message: message,
      );

  List<Account> _upsert(List<Account> list, Account acc) {
    final out = [...list];
    final idx = out.indexWhere((a) => a.username == acc.username);
    if (idx >= 0) {
      out[idx] = out[idx].copyWith(role: acc.role, userId: acc.userId);
    } else {
      out.add(acc);
    }
    return out;
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
