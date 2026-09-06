import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nsd/nsd.dart' as nsd;

import '../../core/config/constants.dart';
import '../models/ld_instance.dart';
import '../models/server_status.dart';
import '../../state/connection_controller.dart';

/// Where a discovery run currently stands, so the UI can show progress, errors
/// and a rescan affordance instead of a silent blank list.
enum DiscoveryPhase { searching, done, error }

class DiscoveryState {
  const DiscoveryState({
    this.phase = DiscoveryPhase.searching,
    this.instances = const [],
    this.error,
  });

  final DiscoveryPhase phase;
  final List<LdInstance> instances;
  final String? error;

  bool get isSearching => phase == DiscoveryPhase.searching;

  DiscoveryState copyWith({
    DiscoveryPhase? phase,
    List<LdInstance>? instances,
    String? error,
    bool clearError = false,
  }) =>
      DiscoveryState(
        phase: phase ?? this.phase,
        instances: instances ?? this.instances,
        error: clearError ? null : (error ?? this.error),
      );
}

/// De-dupes servers discovered via different transports/addresses. Two hits are
/// the same server when they share **any** reachable host (IP or `.local`).
class _MergeStore {
  final List<LdInstance> _list = [];

  void clear() => _list.clear();

  void add(LdInstance incoming) {
    final incHosts = incoming.allHosts.toSet();
    final idx =
        _list.indexWhere((e) => e.allHosts.any(incHosts.contains));
    if (idx < 0) {
      _list.add(incoming);
    } else {
      _list[idx] = _merge(_list[idx], incoming);
    }
  }

  List<LdInstance> get all => List.unmodifiable(_list);

  static LdInstance _merge(LdInstance a, LdInstance b) {
    final hosts = <String>{...a.allHosts, ...b.allHosts};
    final ipv4 = hosts.where(_isIpv4).toList();
    final local = hosts.firstWhere(
      (h) => h.endsWith('.local'),
      orElse: () => '',
    );
    final primary = ipv4.isNotEmpty ? ipv4.first : (local.isNotEmpty ? local : a.host);
    // Prefer a descriptive device name over the generic service label.
    String pickName(LdInstance x) => x.name;
    final name = a.name.toLowerCase() == 'localdrive' && b.name.isNotEmpty
        ? pickName(b)
        : pickName(a);
    return LdInstance(
      scheme: 'http',
      host: primary,
      port: a.port,
      name: name,
      source: InstanceSource.discovered,
      hostname: (a.hostname?.isNotEmpty == true) ? a.hostname : b.hostname,
      addresses: hosts.toList(),
      httpsPort: a.httpsPort ?? b.httpsPort,
      trustSelfSigned: a.trustSelfSigned || b.trustSelfSigned,
    );
  }
}

bool _isIpv4(String h) {
  final parts = h.split('.');
  if (parts.length != 4) return false;
  return parts.every((p) {
    final n = int.tryParse(p);
    return n != null && n >= 0 && n <= 255;
  });
}

/// Browses the LAN via mDNS/Bonjour (native NSD) for LocalDrive servers on both
/// the dedicated `_localdrive._tcp` type and the generic `_http._tcp` (filtered
/// by the advertised name). Emits every merged result plus any browse error.
class _MdnsBrowser {
  _MdnsBrowser({required this.onServices, required this.onError});

  final void Function(List<nsd.Service> services, bool dedicated) onServices;
  final void Function(Object error) onError;

  nsd.Discovery? _localdrive;
  nsd.Discovery? _http;

  Future<void> start() async {
    try {
      _localdrive = await nsd.startDiscovery(
        Discovery.serviceType,
        ipLookupType: nsd.IpLookupType.v4,
      );
      _localdrive!.addListener(
        () => onServices(_localdrive!.services, true),
      );
    } catch (e) {
      // The dedicated type may be unsupported on older servers; keep going but
      // remember the error in case nothing else turns up.
      onError(e);
    }
    try {
      _http = await nsd.startDiscovery(
        Discovery.httpServiceType,
        ipLookupType: nsd.IpLookupType.v4,
      );
      _http!.addListener(() => onServices(_http!.services, false));
    } catch (e) {
      onError(e);
    }
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
}

String? _txt(Map<String, dynamic>? txt, String key) {
  if (txt == null) return null;
  final v = txt[key];
  if (v == null) return null;
  if (v is String) return v;
  if (v is List<int>) {
    try {
      return utf8.decode(v);
    } catch (_) {
      return null;
    }
  }
  return v.toString();
}

/// Strip the trailing dot mDNS sometimes appends; keep only real `.local` names.
String? _localHost(String? raw) {
  if (raw == null) return null;
  var h = raw.trim();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty || _isIpv4(h)) return null;
  return h;
}

