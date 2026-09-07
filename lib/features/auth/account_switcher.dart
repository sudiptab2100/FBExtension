import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/account.dart';
import '../../routing/router.dart';
import '../../state/connection_controller.dart';
import '../../state/session_controller.dart';

/// App-bar button showing the active user's avatar. Tapping it opens the
/// multi-account switcher for the current server.
class AccountSwitchButton extends ConsumerWidget {
  const AccountSwitchButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionControllerProvider.select((s) => s.user));
    final count = ref.watch(
      sessionControllerProvider.select((s) => s.accounts.length),
    );
    final scheme = Theme.of(context).colorScheme;
    final initial = _initialOf(user?.username);

    return IconButton(
      tooltip: 'Accounts',
      onPressed: () => showAccountSwitcher(context, ref),
      icon: Badge(
        isLabelVisible: count > 1,
        label: Text('$count'),
        child: CircleAvatar(
          radius: 14,
          backgroundColor: scheme.primaryContainer,
          child: Text(
            initial,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

String _initialOf(String? username) {
  final u = (username ?? '').trim();
  return u.isEmpty ? '?' : u.characters.first.toUpperCase();
}

/// Opens the account switcher bottom sheet for the active server.
void showAccountSwitcher(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _AccountSheet(),
  );
}

class _AccountSheet extends ConsumerWidget {
  const _AccountSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final server = ref.watch(activeInstanceProvider);
    final activeUsername = session.user?.username;
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Accounts', style: theme.textTheme.titleMedium),
                  if (server != null)
                    Text('on ${server.name}', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final acc in session.accounts)
                    _AccountTile(
                      account: acc,
                      isActive: acc.username == activeUsername,
                      onSwitch: () => _switch(context, ref, acc.username),
                      onSignOut: () => _signOut(context, ref, acc),
                    ),
                ],
              ),
            ),
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1),
              title: const Text('Add account'),
              subtitle: const Text('Sign in as another user on this server'),
              onTap: () {
                Navigator.of(context).pop();
                context.push(Routes.addAccount);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switch(
    BuildContext context,
    WidgetRef ref,
    String username,
  ) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    await container
        .read(sessionControllerProvider.notifier)
        .switchAccount(username);
    final msg = container.read(sessionControllerProvider).message;
    if (msg != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _signOut(
    BuildContext context,
    WidgetRef ref,
    Account account,
  ) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sign out ${account.label}?'),
        content: const Text(
          'This removes the saved session for this account on this server. '
          'Other accounts stay signed in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (context.mounted) Navigator.of(context).pop();
    await container
        .read(sessionControllerProvider.notifier)
        .signOutAccount(account.username);
    final message = container.read(sessionControllerProvider).message;
    if (message != null && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isActive,
    required this.onSwitch,
    required this.onSignOut,
  });

  final Account account;
  final bool isActive;
  final VoidCallback onSwitch;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: isActive,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.25),
      leading: CircleAvatar(
        backgroundColor: isActive
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        foregroundColor: isActive ? scheme.onPrimary : scheme.onSurface,
        child: Text(_initialOf(account.username)),
      ),
      title: Text(account.label),
      subtitle: Text(account.isAdmin ? 'Administrator' : 'User'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isActive)
            Icon(Icons.check_circle, color: scheme.primary, size: 20),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: onSignOut,
          ),
        ],
      ),
      onTap: isActive ? null : onSwitch,
    );
  }
}
