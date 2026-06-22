import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:js_racer/racer_game.dart';

/// Start the countdown and advance past 3-2-1-GO so the game is racing.
void beginRace(RacerGame game) {
  game.startCountdown();
  for (var i = 0; i < 250; i++) {
    game.update(kStep); // ~4.1s, longer than the 3.7s countdown
    if (game.state == RaceState.racing) break;
  }
}

void main() {
  test('road builds with traffic', () {
    final game = RacerGame();
    expect(game.segments.length, greaterThan(500));
    expect(game.cars.length, 200);
    expect(game.trackLength, game.segments.length * kSegmentLength);
  });

  test('starts on the title screen', () {
    final game = RacerGame();
    expect(game.state, RaceState.title);
  });

  test('countdown leads into racing with a full clock', () {
    final game = RacerGame();
    game.startCountdown();
    expect(game.state, RaceState.countdown);
    expect(game.countdownLabel, '3');
    beginRace(game);
    expect(game.state, RaceState.racing);
    expect(game.timeLeft, kInitialTime);
    expect(game.totalTime, lessThan(0.1));
  });

  test('update advances position and respects max speed', () {
    final game = RacerGame();
    beginRace(game);
    game.keyFaster = true;
    for (var i = 0; i < 600; i++) {
      game.update(kStep);
    }
    expect(game.position, greaterThan(0));
    expect(game.speed, lessThanOrEqualTo(kMaxSpeed));
    expect(game.speed, greaterThan(0));
  });

  test('runs out of time -> game over (Out Run style countdown)', () {
    final game = RacerGame();
    beginRace(game);
    // sit still: never reach a checkpoint, so the clock just drains
    for (var i = 0; i < (kInitialTime * kFps).ceil() + 60; i++) {
      game.update(kStep);
    }
    expect(game.state, RaceState.timeUp);
    expect(game.timeLeft, 0);
  });

  test('crossing a checkpoint extends the clock', () {
    final game = RacerGame();
    beginRace(game);
    final before = game.timeLeft;
    game.position = game.trackLength / (kNumCheckpoints + 1) - 10;
    game.speed = kMaxSpeed * 0.5;
    game.keyFaster = true;
    for (var i = 0; i < 30; i++) {
      game.update(kStep);
    }
    expect(game.checkpointsHit, greaterThanOrEqualTo(1));
    expect(game.timeLeft, greaterThan(before));
  });

  test('reaching the end finishes the race and records best time', () {
    final game = RacerGame();
    beginRace(game);
    game.position = game.finishZ - 10; // right at the finish line
    game.speed = kMaxSpeed;
    game.update(kStep);
    expect(game.state, RaceState.finished);
    expect(game.bestTime, greaterThan(0));
  });

  test('restart re-runs the countdown', () {
    final game = RacerGame();
    beginRace(game);
    game.position = game.finishZ - 10;
    game.speed = kMaxSpeed;
    game.update(kStep);
    expect(game.state, RaceState.finished);
    game.restart();
    expect(game.state, RaceState.countdown);
    expect(game.position, 0);
    expect(game.timeLeft, kInitialTime);
    expect(game.checkpointsHit, 0);
  });

  testWidgets('RacerScreen renders', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: RacerScreen()));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(RacerScreen), findsOneWidget);
  });
}
