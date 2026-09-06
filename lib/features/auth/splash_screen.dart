import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_controller.dart';
import '../../state/session_controller.dart';

/// Shown while the saved session is being restored for the active instance.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeInstanceProvider);
    final session = ref.watch(sessionControllerProvider);
    final hasError = session.message != null &&
        session.status != SessionStatus.authenticated;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_sync,
                  size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('LocalDrive',
                  style: Theme.of(context).textTheme.headlineSmall),
              if (active != null) ...[
                const SizedBox(height: 4),
                Text(active.name,
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
              const SizedBox(height: 28),
              if (hasError) ...[
                Text(session.message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () =>
                      ref.read(sessionControllerProvider.notifier).retry(),
                  child: const Text('Retry'),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(connectionControllerProvider.notifier)
                      .setActive(null),
                  child: const Text('Choose another server'),
                ),
              ] else
                const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