String _deviceName(String? localHost, String? serviceName) {
  if (localHost != null && localHost.isNotEmpty) {
    final base = localHost.endsWith('.local')
        ? localHost.substring(0, localHost.length - '.local'.length)
        : localHost;
    if (base.isNotEmpty) return base;
  }
  return (serviceName == null || serviceName.isEmpty) ? 'LocalDrive' : serviceName;
}

LdInstance? _fromService(nsd.Service s, {required bool dedicated}) {
  final port = s.port;
  if (port == null) return null;

  // Restrict generic HTTP hits to LocalDrive by its advertised name.
  if (!dedicated) {
    final name = (s.name ?? '').toLowerCase();
    if (!name.contains('localdrive')) return null;
  }

  final ipv4 = <String>[];
  for (final a in s.addresses ?? const <InternetAddress>[]) {
    if (a.type == InternetAddressType.IPv4 && !ipv4.contains(a.address)) {
      ipv4.add(a.address);
    }
  }
  final localHost = _localHost(s.host);
  final primary = ipv4.isNotEmpty ? ipv4.first : localHost;
  if (primary == null || primary.isEmpty) return null;

  int? httpsPort;
  final flag = _txt(s.txt, 'https');
  final hp = int.tryParse(_txt(s.txt, 'httpsPort') ?? '');
  if (hp != null && hp > 0 && (flag == '1' || flag == 'true')) {
    httpsPort = hp;
  }

  final addresses = <String>[...ipv4, ?localHost];
  return LdInstance(
    scheme: 'http',
    host: primary,
    port: port,
    name: _deviceName(localHost, s.name),
    source: InstanceSource.discovered,
    hostname: localHost,
    addresses: addresses,
    httpsPort: httpsPort,
  );
}

/// Private-LAN /24 the device itself sits on, plus its own last octet (skipped
/// while probing). Only RFC-1918 ranges are scanned, which keeps the sweep on
/// Wi-Fi/LAN and off cellular.
class _Subnet {
  const _Subnet(this.base, this.self);
  final String base; // e.g. "192.168.1"
  final int self; // own last octet
}

bool _isPrivate(String ip) {
  if (ip.startsWith('192.168.')) return true;
  if (ip.startsWith('10.')) return true;
  final m = RegExp(r'^172\.(\d+)\.').firstMatch(ip);
  if (m != null) {
    final n = int.tryParse(m.group(1)!) ?? 0;
    return n >= 16 && n <= 31;
  }
  return false;
}

/// Active fallback: unicast-probes `GET /api/health` across the device's own
/// LAN /24 so servers are still found when the router blocks mDNS multicast.
/// Enriches each hit with the device name and every address from the health
/// status (`urls`), and learns HTTPS from the status.
class SubnetScanner {
  SubnetScanner({
    this.httpPorts = const [Defaults.httpPort],
    this.httpsPorts = const [Defaults.httpsPort],
    this.concurrency = 64,
    this.timeout = const Duration(milliseconds: 500),
  });

  final List<int> httpPorts;
  final List<int> httpsPorts;
  final int concurrency;
  final Duration timeout;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<void> scan(void Function(LdInstance) onFound) async {
    final subnets = await _localSubnets();
    final targets = <_Target>[];
    for (final net in subnets) {
      for (var host = 1; host <= 254; host++) {
        if (host == net.self) continue;
        final ip = '${net.base}.$host';
        for (final p in httpPorts) {
          targets.add(_Target(ip, p, false));
        }
        for (final p in httpsPorts) {
          targets.add(_Target(ip, p, true));
        }
      }
    }
    await _pooled(targets, (t) async {
      if (_cancelled) return;
      final inst = await _probe(t);
      if (inst != null && !_cancelled) onFound(inst);
    });
  }

  Future<void> _pooled(
    List<_Target> targets,
    Future<void> Function(_Target) body,
  ) async {
    var index = 0;
    Future<void> worker() async {
      while (!_cancelled) {
        final i = index++;
        if (i >= targets.length) break;
        await body(targets[i]);
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, targets.isEmpty ? 1 : targets.length),
      (_) => worker(),
    );
    await Future.wait(workers);
  }

  Future<LdInstance?> _probe(_Target t) async {
    final client = HttpClient()..connectionTimeout = timeout;
    if (t.https) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    try {
      final scheme = t.https ? 'https' : 'http';
      final uri = Uri.parse('$scheme://${t.ip}:${t.port}/api/health');
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 1));
      final json = jsonDecode(body);
      if (json is! Map || json['ok'] != true || json['status'] is! Map) {
        return null;
      }
      final status = ServerStatus.fromJson(
        (json['status'] as Map).cast<String, dynamic>(),
      );
      return _instanceFromStatus(t, status);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  LdInstance _instanceFromStatus(_Target t, ServerStatus status) {
    // Harvest every host the server advertises so the card shows all of them.
    final ipv4 = <String>{t.ip};
    String? localHost;
    for (final u in status.urls) {
      final uri = Uri.tryParse(u);
      if (uri == null || uri.host.isEmpty) continue;
      if (_isIpv4(uri.host)) {
        ipv4.add(uri.host);
      } else if (uri.host.endsWith('.local')) {
        localHost ??= uri.host;
      }
    }
    final device = status.hostname.isNotEmpty
        ? status.hostname
        : (_deviceName(localHost, null));
    final httpsPort = t.https
        ? t.port
        : (status.https && status.httpsPort > 0 ? status.httpsPort : null);
    final addresses = <String>[...ipv4, ?localHost];
    return LdInstance(
      scheme: t.https ? 'https' : 'http',
      host: t.ip,
      port: t.port,
      name: device,
      source: InstanceSource.discovered,
      hostname: localHost,
      addresses: addresses,
      httpsPort: httpsPort,
    );
  }

