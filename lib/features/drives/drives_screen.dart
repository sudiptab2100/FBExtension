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
import '../auth/account_switcher.dart';
import 'request_access_sheet.dart';

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
      final access =
          await ref.read(drivesRepositoryProvider).requestAccess(drive.uuid);
      ref.invalidate(drivesListProvider);
      if (mounted) {
        final msg = switch (access) {
          DriveAccess.granted => 'Access granted to “${drive.label}”.',
          DriveAccess.pending =>
            'Request sent — waiting for admin approval.',
          DriveAccess.denied => 'Your request was denied by the admin.',
          DriveAccess.none => 'Request submitted.',
        };
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      // Never leave the tap silent — surface an unexpected failure too.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not request access. Please try again.')),
        );
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

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Routes a tap on a drive card based on the caller's access. Drives the user
  /// can open are opened; otherwise we surface status or offer to request
  /// access — so tapping a locked drive is never a dead end.
  void _onTapDrive(DriveInfo drive) {
    switch (drive.access) {
      case DriveAccess.granted:
        if (drive.online) {
          _openDrive(drive);
        } else {
          _showInfo('“${drive.label}” is offline.');
        }
      case DriveAccess.pending:
        _showInfo('Waiting for admin approval of your access request.');
      case DriveAccess.denied:
      case DriveAccess.none:
      case null:
        _promptRequestAccess(drive);
    }
  }

  Future<void> _promptRequestAccess(DriveInfo drive) async {
    final confirmed = await RequestAccessSheet.show(context, drive);
    if (confirmed == true) await _requestAccess(drive);
  }

  @override
  Widget build(BuildContext context) {
    final drivesAsync = ref.watch(drivesListProvider);
    final session = ref.watch(sessionControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const AccountSwitchButton(),
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
              itemBuilder: (_, i) => DriveCard(
                drive: drives[i],
                requesting: _requesting.contains(drives[i].uuid),
                onTap: () => _onTapDrive(drives[i]),
                onRequest: () => _promptRequestAccess(drives[i]),
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

class DriveCard extends StatelessWidget {
  const DriveCard({
    super.key,
    required this.drive,
    required this.requesting,
    required this.onTap,
    required this.onRequest,
  });

  final DriveInfo drive;
  final bool requesting;

  /// Tapping anywhere on the card. The screen decides what to do based on the
  /// caller's access (open / show status / offer to request access).
  final VoidCallback onTap;

  /// Explicit "request access" affordance for drives the user can't open yet.
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subtitle = [
      if (drive.filesystem != null) drive.filesystem!,
      if (drive.totalBytes != null)
        '${formatBytes(drive.usedBytes)} / ${formatBytes(drive.totalBytes)}',
      if (!drive.online) 'Offline',
    ].join(' · ');
    final requestable = drive.access == DriveAccess.denied ||
        drive.access == DriveAccess.none ||
        drive.access == null;

    return Card(
      child: InkWell(
        onTap: onTap,
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
                        Text(
                          drive.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _AccessStatus(drive: drive),
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
              if (requestable) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: requesting ? null : onRequest,
                    icon: requesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_outlined, size: 18),
                    label: Text(
                      drive.access == DriveAccess.denied
                          ? 'Request again'
                          : 'Request access',
                    ),
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

/// Compact trailing indicator for a drive card. Intentionally small so it never
/// squeezes the drive name — the request action lives on its own row below.
class _AccessStatus extends StatelessWidget {
  const _AccessStatus({required this.drive});

  final DriveInfo drive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
        return Icon(Icons.lock_outline, color: scheme.outline);
    }
  }
}
