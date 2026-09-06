import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../routing/router.dart';
import '../../state/api_providers.dart';
import '../../state/connection_controller.dart';
import '../../state/session_controller.dart';

/// Auth config (whether self-registration is open) for the active server.
final _authConfigProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(authRepositoryProvider).config(),
);

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.addAccount = false});

  /// When true, this screen adds *another* account to the current server
  /// (the user is already signed in) instead of being the pre-auth gate.
  final bool addAccount;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _registerMode = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final username = _username.text.trim();
    final password = _password.text;
    try {
      if (_registerMode) {
        final res =
            await ref.read(sessionControllerProvider.notifier).register(
                  username,
                  password,
                );
        if (res.pending && mounted) {
          setState(() => _registerMode = false);
          _showInfo(res.message ??
              'Your account is awaiting admin approval. You can sign in once '
                  'approved.');
        } else if (!res.pending && mounted && widget.addAccount) {
          context.go(Routes.home);
        }
      } else {
        await ref
            .read(sessionControllerProvider.notifier)
            .login(username, password);
        // Normal mode → the router redirect navigates home. In add-account
        // mode we're already authenticated, so navigate explicitly.
        if (mounted && widget.addAccount) context.go(Routes.home);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showInfo(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Account pending'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(activeInstanceProvider);
    final sessionMessage = ref.watch(
        sessionControllerProvider.select((s) => s.message));
    final authConfig = ref.watch(_authConfigProvider);
    final canRegister = authConfig.asData?.value.registrationEnabled ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.addAccount ? 'Add account' : 'Sign in'),
        actions: [
          TextButton.icon(
            onPressed: () {
              if (widget.addAccount) {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go(Routes.home);
                }
              } else {
                ref
                    .read(connectionControllerProvider.notifier)
                    .setActive(null);
              }
            },
            icon: Icon(widget.addAccount ? Icons.close : Icons.swap_horiz),
            label: Text(widget.addAccount ? 'Cancel' : 'Change'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset('assets/branding/localdrive_logo.png',
                        width: 72, height: 72),
                    const SizedBox(height: 12),
                    Text(
                      active?.name ?? 'LocalDrive',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (active != null)
                      Text(
                        active.baseUrl,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (widget.addAccount) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Add another account to this server. Your current '
                        'session stays signed in and you can switch anytime.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (sessionMessage != null && _error == null)
                      _Banner(sessionMessage,
                          color: Theme.of(context).colorScheme.tertiary),
                    if (_error != null)
                      _Banner(_error!,
                          color: Theme.of(context).colorScheme.error),
                    TextFormField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_registerMode ? 'Create account' : 'Sign in'),
                    ),
                    if (canRegister) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _registerMode = !_registerMode;
                                  _error = null;
                                }),
                        child: Text(_registerMode
                            ? 'Have an account? Sign in'
                            : "New here? Create an account"),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
