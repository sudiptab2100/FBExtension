import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/access_request.dart';
import '../../state/api_providers.dart';
import '../../widgets/status_views.dart';

final adminAccessProvider = FutureProvider.autoDispose<List<AccessRequest>>(
  (ref) => ref.watch(adminRepositoryProvider).accessRequests(),
);

class AdminAccessScreen extends ConsumerWidget {
  const AdminAccessScreen({super.key});

  Future<void> _guard(BuildContext context, WidgetRef ref,
      Future<void> Function() action) async {
    try {
      await action();
      ref.invalidate(adminAccessProvider);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAccessProvider);
    final repo = ref.read(adminRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Access requests')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.message : e.toString(),
          onRetry: () => ref.invalidate(adminAccessProvider),
        ),
        data: (requests) {
          if (requests.isEmpty) {
            return const EmptyView(
              icon: Icons.inbox,
              message: 'No pending access requests.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(adminAccessProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: requests.length,
              itemBuilder: (_, i) {
                final r = requests[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.lock_open, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(
                                      text: r.username,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  const TextSpan(text: '  →  '),
                                  TextSpan(text: r.driveLabel),
                                ]),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: Text(
                            r.existingSpace == true
                                ? 'Will connect to existing user space'
                                : 'A new user space will be created',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => _guard(
                                  context, ref, () => repo.denyAccess(r.id)),
                              child: const Text('Deny'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () => _guard(
                                  context, ref, () => repo.approveAccess(r.id)),
                              child: const Text('Approve'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
