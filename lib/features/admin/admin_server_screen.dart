import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/format.dart';
import '../../data/models/server_status.dart';
import '../../state/api_providers.dart';
import '../../widgets/status_views.dart';

/// Server status derived from the dashboard snapshot.
final adminServerStatusProvider = FutureProvider.autoDispose<ServerStatus>(
  (ref) async {
    final data = await ref.watch(adminRepositoryProvider).dashboard();
    return ServerStatus.fromJson((data['server'] as Map).cast<String, dynamic>());
  },
);

class AdminServerScreen extends ConsumerStatefulWidget {
  const AdminServerScreen({super.key});

  @override
  ConsumerState<AdminServerScreen> createState() => _AdminServerScreenState();
}

class _AdminServerScreenState extends ConsumerState<AdminServerScreen> {
  bool _busy = false;

  Future<void> _act(String label, Future<void> Function() action,
      {bool warnDisconnect = false}) async {
    if (warnDisconnect) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$label server?'),
          content: const Text(
              'This tears down the connection serving this app. You may need '
              'to reconnect afterwards.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(label)),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label requested')));
      }
      ref.invalidate(adminServerStatusProvider);
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
    final async = ref.watch(adminServerStatusProvider);
    final repo = ref.read(adminRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Server control')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(adminServerStatusProvider),
        ),
        data: (status) {
          final scheme = Theme.of(context).colorScheme;
          final color = status.running ? Colors.green : scheme.error;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: color.withValues(alpha: 0.10),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(status.running ? Icons.cloud_done : Icons.cloud_off,
                          color: color, size: 32),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(status.running ? 'Running' : 'Stopped',
                                style:
                                    Theme.of(context).textTheme.titleLarge),
                            Text('${status.hostname}:${status.port}',
                                style:
                                    Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _InfoRow('Bind address', status.host),
              _InfoRow('HTTP port', '${status.port}'),
              if (status.https) _InfoRow('HTTPS port', '${status.httpsPort}'),
              _InfoRow('Active connections', '${status.activeConnections}'),
              if (status.startedAt != null)
                _InfoRow('Started', _fmt(status.startedAt!)),
              if (status.urls.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Access URLs',
                    style: Theme.of(context).textTheme.labelLarge),
                for (final u in status.urls)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.link, size: 18),
                    title: Text(u),
                  ),
              ],
              const SizedBox(height: 20),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else
                Column(
                  children: [
                    if (!status.running)
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start server'),
                        onPressed: () =>
                            _act('Start', () => repo.startServer().then((_) {})),
                      ),
                    if (status.running) ...[
                      FilledButton.icon(
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Restart server'),
                        onPressed: () => _act('Restart', repo.restartServer,
                            warnDisconnect: true),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop server'),
                        onPressed: () => _act('Stop', repo.stopServer,
                            warnDisconnect: true),
                      ),
                    ],
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  String _fmt(String iso) {
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : formatDateTime(dt.toLocal());
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Flexible(child: Text(value, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
