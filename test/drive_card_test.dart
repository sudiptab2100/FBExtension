import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/theme.dart';
import 'package:localdrive_app/data/models/drive_info.dart';
import 'package:localdrive_app/features/drives/drives_screen.dart';

const _longLabel =
    'MyExtremelyLongDriveNameWithoutAnySpacesThatUsedToWrapOneCharacterPerLine';

DriveInfo _drive(DriveAccess? access) => DriveInfo(
      uuid: 'u1',
      label: _longLabel,
      online: true,
      registered: true,
      external: true,
      filesystem: 'APFS',
      totalBytes: 200,
      freeBytes: 50,
      access: access,
    );

Widget _host(DriveInfo drive, {double width = 320}) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: DriveCard(
              drive: drive,
              requesting: false,
              onTap: () {},
              onRequest: () {},
            ),
          ),
        ),
      ),
    );

void main() {
  group('DriveCard', () {
    testWidgets('long label never overflows and stays a single line',
        (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.none)));
      expect(tester.takeException(), isNull);

      final title = tester.widget<Text>(find.text(_longLabel));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('subtitle is capped to two lines', (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.none)));
      final subtitle = tester.widget<Text>(find.textContaining('APFS'));
      expect(subtitle.maxLines, 2);
      expect(subtitle.overflow, TextOverflow.ellipsis);
    });

    testWidgets('none access shows a Request access button', (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.none)));
      expect(find.text('Request access'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('denied access shows a Request again button', (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.denied)));
      expect(find.text('Request again'), findsOneWidget);
    });

    testWidgets('granted access shows a chevron and no request button',
        (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.granted)));
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.text('Request access'), findsNothing);
      expect(find.text('Request again'), findsNothing);
    });

    testWidgets('pending access shows a Pending chip and no request button',
        (tester) async {
      await tester.pumpWidget(_host(_drive(DriveAccess.pending)));
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Request access'), findsNothing);
    });

    testWidgets(
        'renders the request button under the real app theme at a narrow '
        'width (regression: infinite-width crash)', (tester) async {
      for (final access in [DriveAccess.none, DriveAccess.denied]) {
        await tester.pumpWidget(_host(_drive(access), width: 200));
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            access == DriveAccess.denied ? 'Request again' : 'Request access',
          ),
          findsOneWidget,
        );
      }
    });
  });
}
