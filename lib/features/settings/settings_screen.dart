import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../routing/router.dart';
import '../../state/connection_controller.dart';
import '../../state/session_controller.dart';
import '../../state/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final active = ref.watch(activeInstanceProvider);
    final themeMode = ref.watch(themeModeProvider);
    final user = session.user;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ---- Account -------------------------------------------------
          if (user != null)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(user.username.isNotEmpty
                      ? user.username[0].toUpperCase()
                      : '?'),
                ),
                title: Text(user.username),
                subtitle: Text(user.isAdmin ? 'Administrator' : 'User'),
                trailing: user.isAdmin
                    ? Chip(
                        label: const Text('Admin'),
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        visualDensity: VisualDensity.compact,
                      )
                    : null,
              ),
            ),

          // ---- Server --------------------------------------------------
          const _SectionHeader('Server'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(active?.name ?? 'Not connected'),
            subtitle: Text(active?.baseUrl ?? ''),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Switch server'),
            subtitle: const Text('Disconnect and choose another LocalDrive'),
            onTap: () => _confirmSwitch(context, ref),
          ),

          // ---- Admin ---------------------------------------------------
          if (session.isAdmin) ...[
            const _SectionHeader('Admin'),
            SwitchListTile(
              secondary: const Icon(Icons.groups_outlined),
              title: const Text("View all users' spaces"),
              subtitle: const Text(
                  'Off shows only your own space, like a normal user'),
              value: session.viewMode == ViewCookie.admin,
              onChanged: (on) => ref
                  .read(sessionControllerProvider.notifier)
                  .setViewMode(on ? ViewCookie.admin : ViewCookie.user),
            ),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Admin console'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(Routes.admin),
            ),
          ],

          // ---- Appearance ----------------------------------------------
          const _SectionHeader('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
              ],
              selected: {themeMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).set(s.first),
            ),
          ),

          // ---- Notifications -------------------------------------------
          const _SectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('File & access alerts'),
            subtitle: const Text(
                'Notify me when my files or drive access change, including '
                'in the background'),
            value: ref.watch(notificationsEnabledProvider),
            onChanged: (on) =>
                ref.read(notificationsEnabledProvider.notifier).set(on),
          ),

          // ---- About ---------------------------------------------------
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('LocalDrive'),
            subtitle: Text('Mobile client · v$_appVersion'),
          ),

          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
              onPressed: () => _confirmLogout(context, ref),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static const _appVersion = '1.0.0';

  Future<void> _confirmSwitch(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch server?'),
        content: const Text(
            'You will return to the server chooser. Your saved sign-in for '
            'this server is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Switch')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(connectionControllerProvider.notifier).setActive(null);
    }
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again on this server.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(sessionControllerProvider.notifier).logout();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}
