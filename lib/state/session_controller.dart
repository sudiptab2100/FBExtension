import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../core/network/api_exception.dart';
import '../data/models/account.dart';
import '../data/models/ld_instance.dart';
import '../data/models/user.dart';
import '../data/repositories/auth_repository.dart';
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
  }) =>
      SessionState(
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
    _bootstrap(active);
    return SessionState(
      status: SessionStatus.loading,
      viewMode: vm,
      accounts: accounts,
    );
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  // ---- Session restore -----------------------------------------------------

  Future<void> _bootstrap(LdInstance active) async {
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    var accounts = prefs.accounts(active.id);

    // One-time migration from the legacy single-token-per-instance layout.
    if (accounts.isEmpty) {
      final legacy = await store.readToken(active.id);
      if (legacy == null || legacy.isEmpty) {
        state = _unauth(const []);
        return;
      }
      state = state.copyWith(token: legacy);
      try {
        final user = await _auth.me();
        await store.writeUserToken(active.id, user.username, legacy);
        await store.deleteToken(active.id);
        accounts = [Account.fromUser(user)];
        await prefs.writeAccounts(active.id, accounts);
        await prefs.setActiveAccount(active.id, user.username);
        state = _authed(user, legacy, accounts);
      } on ApiException catch (e) {
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
    final token = await store.readUserToken(active.id, username);
    if (token == null || token.isEmpty) {
      // A listed account without a stored token — require re-login but keep it.
      state = _unauth(accounts);
      return;
    }
    state = state.copyWith(token: token, accounts: accounts);
    try {
      final user = await _auth.me();
      accounts = _upsert(accounts, Account.fromUser(user));
      await prefs.writeAccounts(active.id, accounts);
      state = _authed(user, token, accounts);
    } on ApiException catch (e) {
      if (e.isAuth) {
        await store.deleteUserToken(active.id, username);
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
    final res = await _auth.login(username, password);
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
    final res = await _auth.register(username, password);
    if (!res.pending && res.token != null && res.user != null) {
      await _activate(active, res.user!, res.token!);
    }
    return res;
  }

  /// Persist a freshly authenticated account and make it the active session.
  Future<void> _activate(LdInstance active, AppUser user, String token) async {
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    await store.writeUserToken(active.id, user.username, token);
    final accounts = _upsert(prefs.accounts(active.id), Account.fromUser(user));
    await prefs.writeAccounts(active.id, accounts);
    await prefs.setActiveAccount(active.id, user.username);
    state = _authed(user, token, accounts);
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

    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    final accounts = prefs.accounts(active.id);
    final token = await store.readUserToken(active.id, username);

    if (token == null || token.isEmpty) {
      // The account has no stored token — needs a fresh login.
      await prefs.setActiveAccount(active.id, username);
      state = _unauth(accounts, message: 'Please sign in again as $username.');
      ref.invalidate(dioProvider);
      return;
    }

    await prefs.setActiveAccount(active.id, username);
    // Swap the token first so /me runs as the target user; keep the current UI
    // visible (no splash flash) until we know the switch succeeded.
    state = prev.copyWith(token: token, clearMessage: true);
    try {
      final user = await _auth.me();
      final updated = _upsert(accounts, Account.fromUser(user));
      await prefs.writeAccounts(active.id, updated);
      state = _authed(user, token, updated);
      ref.invalidate(dioProvider);
    } on ApiException catch (e) {
      if (e.isAuth) await store.deleteUserToken(active.id, username);
      // Revert to the previous account and surface the failure.
      await prefs.setActiveAccount(active.id, prev.user?.username);
      state = prev.copyWith(
        message: e.isAuth
            ? 'Could not switch to $username — the session expired.'
            : e.message,
      );
    }
  }

  // ---- Sign out ------------------------------------------------------------

  /// Sign out a single account. If it's the active one, fall back to another
  /// signed-in account (or the login screen when none remain).
  Future<void> signOutAccount(String username) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) return;
    final store = ref.read(secureStoreProvider);
    final prefs = ref.read(prefsProvider);
    final isActive = state.isAuthenticated && state.user?.username == username;

    if (isActive) {
      try {
        await _auth.logout();
      } catch (_) {
        // Best-effort; local sign-out proceeds regardless.
      }
    }
    await store.deleteUserToken(active.id, username);
    final remaining =
        prefs.accounts(active.id).where((a) => a.username != username).toList();
    await prefs.writeAccounts(active.id, remaining);

    if (!isActive) {
      state = state.copyWith(accounts: remaining);
      return;
    }
    if (remaining.isNotEmpty) {
      await prefs.setActiveAccount(active.id, null);
      state = SessionState(
        status: SessionStatus.loading,
        viewMode: state.viewMode,
        accounts: remaining,
      );
      await switchAccount(remaining.first.username);
    } else {
      await prefs.setActiveAccount(active.id, null);
      state = _unauth(const []);
      ref.invalidate(dioProvider);
    }
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
    if (state.status != SessionStatus.authenticated) return;
    final active = ref.read(activeInstanceProvider);
    final username = state.user?.username;
    if (active != null && username != null) {
      ref.read(secureStoreProvider).deleteUserToken(active.id, username);
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
    await _bootstrap(active);
  }

  // ---- Helpers -------------------------------------------------------------

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
      out[idx] = out[idx].copyWith(role: acc.role);
    } else {
      out.add(acc);
    }
    return out;
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
