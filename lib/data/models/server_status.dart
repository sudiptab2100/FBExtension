import '../../core/utils/json.dart';

/// Runtime server status, mirroring the server's `ServerStatus`.
class ServerStatus {
  const ServerStatus({
    required this.running,
    required this.port,
    required this.host,
    required this.hostname,
    required this.urls,
    required this.startedAt,
    required this.activeConnections,
    required this.https,
    required this.httpsPort,
  });

  final bool running;
  final int port;
  final String host;
  final String hostname;
  final List<String> urls;
  final String? startedAt;
  final int activeConnections;
  final bool https;
  final int httpsPort;

  factory ServerStatus.fromJson(Map<String, dynamic> json) => ServerStatus(
        running: asBool(json['running']),
        port: asInt(json['port']),
        host: asString(json['host']),
        hostname: asString(json['hostname']),
        urls: asStringList(json['urls']),
        startedAt: asStringOrNull(json['startedAt']),
        activeConnections: asInt(json['activeConnections']),
        https: asBool(json['https']),
        httpsPort: asInt(json['httpsPort']),
      );
}
