import '../../core/utils/json.dart';

/// How a server instance was discovered/added.
enum InstanceSource { manual, qr, discovered }

InstanceSource _sourceFrom(String? v) {
  switch (v) {
    case 'qr':
      return InstanceSource.qr;
    case 'discovered':
      return InstanceSource.discovered;
    default:
      return InstanceSource.manual;
  }
}

/// A LocalDrive server the app knows about (saved, discovered, or scanned).
///
/// This is an app-only model — the server has no matching type. Identity is the
/// `scheme://host:port` triple, captured in [id].
class LdInstance {
  const LdInstance({
    required this.scheme,
    required this.host,
    required this.port,
    required this.name,
    required this.source,
    this.hostname,
    this.addresses = const [],
    this.httpsPort,
    this.lastConnectedAt,
    this.trustSelfSigned = false,
  });

  final String scheme; // 'http' | 'https'
  final String host; // ip or *.local
  final int port;
  final String name; // friendly label (the device/host name when discovered)
  final InstanceSource source;

  /// Advertised host name (e.g. "MacBook.local"), when known.
  final String? hostname;

  /// All reachable addresses for this same server (every LAN IPv4 plus the
  /// `<name>.local` host). Includes [host]. Populated by LAN discovery so the
  /// UI can show every address and connecting can fall back across them.
  final List<String> addresses;

  /// The server's HTTPS port, when it advertises TLS (mDNS TXT `httpsPort` or
  /// the health status). Lets the app prefer the encrypted endpoint.
  final int? httpsPort;

  final String? lastConnectedAt;

  /// Whether the user approved this instance's self-signed certificate.
  final bool trustSelfSigned;

  bool get isHttps => scheme == 'https';

  /// True when the server also offers an HTTPS endpoint.
  bool get hasHttps => httpsPort != null && httpsPort! > 0;

  String get baseUrl => '$scheme://$host:$port';

  /// Stable identity for dedupe/storage.
  String get id => '$scheme://$host:$port';

  /// All distinct hosts known for this server, IPv4 before `.local`.
  List<String> get allHosts {
    final hosts = <String>[
      host,
      ...addresses,
      ?hostname,
    ];
    final seen = <String>{};
    final unique = hosts.where((h) => h.isNotEmpty && seen.add(h)).toList();
    unique.sort((a, b) {
      final aLocal = a.endsWith('.local');
      final bLocal = b.endsWith('.local');
      if (aLocal != bLocal) return aLocal ? 1 : -1;
      return 0;
    });
    return unique;
  }

  /// A compact, human-readable summary of every reachable address, e.g.
  /// `192.168.1.20 · mac.local`.
  String get addressSummary => allHosts.join(' · ');

  LdInstance copyWith({
    String? name,
    String? hostname,
    List<String>? addresses,
    int? httpsPort,
    String? lastConnectedAt,
    bool? trustSelfSigned,
    InstanceSource? source,
  }) =>
      LdInstance(
        scheme: scheme,
        host: host,
        port: port,
        name: name ?? this.name,
        source: source ?? this.source,
        hostname: hostname ?? this.hostname,
        addresses: addresses ?? this.addresses,
        httpsPort: httpsPort ?? this.httpsPort,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        trustSelfSigned: trustSelfSigned ?? this.trustSelfSigned,
      );

  /// Same server, different connect target (scheme/host/port). Used to build the
  /// ordered fallback candidates from [allHosts].
  LdInstance withTarget({
    required String scheme,
    required String host,
    required int port,
  }) =>
      LdInstance(
        scheme: scheme,
        host: host,
        port: port,
        name: name,
        source: source,
        hostname: hostname,
        addresses: addresses,
        httpsPort: httpsPort,
        lastConnectedAt: lastConnectedAt,
        trustSelfSigned: trustSelfSigned,
      );

  /// Connect targets to try in order: HTTPS before HTTP (when advertised), and
  /// IP addresses before `.local` names. The first that answers `/api/health`
  /// wins. De-duplicated by [id].
  List<LdInstance> orderedCandidates() {
    final out = <LdInstance>[];
    final seen = <String>{};
    void add(LdInstance c) {
      if (seen.add(c.id)) out.add(c);
    }

    // Prefer the exact endpoint this instance already points at first.
    add(this);
    // The plain-HTTP port is only known when this target is itself HTTP
    // (discovered instances keep [port] as the HTTP port); avoid inventing an
    // HTTP endpoint on a bare HTTPS URL's port.
    final httpPort = isHttps ? null : port;
    for (final h in allHosts) {
      if (hasHttps) add(withTarget(scheme: 'https', host: h, port: httpsPort!));
      if (httpPort != null) {
        add(withTarget(scheme: 'http', host: h, port: httpPort));
      }
    }
    return out;
  }

  factory LdInstance.fromJson(Map<String, dynamic> json) => LdInstance(
        scheme: asString(json['scheme'], 'http'),
        host: asString(json['host']),
        port: asInt(json['port'], 4820),
        name: asString(json['name'], 'LocalDrive'),
        source: _sourceFrom(asStringOrNull(json['source'])),
        hostname: asStringOrNull(json['hostname']),
        addresses: asStringList(json['addresses']),
        httpsPort: asIntOrNull(json['httpsPort']),
        lastConnectedAt: asStringOrNull(json['lastConnectedAt']),
        trustSelfSigned: asBool(json['trustSelfSigned']),
      );

  Map<String, dynamic> toJson() => {
        'scheme': scheme,
        'host': host,
        'port': port,
        'name': name,
        'source': source.name,
        'hostname': hostname,
        'addresses': addresses,
        'httpsPort': httpsPort,
        'lastConnectedAt': lastConnectedAt,
        'trustSelfSigned': trustSelfSigned,
      };

  /// Parse a base URL like `http://192.168.1.5:4820` into an instance.
  static LdInstance? tryParse(
    String input, {
    String? name,
    InstanceSource source = InstanceSource.manual,
  }) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme == 'https' ? 'https' : 'http';
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 4843 : 4820);
    return LdInstance(
      scheme: scheme,
      host: uri.host,
      port: port,
      name: name ?? uri.host,
      source: source,
      hostname: uri.host.endsWith('.local') ? uri.host : null,
    );
  }
}
