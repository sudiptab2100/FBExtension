import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/format.dart';
import '../../data/models/drive_info.dart';
import '../../routing/router.dart';
import '../../state/api_providers.dart';
import '../../state/session_controller.dart';
import '../../widgets/status_views.dart';

/// All registered drives with the caller's access state. Refetches when the
/// admin view mode changes so the list reflects the active scope.
final drivesListProvider = FutureProvider.autoDispose<List<DriveInfo>>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.effectiveViewMode));
  return ref.watch(drivesRepositoryProvider).list();
});

class DrivesScreen extends ConsumerStatefulWidget {
  const DrivesScreen({super.key});

  @override
  ConsumerState<DrivesScreen> createState() => _DrivesScreenState();
}

class _DrivesScreenState extends ConsumerState<DrivesScreen> {
  final _requesting = <String>{};

  Future<void> _requestAccess(DriveInfo drive) async {
    setState(() => _requesting.add(drive.uuid));
    try {
      await ref.read(drivesRepositoryProvider).requestAccess(drive.uuid);
      ref.invalidate(drivesListProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _requesting.remove(drive.uuid));
    }
  }

  void _openDrive(DriveInfo drive) {
    context.push(
      Uri(path: Routes.files, queryParameters: {
        'drive': drive.uuid,
        'path': '',
        'label': drive.label,
      }).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drivesAsync = ref.watch(drivesListProvider);
    final session = ref.watch(sessionControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drives'),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push(Routes.search),
          ),
          if (session.isAdmin) ...[
            _ViewModeButton(
              mode: session.viewMode,
              onChanged: (m) async {
                await ref
                    .read(sessionControllerProvider.notifier)
                    .setViewMode(m);
                ref.invalidate(drivesListProvider);
              },
            ),
            IconButton(
              tooltip: 'Admin console',
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: () => context.push(Routes.admin),
            ),
          ],
        ],
      ),
      body: drivesAsync.when(
        loading: () => const LoadingView(label: 'Loading drives…'),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(drivesListProvider),
        ),
        data: (drives) {
          if (drives.isEmpty) {
            return const EmptyView(
              icon: Icons.storage_outlined,
              message:
                  'No drives have been shared yet.\nAsk the server admin to '
                  'share a drive.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(drivesListProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: drives.length,
              itemBuilder: (_, i) => _DriveCard(
                drive: drives[i],
                requesting: _requesting.contains(drives[i].uuid),
                onOpen: () => _openDrive(drives[i]),
                onRequest: () => _requestAccess(drives[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ViewModeButton extends StatelessWidget {
  const _ViewModeButton({required this.mode, required this.onChanged});
  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'View mode',
      icon: Icon(mode == ViewCookie.admin
          ? Icons.groups_outlined
          : Icons.person_outline),
      onSelected: onChanged,
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: ViewCookie.admin,
          checked: mode == ViewCookie.admin,
          child: const Text("All users' spaces"),
        ),
        CheckedPopupMenuItem(
          value: ViewCookie.user,
          checked: mode == ViewCookie.user,
          child: const Text('My space only'),
        ),
      ],
    );
  }
}

class _DriveCard extends StatelessWidget {
  const _DriveCard({
    required this.drive,
    required this.requesting,
    required this.onOpen,
    required this.onRequest,
  });

  final DriveInfo drive;
  final bool requesting;
  final VoidCallback onOpen;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = drive.isGranted;
    final subtitle = [
      if (drive.filesystem != null) drive.filesystem!,
      if (drive.totalBytes != null)
        '${formatBytes(drive.usedBytes)} / ${formatBytes(drive.totalBytes)}',
      if (!drive.online) 'Offline',
    ].join(' · ');

    return Card(
      child: InkWell(
        onTap: granted && drive.online ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    drive.external ? Icons.usb : Icons.storage,
                    color: drive.online ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(drive.label,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis),
                        if (subtitle.isNotEmpty)
                          Text(subtitle,
                              style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  _AccessTrailing(
                    drive: drive,
                    requesting: requesting,
                    onOpen: onOpen,
                    onRequest: onRequest,
                  ),
                ],
              ),
              if (drive.usedFraction != null) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: drive.usedFraction,
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AccessTrailing extends StatelessWidget {
  const _AccessTrailing({
    required this.drive,
    required this.requesting,
    required this.onOpen,
    required this.onRequest,
  });

  final DriveInfo drive;
  final bool requesting;
  final VoidCallback onOpen;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    if (requesting) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    switch (drive.access) {
      case DriveAccess.granted:
        return const Icon(Icons.chevron_right);
      case DriveAccess.pending:
        return const Chip(
          label: Text('Pending'),
          visualDensity: VisualDensity.compact,
        );
      case DriveAccess.denied:
      case DriveAccess.none:
      case null:
        return FilledButton.tonal(
          onPressed: onRequest,
          child: const Text('Request'),
        );
    }
  }
}
