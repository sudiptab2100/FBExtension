import 'package:flutter/material.dart';

import '../../core/utils/format.dart';
import '../../data/models/drive_info.dart';

/// Bottom-sheet shown when a user taps a drive they don't have access to.
/// Presents the drive's details and lets them confirm a request for access.
///
/// Pure UI: it performs no network calls. It pops `true` when the user confirms
/// and `false` (or `null`) when they cancel, so the caller owns the actual
/// request, loading state and feedback.
class RequestAccessSheet extends StatelessWidget {
  const RequestAccessSheet({super.key, required this.drive});

  final DriveInfo drive;

  static Future<bool?> show(BuildContext context, DriveInfo drive) {
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => RequestAccessSheet(drive: drive),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final denied = drive.access == DriveAccess.denied;

    final details = [
      drive.external ? 'External drive' : 'Internal drive',
      if (drive.filesystem != null) drive.filesystem!,
      if (drive.totalBytes != null)
        '${formatBytes(drive.usedBytes)} / ${formatBytes(drive.totalBytes)}',
    ].join(' · ');

    final body = denied
        ? 'Your previous request was denied. You can request access again — '
            'the server admin will be notified.'
        : "You don't have access to this drive yet. Request access and the "
            'server admin can approve it.';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                  child: Text(
                    drive.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(details, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Text(body, style: theme.textTheme.bodyMedium),
            if (!drive.online) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.cloud_off_outlined,
                      size: 18, color: scheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This drive is offline right now. Your request is still '
                      'recorded and applies once it reconnects.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: const Text('Request access'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
