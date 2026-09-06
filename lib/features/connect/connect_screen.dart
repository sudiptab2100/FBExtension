import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/ld_instance.dart';
import '../../data/services/discovery_service.dart';
import '../../routing/router.dart';
import '../../state/connect_controller.dart';
import '../../state/connection_controller.dart';

/// First-run / server-chooser screen: saved servers, live LAN discovery, QR
/// scan, and manual entry. Selecting a server makes it active.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  bool _busy = false;

  Future<void> _connect(LdInstance candidate) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(connectControllerProvider).connect(candidate);
      // The router redirect takes over once the instance becomes active.
    } on ApiException catch (e) {
      if (!mounted) return;
      if (candidate.isHttps && e.isNetwork) {
        _offerTrust(candidate);
      } else {
        _snack(e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _offerTrust(LdInstance candidate) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Untrusted certificate'),
        content: Text(
          '${candidate.host} uses a self-signed certificate. Trust it for '
          'this server and continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _connect(candidate.copyWith(trustSelfSigned: true));
            },
            child: const Text('Trust & connect'),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(connectionControllerProvider).instances;
    final discovered = ref.watch(discoveredInstancesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect to LocalDrive'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (saved.isNotEmpty) ...[
            const _SectionHeader('Saved servers'),
            ...saved.map((i) => _InstanceTile(
                  instance: i,
                  subtitle: i.baseUrl,
                  onTap: () => ref
                      .read(connectionControllerProvider.notifier)
                      .setActive(i.id),
                  onDelete: () => ref
                      .read(connectionControllerProvider.notifier)
                      .remove(i.id),
                )),
            const Divider(height: 24),
          ],
          const _SectionHeader('On this network'),
          discovered.when(
            loading: () => const _Hint('Searching for servers…'),
            error: (e, _) => _Hint('Discovery unavailable: $e'),
            data: (list) {
              final fresh = list
                  .where((d) => !saved.any((s) => s.id == d.id))
                  .toList();
              if (fresh.isEmpty) {
                return const _Hint(
                  'No servers found yet. Make sure LocalDrive is running on a '
                  'computer on the same Wi‑Fi, or add it manually below.',
                );
              }
              return Column(
                children: fresh
                    .map((i) => _InstanceTile(
                          instance: i,
                          subtitle: i.baseUrl,
                          leading: const Icon(Icons.wifi_tethering),
                          onTap: () => _connect(i),
                        ))
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => context.push(Routes.qrScan),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR code'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _showManualEntry,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Enter address manually'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _showManualEntry() async {
    final result = await showModalBottomSheet<LdInstance>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ManualEntrySheet(),
    );
    if (result != null) await _connect(result);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _InstanceTile extends StatelessWidget {
  const _InstanceTile({
    required this.instance,
    required this.subtitle,
    required this.onTap,
    this.leading,
    this.onDelete,
  });

  final LdInstance instance;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? leading;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading ?? const Icon(Icons.dns_outlined),
      title: Text(instance.name),
      subtitle: Text(subtitle),
      onTap: onTap,
      trailing: onDelete == null
          ? const Icon(Icons.chevron_right)
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: onDelete,
            ),
    );
  }
}

/// Bottom sheet for manual endpoint entry (host/URL + port + HTTPS).
class _ManualEntrySheet extends StatefulWidget {
  const _ManualEntrySheet();

  @override
  State<_ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends State<_ManualEntrySheet> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  bool _https = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    final scheme = _https ? 'https' : 'http';
    final portText = _port.text.trim();
    final input = host.contains('://')
        ? host
        : '$scheme://$host${portText.isEmpty ? '' : ':$portText'}';
    final instance = LdInstance.tryParse(input);
    if (instance != null) Navigator.pop(context, instance);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add server', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Host or URL',
              hintText: '192.168.1.20 or http://mac.local:4820',
              prefixIcon: Icon(Icons.link),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Port (optional)',
              hintText: '4820',
              prefixIcon: Icon(Icons.numbers),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use HTTPS'),
            value: _https,
            onChanged: (v) => setState(() => _https = v),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _submit, child: const Text('Connect')),
        ],
      ),
    );
  }
}
