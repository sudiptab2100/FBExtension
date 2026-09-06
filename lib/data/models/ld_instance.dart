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
    this.lastConnectedAt,
    this.trustSelfSigned = false,
  });

  final String scheme; // 'http' | 'https'
  final String host; // ip or *.local
  final int port;
  final String name; // friendly label
  final InstanceSource source;

  /// Advertised host name (e.g. "MacBook.local"), when known.
  final String? hostname;
  final String? lastConnectedAt;

  /// Whether the user approved this instance's self-signed certificate.
  final bool trustSelfSigned;

  bool get isHttps => scheme == 'https';

  String get baseUrl => '$scheme://$host:$port';

  /// Stable identity for dedupe/storage.
  String get id => '$scheme://$host:$port';

  LdInstance copyWith({
    String? name,
    String? hostname,
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
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        trustSelfSigned: trustSelfSigned ?? this.trustSelfSigned,
      );

  factory LdInstance.fromJson(Map<String, dynamic> json) => LdInstance(
        scheme: asString(json['scheme'], 'http'),
        host: asString(json['host']),
        port: asInt(json['port'], 4820),
        name: asString(json['name'], 'LocalDrive'),
        source: _sourceFrom(asStringOrNull(json['source'])),
        hostname: asStringOrNull(json['hostname']),
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
