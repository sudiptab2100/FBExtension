import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/acl.dart';
import '../../data/models/user.dart';
import '../../state/api_providers.dart';
import '../../state/session_controller.dart';
import '../../widgets/status_views.dart';

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUser>>(
  (ref) => ref.watch(adminRepositoryProvider).users(),
);

class AdminUsersScreen extends ConsumerWidget {
  const AdminUsersScreen({super.key});

  Future<void> _guard(
      BuildContext context, WidgetRef ref, Future<void> Function() action) async {
    try {
      await action();
      ref.invalidate(adminUsersProvider);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminUsersProvider);
    final meId = ref.watch(sessionControllerProvider).user?.id;
    final repo = ref.read(adminRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createUser(context, ref),
        icon: const Icon(Icons.person_add),
        label: const Text('Add user'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(adminUsersProvider),
        ),
        data: (users) {
          if (users.isEmpty) {
            return const EmptyView(
                icon: Icons.group_off, message: 'No users yet.');
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(adminUsersProvider),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: users.length,
              itemBuilder: (_, i) {
                final au = users[i];
                final u = au.user;
                final isSelf = u.id == meId;
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(u.username.isNotEmpty
                        ? u.username[0].toUpperCase()
                        : '?'),
                  ),
                  title: Row(
                    children: [
                      Flexible(child: Text(u.username)),
                      if (u.isAdmin) ...[
                        const SizedBox(width: 8),
                        const _Tag('admin'),
                      ],
                      if (u.isPending) ...[
                        const SizedBox(width: 8),
                        const _Tag('pending', warn: true),
                      ],
                    ],
                  ),
                  subtitle: Text(_subtitle(au.acls)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => _onAction(context, ref, repo, u, v),
                    itemBuilder: (_) => [
                      if (u.isPending)
                        const PopupMenuItem(
                            value: 'approve', child: Text('Approve')),
                      PopupMenuItem(
                        value: 'role',
                        child: Text(u.isAdmin ? 'Make user' : 'Make admin'),
                      ),
                      const PopupMenuItem(
                          value: 'password', child: Text('Reset password')),
                      if (!isSelf)
                        const PopupMenuItem(
                            value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  String _subtitle(List<Acl> acls) {
    if (acls.isEmpty) return 'No drive grants';
    return '${acls.length} drive grant${acls.length == 1 ? '' : 's'}';
  }

  void _onAction(BuildContext context, WidgetRef ref, dynamic repo, AppUser u,
      String action) {
    switch (action) {
      case 'approve':
        _guard(context, ref, () => repo.approveUser(u.id));
      case 'role':
        _guard(context, ref,
            () => repo.setRole(u.id, u.isAdmin ? 'user' : 'admin'));
      case 'password':
        _resetPassword(context, ref, u);
      case 'delete':
        _deleteUser(context, ref, u);
    }
  }

  Future<void> _resetPassword(
      BuildContext context, WidgetRef ref, AppUser u) async {
    final controller = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset password · ${u.username}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'New password'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Set')),
        ],
      ),
    );
    if (pw == null || pw.isEmpty) return;
    if (!context.mounted) return;
    await _guard(context, ref,
        () => ref.read(adminRepositoryProvider).setPassword(u.id, pw));
  }

  Future<void> _deleteUser(
      BuildContext context, WidgetRef ref, AppUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${u.username}?'),
        content: const Text(
            'The account is removed. Files in their space are not deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _guard(
        context, ref, () => ref.read(adminRepositoryProvider).deleteUser(u.id));
  }

  Future<void> _createUser(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_NewUser>(
      context: context,
      builder: (_) => const _CreateUserDialog(),
    );
    if (result == null || !context.mounted) return;
    await _guard(
      context,
      ref,
      () => ref
          .read(adminRepositoryProvider)
          .createUser(result.username, result.password, result.role)
          .then((_) {}),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.warn = false});
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = warn ? scheme.tertiary : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _NewUser {
  const _NewUser(this.username, this.password, this.role);
  final String username;
  final String password;
  final String role;
}

class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog();

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  String _role = 'user';

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add user'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _username,
            autofocus: true,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            items: const [
              DropdownMenuItem(value: 'user', child: Text('User')),
              DropdownMenuItem(value: 'admin', child: Text('Admin')),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'user'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final u = _username.text.trim();
            final p = _password.text;
            if (u.isEmpty || p.isEmpty) return;
            Navigator.pop(context, _NewUser(u, p, _role));
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
