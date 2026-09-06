import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/drive_info.dart';
import 'package:localdrive_app/features/drives/request_access_sheet.dart';

DriveInfo _drive({
  DriveAccess? access = DriveAccess.none,
  bool online = true,
}) {
  return DriveInfo(
    uuid: 'u1',
    label: 'Backup SSD',
    online: online,
    registered: true,
    external: true,
    filesystem: 'APFS',
    totalBytes: 200,
    freeBytes: 50,
    access: access,
  );
}

void main() {
  group('RequestAccessSheet', () {
    testWidgets('shows the no-access copy for a none drive', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RequestAccessSheet(drive: _drive())),
      ));
      expect(find.textContaining("don't have access"), findsOneWidget);
      expect(find.textContaining('previous request was denied'), findsNothing);
      expect(find.text('Request access'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('shows the re-request copy for a denied drive', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RequestAccessSheet(drive: _drive(access: DriveAccess.denied)),
        ),
      ));
      expect(find.textContaining('previous request was denied'), findsOneWidget);
    });

    testWidgets('shows an offline note when the drive is offline',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RequestAccessSheet(drive: _drive(online: false))),
      ));
      expect(find.textContaining('offline right now'), findsOneWidget);
    });

    testWidgets('no offline note when the drive is online', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RequestAccessSheet(drive: _drive(online: true))),
      ));
      expect(find.textContaining('offline right now'), findsNothing);
    });

    testWidgets('Request access pops true', (tester) async {
      bool? popped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    popped = await RequestAccessSheet.show(context, _drive()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Request access'), findsOneWidget);
      await tester.tap(find.text('Request access'));
      await tester.pumpAndSettle();
      expect(popped, isTrue);
    });

    testWidgets('Cancel pops false', (tester) async {
      bool? popped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    popped = await RequestAccessSheet.show(context, _drive()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(popped, isFalse);
    });
  });
}
