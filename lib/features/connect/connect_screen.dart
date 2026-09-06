import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/ld_instance.dart';
import '../../data/services/discovery_service.dart';
import '../../routing/router.dart';
import '../../state/connection_controller.dart';
import 'connect_flow.dart';

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
      await connectWithTrust(context, ref, candidate);
      // The router redirect takes over once the instance becomes active.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(connectionControllerProvider).instances;
    final discovery = ref.watch(discoveryControllerProvider);
    final fresh = discovery.instances
        .where((d) => !saved.any((s) => s.id == d.id))
        .toList();

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
                  onTap: () => ref
                      .read(connectionControllerProvider.notifier)
                      .setActive(i.id),
                  onDelete: () => ref
                      .read(connectionControllerProvider.notifier)
                      .remove(i.id),
                )),
            const Divider(height: 24),
          ],
          _DiscoveryHeader(
            phase: discovery.phase,
            onRescan: () =>
                ref.read(discoveryControllerProvider.notifier).rescan(),
          ),
          if (fresh.isEmpty)
            _DiscoveryEmpty(phase: discovery.phase, error: discovery.error)
          else
            ...fresh.map((i) => _InstanceTile(
                  instance: i,
                  leading: const Icon(Icons.wifi_tethering),
                  onTap: () => _connect(i),
                )),
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

/// "On this network" header with a live search indicator + manual rescan.
class _DiscoveryHeader extends StatelessWidget {
  const _DiscoveryHeader({required this.phase, required this.onRescan});
  final DiscoveryPhase phase;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    final searching = phase == DiscoveryPhase.searching;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'ON THIS NETWORK',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          if (searching)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
            onPressed: searching ? null : onRescan,
          ),
        ],
      ),
    );
  }
}

class _DiscoveryEmpty extends StatelessWidget {
  const _DiscoveryEmpty({required this.phase, this.error});
  final DiscoveryPhase phase;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final String text;
    if (phase == DiscoveryPhase.searching) {
      text = 'Searching for servers on your Wi‑Fi…';
    } else if (phase == DiscoveryPhase.error) {
      text = '${error ?? 'Discovery failed.'}\n\n'
          'On iPhone, make sure LocalDrive is allowed under Settings → '
          'Privacy → Local Network, then tap rescan.';
    } else {
      text = 'No servers found. Make sure LocalDrive is running on a computer '
          'on the same Wi‑Fi, then tap rescan — or add it manually below.';
    }
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
    required this.onTap,
    this.leading,
    this.onDelete,
  });

  final LdInstance instance;
  final VoidCallback onTap;
  final Widget? leading;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    // Show every reachable address so the user can see all IPs and the .local
    // name at a glance.
    final subtitle = instance.addresses.isNotEmpty
        ? instance.addressSummary
        : instance.baseUrl;
    return ListTile(
      leading: leading ?? const Icon(Icons.dns_outlined),
      title: Text(instance.name),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      isThreeLine: instance.addresses.length > 1,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SchemeBadge(instance: instance),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove',
              onPressed: onDelete,
            )
          else
            const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// A small HTTPS/HTTP badge so the user can tell secure servers apart.
class _SchemeBadge extends StatelessWidget {
  const _SchemeBadge({required this.instance});
  final LdInstance instance;

  @override
  Widget build(BuildContext context) {
    final secure = instance.isHttps || instance.hasHttps;
    final scheme = Theme.of(context).colorScheme;
    final color = secure ? scheme.primary : scheme.outline;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(secure ? Icons.lock_outline : Icons.lock_open_outlined,
              size: 14, color: color),
          const SizedBox(width: 2),
          Text(
            secure ? 'HTTPS' : 'HTTP',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
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
