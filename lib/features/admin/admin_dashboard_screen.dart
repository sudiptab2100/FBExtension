import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/utils/format.dart';
import '../../core/utils/json.dart';
import '../../routing/router.dart';
import '../../state/api_providers.dart';
import '../../widgets/status_views.dart';

/// Admin console home: key metrics plus navigation into the management screens.
final adminDashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(adminRepositoryProvider).dashboard(),
);

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminDashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Admin console')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(adminDashboardProvider),
        ),
        data: (data) {
          final transfers = asMap(data['transfers']);
          final server = asMap(data['server']);
          final drives = (data['drives'] as List? ?? const []);
          final running = asBool(server['running']);

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(adminDashboardProvider),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _StatusBanner(running: running, server: server),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.5,
                  children: [
                    _MetricCard(
                      icon: Icons.group,
                      label: 'Users',
                      value: '${asInt(data['usersCount'])}',
                    ),
                    _MetricCard(
                      icon: Icons.storage,
                      label: 'Drives',
                      value: '${drives.length}',
                    ),
                    _MetricCard(
                      icon: Icons.upload,
                      label: 'Uploads',
                      value: '${asInt(transfers['uploads'])}',
                    ),
                    _MetricCard(
                      icon: Icons.download,
                      label: 'Downloads',
                      value: '${asInt(transfers['downloads'])}',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _TransferRow(
                  inBytes: asInt(transfers['bytesIn']),
                  outBytes: asInt(transfers['bytesOut']),
                ),
                const SizedBox(height: 12),
                _NavCard(
                  icon: Icons.manage_accounts,
                  title: 'Users & permissions',
                  subtitle: 'Approve, create, and manage accounts',
                  onTap: () => context.push(Routes.adminUsers),
                ),
                _NavCard(
                  icon: Icons.lock_open,
                  title: 'Access requests',
                  subtitle: 'Approve per-drive access',
                  onTap: () => context.push(Routes.adminAccess),
                ),
                _NavCard(
                  icon: Icons.tune,
                  title: 'Configuration',
                  subtitle: 'Ports, HTTPS, registration & approvals',
                  onTap: () => context.push(Routes.adminConfig),
                ),
                _NavCard(
                  icon: Icons.dns,
                  title: 'Server control',
                  subtitle: 'Start, stop, or restart the server',
                  onTap: () => context.push(Routes.adminServer),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.running, required this.server});
  final bool running;
  final Map<String, dynamic> server;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = running ? Colors.green : scheme.error;
    final host = asString(server['hostname'], asString(server['host']));
    final port = asInt(server['port']);
    return Card(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(running ? Icons.check_circle : Icons.cancel, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(running ? 'Server running' : 'Server stopped',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (running)
                    Text('$host:$port',
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const Spacer(),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.inBytes, required this.outBytes});
  final int inBytes;
  final int outBytes;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Row(children: [
                const Icon(Icons.south, size: 18),
                const SizedBox(width: 8),
                Text('In ${formatBytes(inBytes)}'),
              ]),
            ),
            Expanded(
              child: Row(children: [
                const Icon(Icons.north, size: 18),
                const SizedBox(width: 8),
                Text('Out ${formatBytes(outBytes)}'),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
