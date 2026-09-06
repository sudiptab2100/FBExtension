import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/dio_client.dart';
import '../data/models/ld_instance.dart';
import '../data/models/server_status.dart';
import '../data/repositories/connect_repository.dart';
import 'connection_controller.dart';

/// Actions for validating and adding server instances from the connect screen.
class ConnectController {
  ConnectController(this.ref);
  final Ref ref;

  /// Health-check a candidate server with a throwaway Dio (no auth). Throws
  /// [ApiException] when unreachable or not a LocalDrive server.
  Future<ServerStatus> probe(LdInstance candidate) async {
    final dio = buildDio(
      baseUrl: candidate.baseUrl,
      token: () => null,
      trustSelfSigned: candidate.trustSelfSigned,
    );
    try {
      return await ConnectRepository(dio).health();
    } finally {
      dio.close();
    }
  }

  /// Probe then persist the instance, optionally making it active (which drives
  /// the router into the login/session flow for that server).
  Future<LdInstance> connect(
    LdInstance candidate, {
    bool activate = true,
  }) async {
    final status = await probe(candidate);
    // Adopt the server's real hostname when we only had an IP.
    final enriched = candidate.hostname == null && status.hostname.isNotEmpty
        ? candidate.copyWith(hostname: status.hostname)
        : candidate;
    return ref
        .read(connectionControllerProvider.notifier)
        .addOrUpdate(enriched, activate: activate);
  }
}

final connectControllerProvider =
    Provider<ConnectController>((ref) => ConnectController(ref));
