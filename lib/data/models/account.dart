import '../../core/utils/json.dart';
import 'user.dart';

/// A signed-in account remembered for a server instance. The app keeps a token
/// per (instance, username) so several users can stay signed in on the same
/// server and switch between them without re-entering passwords.
class Account {
  const Account({
    required this.username,
    required this.role,
    required this.addedAt,
    this.displayName,
  });

  final String username;
  final UserRole role;
  final String addedAt;

  /// Optional friendly name; falls back to [username].
  final String? displayName;

  bool get isAdmin => role == UserRole.admin;
  String get label => (displayName?.isNotEmpty == true) ? displayName! : username;

  factory Account.fromUser(AppUser u) => Account(
        username: u.username,
        role: u.role,
        addedAt: DateTime.now().toIso8601String(),
      );

  Account copyWith({UserRole? role, String? displayName}) => Account(
        username: username,
        role: role ?? this.role,
        addedAt: addedAt,
        displayName: displayName ?? this.displayName,
      );

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        username: asString(json['username']),
        role: AppUser.roleFromString(asStringOrNull(json['role'])),
        addedAt: asString(json['addedAt']),
        displayName: asStringOrNull(json['displayName']),
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'role': role.name,
        'addedAt': addedAt,
        'displayName': displayName,
      };
}
