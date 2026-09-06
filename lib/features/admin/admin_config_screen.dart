import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/app_config.dart';
import '../../state/api_providers.dart';
import '../../widgets/status_views.dart';

final adminConfigProvider = FutureProvider.autoDispose<AppConfig>(
  (ref) => ref.watch(adminRepositoryProvider).config(),
);

class AdminConfigScreen extends ConsumerStatefulWidget {
  const AdminConfigScreen({super.key});

  @override
  ConsumerState<AdminConfigScreen> createState() => _AdminConfigScreenState();
}

class _AdminConfigScreenState extends ConsumerState<AdminConfigScreen> {
  bool _busy = false;

  Future<void> _patch(Map<String, dynamic> patch) async {
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(adminRepositoryProvider).patchConfig(patch);
      ref.invalidate(adminConfigProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.restarted
              ? 'Saved · server restarting'
              : 'Saved'),
        ));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(adminConfigProvider),
        ),
        data: (cfg) => ListView(
          children: [
            const _Header('Registration'),
            SwitchListTile(
              title: const Text('Allow self-registration'),
              subtitle: const Text('Users can create their own accounts'),
              value: cfg.registrationEnabled,
              onChanged: _busy
                  ? null
                  : (v) => _patch({'registrationEnabled': v}),
            ),
            SwitchListTile(
              title: const Text('Auto-approve new accounts'),
              subtitle: const Text('Skip admin approval for sign-ups'),
              value: cfg.autoApproveRegistrations,
              onChanged: _busy
                  ? null
                  : (v) => _patch({'autoApproveRegistrations': v}),
            ),
            SwitchListTile(
              title: const Text('Auto-approve access requests'),
              subtitle: const Text('Grant drive access without review'),
              value: cfg.autoApproveAccessRequests,
              onChanged: _busy
                  ? null
                  : (v) => _patch({'autoApproveAccessRequests': v}),
            ),
            const _Header('Server'),
            SwitchListTile(
              title: const Text('Start automatically'),
              subtitle: const Text('Launch the server on app start'),
              value: cfg.autoStart,
              onChanged: _busy ? null : (v) => _patch({'autoStart': v}),
            ),
            SwitchListTile(
              title: const Text('Enable HTTPS'),
              subtitle: const Text('Serve over TLS (restarts server)'),
              value: cfg.httpsEnabled,
              onChanged: _busy ? null : (v) => _patch({'httpsEnabled': v}),
            ),
            _EditRow(
              label: 'HTTP port',
              value: '${cfg.port}',
              enabled: !_busy,
              onEdit: () => _editNumber('HTTP port', 'port', cfg.port),
            ),
            _EditRow(
              label: 'HTTPS port',
              value: '${cfg.httpsPort}',
              enabled: !_busy,
              onEdit: () =>
                  _editNumber('HTTPS port', 'httpsPort', cfg.httpsPort),
            ),
            _EditRow(
              label: 'Bind address',
              value: cfg.host,
              enabled: !_busy,
              onEdit: () => _editText('Bind address', 'host', cfg.host),
            ),
            _EditRow(
              label: 'Share folder name',
              value: cfg.shareRootName,
              enabled: !_busy,
              onEdit: () => _editText(
                  'Share folder name', 'shareRootName', cfg.shareRootName),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _editNumber(String title, String key, int current) async {
    final controller = TextEditingController(text: '$current');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (value == null) return;
    final n = int.tryParse(value.trim());
    if (n == null) return;
    await _patch({key: n});
  }

  Future<void> _editText(String title, String key, String current) async {
    final controller = TextEditingController(text: current);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    await _patch({key: value.trim()});
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
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

class _EditRow extends StatelessWidget {
  const _EditRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onEdit,
  });

  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.edit_outlined),
      enabled: enabled,
      onTap: onEdit,
    );
  }
}
