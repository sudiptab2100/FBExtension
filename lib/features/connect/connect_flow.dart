import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../data/models/ld_instance.dart';
import '../../state/connect_controller.dart';

/// Connects to [candidate], transparently trying **all** of its known addresses
/// (HTTPS-first, IP before `.local`) and, on a self-signed-certificate failure,
/// offering a one-tap trust prompt before retrying the encrypted endpoint.
///
/// This is the single source of truth for the connect UX so the QR scanner and
/// the manual/discovery connect screen behave identically — in particular both
/// now handle HTTPS QR codes that point at a self-signed server.
///
/// Returns `true` once a candidate connects (the router redirect then takes the
/// user onward); otherwise surfaces the last error via a snackbar and returns
/// `false`.
Future<bool> connectWithTrust(
  BuildContext context,
  WidgetRef ref,
  LdInstance candidate, {
  bool showErrorSnack = true,
}) async {
  final controller = ref.read(connectControllerProvider);
  ApiException? lastError;

  for (final base in candidate.orderedCandidates()) {
    var target = base;
    // At most two attempts per target: the plain try, then a trusted retry
    // after the user approves the self-signed certificate.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await controller.connect(target);
        return true;
      } on ApiException catch (e) {
        lastError = e;
        final untrustedHttps =
            target.isHttps && e.isNetwork && !target.trustSelfSigned;
        if (untrustedHttps) {
          if (!context.mounted) return false;
          final trust = await _askTrust(context, target);
          if (trust) {
            target = target.copyWith(trustSelfSigned: true);
            continue; // retry this same target, now trusting its cert
          }
        }
        break; // give up on this target, fall through to the next address
      }
    }
  }

  if (showErrorSnack && context.mounted && lastError != null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(lastError.message)));
  }
  return false;
}

Future<bool> _askTrust(BuildContext context, LdInstance candidate) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Untrusted certificate'),
      content: Text(
        '${candidate.host} uses a self-signed certificate. Trust it for '
        'this server and continue?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Trust & connect'),
        ),
      ],
    ),
  );
  return result ?? false;
}
