import '../../core/utils/json.dart';

/// Response of `GET /api/connect`: connection info + a QR data URL.
class ConnectInfo {
  const ConnectInfo({
    required this.urls,
    required this.hostname,
    required this.qr,
    required this.addresses,
    required this.httpsEnabled,
    required this.port,
    required this.httpsPort,
  });

  final List<String> urls;
  final String hostname;

  /// A `data:image/png;base64,...` QR of the primary URL.
  final String qr;

  /// LAN IPv4 addresses of the host.
  final List<String> addresses;
  final bool httpsEnabled;
  final int port;
  final int httpsPort;

  factory ConnectInfo.fromJson(Map<String, dynamic> json) => ConnectInfo(
        urls: asStringList(json['urls']),
        hostname: asString(json['hostname']),
        qr: asString(json['qr']),
        addresses: asStringList(json['addresses']),
        httpsEnabled: asBool(json['httpsEnabled']),
        port: asInt(json['port'], 4820),
        httpsPort: asInt(json['httpsPort'], 4843),
      );
}
