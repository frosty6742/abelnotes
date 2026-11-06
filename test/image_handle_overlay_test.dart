// A clicked straight arrow is selected but must still show its handles and
// action bar: the overlay draws nothing for a box under 1px, which is what a
// vertical or horizontal arrow's bounds are.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:abelnotes/features/canvas/presentation/image_handle_overlay.dart';
import 'package:abelnotes/l10n/app_localizations.dart';

Widget host(Rect bounds) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: SizedBox(
          width: 500,
          height: 500,
          child: Stack(children: [
            ImageHandleOverlay(
              bounds: bounds,
              rotation: 0,
              onMove: (_) {},
              onResize: (_) {},
              onRotate: (_) {},
              onDelete: () {},
              onDeselect: () {},
              onBlockAtEnd: () {},
            ),
          ]),
        ),
      ),
    );

void main() {
  const verticalArrow = Rect.fromLTWH(200, 200, 0, 90); // zero wide, like a drawn "down" arrow

  test('handleRect grows a flat box to a visible one around the same centre', () {
    final r = handleRect(verticalArrow);
    expect(r.center, verticalArrow.center);
    expect(r.width, 28);
    expect(r.height, 90); // already tall enough: untouched
    expect(handleRect(const Rect.fromLTWH(0, 0, 80, 60)), const Rect.fromLTWH(0, 0, 80, 60));
  });

  testWidgets('a zero-width box draws no selection UI (the bug)', (tester) async {
    await tester.pumpWidget(host(verticalArrow));
    expect(find.byTooltip("Block at the arrow's end"), findsNothing);
  });

  testWidgets('the grown box shows the action bar, including block-at-tip', (tester) async {
    await tester.pumpWidget(host(handleRect(verticalArrow)));
    expect(find.byTooltip("Block at the arrow's end"), findsOneWidget);
  });
}