  Future<List<_Subnet>> _localSubnets() async {
    final out = <_Subnet>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          if (!_isPrivate(a.address)) continue;
          final parts = a.address.split('.');
          if (parts.length != 4) continue;
          final base = '${parts[0]}.${parts[1]}.${parts[2]}';
          final self = int.tryParse(parts[3]);
          if (self == null) continue;
          if (!out.any((s) => s.base == base)) out.add(_Subnet(base, self));
        }
      }
    } catch (_) {
      // Interface enumeration can fail without permission; the mDNS path still
      // covers discovery in that case.
    }
    return out;
  }
}

class _Target {
  const _Target(this.ip, this.port, this.https);
  final String ip;
  final int port;
  final bool https;
}

/// Orchestrates mDNS browsing + the subnet-scan fallback into one merged,
/// status-bearing result set with a manual [rescan]. Auto-disposes (stopping
/// all browsing/scanning) when the connect screen stops listening.
class DiscoveryController extends Notifier<DiscoveryState> {
  final _store = _MergeStore();
  _MdnsBrowser? _mdns;
  SubnetScanner? _scanner;
  int _runId = 0;
  Object? _mdnsError;
  int _pending = 0;

  @override
  DiscoveryState build() {
    ref.onDispose(_stop);
    // React to saved-instance changes so custom ports get swept too.
    final saved = ref.watch(
      connectionControllerProvider.select((s) => s.instances),
    );
    _httpPorts = {
      Defaults.httpPort,
      ...saved.where((i) => !i.isHttps).map((i) => i.port),
    }.toList();
    _httpsPorts = {
      Defaults.httpsPort,
      ...saved.where((i) => i.isHttps).map((i) => i.port),
      ...saved.where((i) => i.hasHttps).map((i) => i.httpsPort!),
    }.toList();
    _run();
    return const DiscoveryState(phase: DiscoveryPhase.searching);
  }

  List<int> _httpPorts = const [Defaults.httpPort];
  List<int> _httpsPorts = const [Defaults.httpsPort];

  void rescan() {
    _stop();
    _store.clear();
    _run();
  }

  void _run() {
    final runId = ++_runId;
    _mdnsError = null;
    _pending = 2; // mDNS + subnet scan
    state = const DiscoveryState(phase: DiscoveryPhase.searching);

    _mdns = _MdnsBrowser(
      onServices: (services, dedicated) {
        if (runId != _runId) return;
        for (final s in services) {
          final inst = _fromService(s, dedicated: dedicated);
          if (inst != null) _store.add(inst);
        }
        _emit(runId);
      },
      onError: (e) => _mdnsError = e,
    );
    // Browsing is long-lived; mark its "startup" done shortly after it starts.
    _mdns!.start().whenComplete(() {
      Future.delayed(const Duration(seconds: 3), () => _done(runId));
    });

    _scanner = SubnetScanner(httpPorts: _httpPorts, httpsPorts: _httpsPorts);
    _scanner!.scan((inst) {
      if (runId != _runId) return;
      _store.add(inst);
      _emit(runId);
    }).whenComplete(() => _done(runId));
  }

  void _emit(int runId) {
    if (runId != _runId) return;
    state = state.copyWith(instances: _store.all, clearError: true);
  }

  void _done(int runId) {
    if (runId != _runId) return;
    if (_pending > 0) _pending--;
    if (_pending > 0) return;
    final list = _store.all;
    if (list.isEmpty && _mdnsError != null) {
      state = DiscoveryState(
        phase: DiscoveryPhase.error,
        instances: list,
        error: 'Discovery error: $_mdnsError',
      );
    } else {
      state = state.copyWith(phase: DiscoveryPhase.done, instances: list);
    }
  }

  void _stop() {
    _runId++;
    final mdns = _mdns;
    final scanner = _scanner;
    _mdns = null;
    _scanner = null;
    scanner?.cancel();
    mdns?.stop();
  }
}

/// Live LAN discovery with progress + errors + a manual rescan. Auto-disposes
/// (and stops mDNS/subnet scanning) when the connect screen is gone.
final discoveryControllerProvider =
    NotifierProvider.autoDispose<DiscoveryController, DiscoveryState>(
  DiscoveryController.new,
);
