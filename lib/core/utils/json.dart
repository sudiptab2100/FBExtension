/// Small, null-safe JSON coercion helpers shared by the data models.
///
/// The server sends numbers as JSON numbers (which decode to `int` or `double`
/// in Dart depending on the value), so these helpers normalise them defensively.
library;

int? asIntOrNull(dynamic v) => v == null ? null : (v as num).toInt();

int asInt(dynamic v, [int def = 0]) => v == null ? def : (v as num).toInt();

double asDouble(dynamic v, [double def = 0]) =>
    v == null ? def : (v as num).toDouble();

bool asBool(dynamic v, [bool def = false]) {
  if (v is bool) return v;
  if (v == null) return def;
  if (v is num) return v != 0;
  final s = v.toString().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

String? asStringOrNull(dynamic v) => v?.toString();

String asString(dynamic v, [String def = '']) => v?.toString() ?? def;

List<String> asStringList(dynamic v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const [];
}

/// A null-safe map coercion for nested JSON objects.
Map<String, dynamic> asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return <String, dynamic>{};
}
