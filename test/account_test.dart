import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/account.dart';
import 'package:localdrive_app/data/models/user.dart';

void main() {
  group('Account', () {
    test('fromUser copies username and role, label falls back to username', () {
      const user = AppUser(
        id: 7,
        username: 'alice',
        role: UserRole.user,
        createdAt: '2026-01-01',
        home: 'alice',
        status: UserStatus.active,
      );
      final acc = Account.fromUser(user);
      expect(acc.username, 'alice');
      expect(acc.role, UserRole.user);
      expect(acc.isAdmin, isFalse);
      expect(acc.label, 'alice');
      expect(acc.addedAt, isNotEmpty);
    });

    test('admin role flags isAdmin', () {
      const user = AppUser(
        id: 1,
        username: 'root',
        role: UserRole.admin,
        createdAt: '',
        home: '',
        status: UserStatus.active,
      );
      expect(Account.fromUser(user).isAdmin, isTrue);
    });

    test('JSON round-trips all fields', () {
      const acc = Account(
        username: 'bob',
        role: UserRole.admin,
        addedAt: '2026-02-02T00:00:00.000',
        displayName: 'Bobby',
      );
      final restored = Account.fromJson(acc.toJson());
      expect(restored.username, 'bob');
      expect(restored.role, UserRole.admin);
      expect(restored.addedAt, '2026-02-02T00:00:00.000');
      expect(restored.displayName, 'Bobby');
      expect(restored.label, 'Bobby');
    });

    test('copyWith updates role but keeps identity', () {
      const acc = Account(
        username: 'carol',
        role: UserRole.user,
        addedAt: 't',
      );
      final promoted = acc.copyWith(role: UserRole.admin);
      expect(promoted.username, 'carol');
      expect(promoted.role, UserRole.admin);
      expect(promoted.addedAt, 't');
    });
  });
}
