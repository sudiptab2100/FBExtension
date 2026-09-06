import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../core/network/api_exception.dart';
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
  });

  final SessionStatus status;
  final AppUser? user;
  final String? token;

  /// Admin-only view scope: 'admin' (whole share) or 'user' (own space).
  final String viewMode;
  final String? message;

  bool get isAuthenticated => status == SessionStatus.authenticated;
  bool get isAdmin => user?.isAdmin ?? false;

  /// The effective scope actually applied by the server for this session.
  String get effectiveViewMode => isAdmin ? viewMode : ViewCookie.user;

  SessionState copyWith({
    SessionStatus? status,
    AppUser? user,
    String? token,
    String? viewMode,
    String? message,
    bool clearMessage = false,
  }) =>
      SessionState(
        status: status ?? this.status,
        user: user ?? this.user,
        token: token ?? this.token,
        viewMode: viewMode ?? this.viewMode,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// Manages login/register/logout and session restore, rebuilding whenever the
/// active instance changes (switching servers re-bootstraps auth).
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    final active = ref.watch(activeInstanceProvider);
    if (active == null) {
      return const SessionState(status: SessionStatus.unauthenticated);
    }
    final vm = ref.read(prefsProvider).viewMode(active.id);
    // Restore any saved token and verify it in the background.
    _bootstrap(active);
    return SessionState(status: SessionStatus.loading, viewMode: vm);
  }

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  Future<void> _bootstrap(LdInstance active) async {
    final token = await ref.read(secureStoreProvider).readToken(active.id);
    if (token == null || token.isEmpty) {
      state = state.copyWith(status: SessionStatus.unauthenticated);
      return;
    }
    // Expose the token so the Dio interceptor authenticates the /me probe.
    state = state.copyWith(token: token);
    try {
      final user = await _auth.me();
      state = SessionState(
        status: SessionStatus.authenticated,
        user: user,
        token: token,
        viewMode: state.viewMode,
      );
    } on ApiException catch (e) {
      if (e.isAuth) {
        await ref.read(secureStoreProvider).deleteToken(active.id);
        state = SessionState(
          status: SessionStatus.unauthenticated,
          viewMode: state.viewMode,
        );
      } else {
        // Reachability problem — allow the UI to retry without wiping the token.
        state = SessionState(
          status: SessionStatus.unauthenticated,
          viewMode: state.viewMode,
          message: e.message,
        );
      }
    }
  }

  /// Sign in. Throws [ApiException] on failure (including `pending` accounts).
  Future<void> login(String username, String password) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) throw ApiException('No server selected');
    final res = await _auth.login(username, password);
    if (res.token == null || res.user == null) {
      throw ApiException('Login failed');
    }
    await ref.read(secureStoreProvider).writeToken(active.id, res.token!);
    state = SessionState(
      status: SessionStatus.authenticated,
      user: res.user,
      token: res.token,
      viewMode: state.viewMode,
    );
    await ref.read(connectionControllerProvider.notifier).markConnected(active.id);
  }

  /// Register. Returns the [AuthResult]; when auto-approved the user is signed
  /// in immediately, otherwise the account is pending admin approval.
  Future<AuthResult> register(String username, String password) async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) throw ApiException('No server selected');
    final res = await _auth.register(username, password);
    if (!res.pending && res.token != null && res.user != null) {
      await ref.read(secureStoreProvider).writeToken(active.id, res.token!);
      state = SessionState(
        status: SessionStatus.authenticated,
        user: res.user,
        token: res.token,
        viewMode: state.viewMode,
      );
      await ref
          .read(connectionControllerProvider.notifier)
          .markConnected(active.id);
    }
    return res;
  }

  Future<void> logout() async {
    final active = ref.read(activeInstanceProvider);
    try {
      await _auth.logout();
    } catch (_) {
      // Best-effort; local sign-out proceeds regardless.
    }
    if (active != null) {
      await ref.read(secureStoreProvider).deleteToken(active.id);
    }
    state = SessionState(
      status: SessionStatus.unauthenticated,
      viewMode: state.viewMode,
    );
  }

  /// Toggle the admin view scope (persisted per instance).
  Future<void> setViewMode(String mode) async {
    final active = ref.read(activeInstanceProvider);
    if (active != null) {
      await ref.read(prefsProvider).setViewMode(active.id, mode);
    }
    state = state.copyWith(viewMode: mode);
  }

  /// Called by the Dio 401 hook — drop the session so the router shows login.
  void handleUnauthorized() {
    if (state.status != SessionStatus.authenticated) return;
    final active = ref.read(activeInstanceProvider);
    if (active != null) {
      ref.read(secureStoreProvider).deleteToken(active.id);
    }
    state = SessionState(
      status: SessionStatus.unauthenticated,
      viewMode: state.viewMode,
      message: 'Session expired. Please sign in again.',
    );
  }

  /// Re-run session restore (e.g. after a transient network error).
  Future<void> retry() async {
    final active = ref.read(activeInstanceProvider);
    if (active == null) return;
    state = SessionState(status: SessionStatus.loading, viewMode: state.viewMode);
    await _bootstrap(active);
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
