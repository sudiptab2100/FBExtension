import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../../core/config/constants.dart';
import '../models/ld_instance.dart';

/// Browses the LAN via mDNS/Bonjour (native NSD) for LocalDrive servers.
///
/// Two service types are watched: the dedicated `_localdrive._tcp` (advertised
/// by newer servers) and the generic `_http._tcp` filtered by the advertised
/// name "LocalDrive". Results are merged and de-duplicated by base URL.
class DiscoveryService {
  DiscoveryService();

  final _controller = StreamController<List<LdInstance>>.broadcast();
  final _byId = <String, LdInstance>{};
  nsd.Discovery? _localdrive;
  nsd.Discovery? _http;

  Stream<List<LdInstance>> get stream => _controller.stream;

  Future<void> start() async {
    await stop();
    _byId.clear();
    try {
      _localdrive = await nsd.startDiscovery(
        Discovery.serviceType,
        ipLookupType: nsd.IpLookupType.v4,
      );
      _localdrive!.addListener(
        () => _ingest(_localdrive!.services, dedicated: true),
      );
    } catch (_) {
      // The dedicated type may be unsupported on older servers; ignore.
    }
    try {
      _http = await nsd.startDiscovery(
        Discovery.httpServiceType,
        ipLookupType: nsd.IpLookupType.v4,
      );
      _http!.addListener(() => _ingest(_http!.services, dedicated: false));
    } catch (_) {
      // mDNS is best-effort; discovery simply yields nothing on failure.
    }
  }

  void _ingest(List<nsd.Service> services, {required bool dedicated}) {
    for (final s in services) {
      final inst = _toInstance(s, dedicated: dedicated);
      if (inst != null) _byId[inst.id] = inst;
    }
    if (!_controller.isClosed) {
      _controller.add(_byId.values.toList(growable: false));
    }
  }

  LdInstance? _toInstance(nsd.Service s, {required bool dedicated}) {
    final port = s.port;
    if (port == null) return null;

    // Restrict generic HTTP hits to LocalDrive by its advertised name.
    if (!dedicated) {
      final name = (s.name ?? '').toLowerCase();
      if (!name.contains('localdrive')) return null;
    }

    // Prefer a resolved IPv4 address; fall back to the .local hostname.
    String? host;
    final addrs = s.addresses;
    if (addrs != null && addrs.isNotEmpty) {
      final v4 = addrs.firstWhere(
        (a) => a.type == InternetAddressType.IPv4,
        orElse: () => addrs.first,
      );
      host = v4.address;
    } else {
      host = s.host;
    }
    if (host == null || host.isEmpty) return null;

    final hostname = s.host;
    final label = (s.name != null && s.name!.isNotEmpty)
        ? s.name!
        : (hostname ?? host);

    return LdInstance(
      scheme: 'http',
      host: host,
      port: port,
      name: label,
      source: InstanceSource.discovered,
      hostname:
          hostname != null && hostname.endsWith('.local') ? hostname : null,
    );
  }

  Future<void> stop() async {
    final d1 = _localdrive;
    final d2 = _http;
    _localdrive = null;
    _http = null;
    if (d1 != null) {
      try {
        await nsd.stopDiscovery(d1);
      } catch (_) {}
    }
    if (d2 != null) {
      try {
        await nsd.stopDiscovery(d2);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}

/// Live LAN discovery results. Auto-disposes (and stops mDNS browsing) when the
/// connect screen is no longer listening.
final discoveredInstancesProvider =
    StreamProvider.autoDispose<List<LdInstance>>((ref) async* {
  final svc = DiscoveryService();
  ref.onDispose(svc.dispose);
  yield const <LdInstance>[];
  await svc.start();
  yield* svc.stream;
});
