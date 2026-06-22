import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:js_racer/racer_game.dart';

void main() {
  test('road builds with traffic', () {
    final game = RacerGame();
    expect(game.segments.length, greaterThan(500));
    expect(game.cars.length, 200);
    expect(game.trackLength, game.segments.length * kSegmentLength);
  });

  test('update advances position and respects max speed', () {
    final game = RacerGame();
    game.keyFaster = true;
    for (var i = 0; i < 600; i++) {
      game.update(kStep);
    }
    expect(game.position, greaterThan(0));
    expect(game.speed, lessThanOrEqualTo(kMaxSpeed));
    expect(game.speed, greaterThan(0));
  });

  testWidgets('RacerScreen renders', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RacerScreen()));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(RacerScreen), findsOneWidget);
  });
}
