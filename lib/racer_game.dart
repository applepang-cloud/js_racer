import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'engine_audio.dart';

/// A Flutter (CustomPaint) port of Jake Gordon's javascript-racer, extended
/// with an Out Run-style timed race: a finite track with a start and finish,
/// a countdown clock, and checkpoints that extend your time.
/// https://github.com/jakesgordon/javascript-racer/

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const double kFps = 60;
const double kStep = 1 / kFps;
const int kSegmentLength = 200;
const int kRumbleLength = 3;
const double kRoadWidth = 2000;
const int kLanes = 3;
const double kFieldOfView = 100;
const double kCameraHeight = 1000;
const int kDrawDistance = 300;
const double kFogDensity = 5;
const double kCentrifugal = 0.3;

final double kCameraDepth = 1 / math.tan((kFieldOfView / 2) * math.pi / 180);
final double kPlayerZ = kCameraHeight * kCameraDepth;

const double kMaxSpeed = kSegmentLength / kStep; // 12000
final double kAccel = kMaxSpeed / 5;
final double kBreaking = -kMaxSpeed;
final double kDecel = -kMaxSpeed / 5;
final double kOffRoadDecel = -kMaxSpeed / 2;
final double kOffRoadLimit = kMaxSpeed / 4;

const double kSpriteScale = 0.3 / 80.0;

const double kSkySpeed = 0.001;
const double kHillSpeed = 0.002;
const double kTreeSpeed = 0.003;

// Out Run-style timing
const double kInitialTime = 40; // seconds on the clock at the start line
const double kCheckpointBonus = 25; // seconds added per checkpoint
const int kNumCheckpoints = 4;

const String kMusicUrl = 'assets/assets/racer.mp3';

enum RaceState { title, countdown, racing, finished, timeUp }

// ---------------------------------------------------------------------------
// Sprite atlas — exact coordinates from the original common.js
// ---------------------------------------------------------------------------
class Atlas {
  static final palmTree = const Rect.fromLTWH(5, 5, 215, 540);
  static final billboard08 = const Rect.fromLTWH(230, 5, 385, 265);
  static final tree1 = const Rect.fromLTWH(625, 5, 360, 360);
  static final deadTree1 = const Rect.fromLTWH(5, 555, 135, 332);
  static final billboard09 = const Rect.fromLTWH(150, 555, 328, 282);
  static final boulder3 = const Rect.fromLTWH(230, 280, 320, 220);
  static final column = const Rect.fromLTWH(995, 5, 200, 315);
  static final billboard01 = const Rect.fromLTWH(625, 375, 300, 170);
  static final billboard06 = const Rect.fromLTWH(488, 555, 298, 190);
  static final billboard05 = const Rect.fromLTWH(5, 897, 298, 190);
  static final billboard07 = const Rect.fromLTWH(313, 897, 298, 190);
  static final boulder2 = const Rect.fromLTWH(621, 897, 298, 140);
  static final tree2 = const Rect.fromLTWH(1205, 5, 282, 295);
  static final billboard04 = const Rect.fromLTWH(1205, 310, 268, 170);
  static final deadTree2 = const Rect.fromLTWH(1205, 490, 150, 260);
  static final boulder1 = const Rect.fromLTWH(1205, 760, 168, 248);
  static final bush1 = const Rect.fromLTWH(5, 1097, 240, 155);
  static final cactus = const Rect.fromLTWH(929, 897, 235, 118);
  static final bush2 = const Rect.fromLTWH(255, 1097, 232, 152);
  static final billboard03 = const Rect.fromLTWH(5, 1262, 230, 220);
  static final billboard02 = const Rect.fromLTWH(245, 1262, 215, 220);
  static final stump = const Rect.fromLTWH(995, 330, 195, 140);
  static final semi = const Rect.fromLTWH(1365, 490, 122, 144);
  static final truck = const Rect.fromLTWH(1365, 644, 100, 78);
  static final car03 = const Rect.fromLTWH(1383, 760, 88, 55);
  static final car02 = const Rect.fromLTWH(1383, 825, 80, 59);
  static final car04 = const Rect.fromLTWH(1383, 894, 80, 57);
  static final car01 = const Rect.fromLTWH(1205, 1018, 80, 56);
  static final playerUphillLeft = const Rect.fromLTWH(1383, 961, 80, 45);
  static final playerUphillStraight = const Rect.fromLTWH(1295, 1018, 80, 45);
  static final playerUphillRight = const Rect.fromLTWH(1385, 1018, 80, 45);
  static final playerLeft = const Rect.fromLTWH(995, 480, 80, 41);
  static final playerStraight = const Rect.fromLTWH(1085, 480, 80, 41);
  static final playerRight = const Rect.fromLTWH(995, 531, 80, 41);

  static final billboards = [
    billboard01, billboard02, billboard03, billboard04, billboard05,
    billboard06, billboard07, billboard08, billboard09,
  ];
  static final plants = [
    tree1, tree2, deadTree1, deadTree2, palmTree, bush1, bush2, cactus,
    stump, boulder1, boulder2, boulder3,
  ];
  static final cars = [car01, car02, car03, car04, semi, truck];
}

class Bg {
  static final hills = const Rect.fromLTWH(5, 5, 1280, 480);
  static final sky = const Rect.fromLTWH(5, 495, 1280, 480);
  static final trees = const Rect.fromLTWH(5, 985, 1280, 480);
}

// ---------------------------------------------------------------------------
// Road surface colors
// ---------------------------------------------------------------------------
class RoadColors {
  final Color road, grass, rumble, lane;
  const RoadColors(this.road, this.grass, this.rumble,
      [this.lane = Colors.transparent]);
}

const kColorFog = Color(0xFF005108);
const kLight = RoadColors(
    Color(0xFF6B6B6B), Color(0xFF10AA10), Color(0xFF555555), Color(0xFFCCCCCC));
const kDark =
    RoadColors(Color(0xFF696969), Color(0xFF009A00), Color(0xFFBBBBBB));
const kStartColor = RoadColors(Colors.white, Colors.white, Colors.white);
const kFinishColor = RoadColors(Colors.black, Colors.black, Colors.black);

// ---------------------------------------------------------------------------
// Math helpers (Util in the original)
// ---------------------------------------------------------------------------
double increase(double start, double inc, double max) {
  double result = start + inc;
  while (result >= max) {
    result -= max;
  }
  while (result < 0) {
    result += max;
  }
  return result;
}

double accelerate(double v, double accel, double dt) => v + accel * dt;
double limit(double value, double lo, double hi) =>
    math.max(lo, math.min(value, hi));
double interpolate(double a, double b, double percent) => a + (b - a) * percent;
double easeIn(double a, double b, double p) => a + (b - a) * math.pow(p, 2);
double easeInOut(double a, double b, double p) =>
    a + (b - a) * (-math.cos(p * math.pi) / 2 + 0.5);
double exponentialFog(double distance, double density) =>
    1 / math.pow(math.e, distance * distance * density);
double percentRemaining(double n, int total) => (n % total) / total;

bool overlap(double x1, double w1, double x2, double w2,
    [double percent = 1.0]) {
  final half = percent / 2;
  final min1 = x1 - w1 * half;
  final max1 = x1 + w1 * half;
  final min2 = x2 - w2 * half;
  final max2 = x2 + w2 * half;
  return !((max1 < min2) || (min1 > max2));
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
class P {
  double wx = 0, wy = 0, wz = 0;
  double cx = 0, cy = 0, cz = 0;
  double sx = 0, sy = 0, sw = 0, scale = 0;
}

void project(P p, double cameraX, double cameraY, double cameraZ,
    double cameraDepth, double width, double height, double roadWidth) {
  p.cx = p.wx - cameraX;
  p.cy = p.wy - cameraY;
  p.cz = p.wz - cameraZ;
  p.scale = cameraDepth / p.cz;
  p.sx = (width / 2) + (p.scale * p.cx * width / 2);
  p.sy = (height / 2) - (p.scale * p.cy * height / 2);
  p.sw = (p.scale * roadWidth * width / 2);
}

class RoadSprite {
  final Rect src;
  final double offset;
  RoadSprite(this.src, this.offset);
}

class Car {
  double offset;
  double z;
  double speed;
  double percent = 0;
  final Rect sprite;
  Car(this.offset, this.z, this.speed, this.sprite);
}

class Segment {
  final int index;
  final P p1 = P();
  final P p2 = P();
  double curve;
  double fog = 0;
  double clip = 0;
  bool looped = false;
  RoadColors color;
  final List<RoadSprite> sprites = [];
  final List<Car> cars = [];
  Segment(this.index, this.curve, this.color);
}

// ---------------------------------------------------------------------------
// The game model
// ---------------------------------------------------------------------------
class RacerGame {
  final List<Segment> segments = [];
  final List<Car> cars = [];
  final math.Random rng = math.Random(42);

  double position = 0;
  double speed = 0;
  double playerX = 0;
  double playerY = 0;

  double skyOffset = 0;
  double hillOffset = 0;
  double treeOffset = 0;

  // race state
  RaceState state = RaceState.title;
  double timeLeft = kInitialTime;
  double totalTime = 0;
  double bestTime = 0; // fastest finish (0 = none)
  int checkpointsHit = 0;
  late List<double> _checkpointZ;
  late List<bool> _checkpointPassed;
  double flashTimer = 0;
  String flashText = '';
  double countdownTimer = 0; // 3..2..1..GO before the race starts

  /// Big label shown during the pre-race countdown.
  String get countdownLabel {
    final t = countdownTimer;
    if (t > 2.7) return '3';
    if (t > 1.7) return '2';
    if (t > 0.7) return '1';
    return 'GO!';
  }

  bool keyLeft = false, keyRight = false, keyFaster = false, keySlower = false;

  // one-shot events consumed by the view layer each frame
  bool collisionEvent = false;
  bool checkpointEvent = false;
  bool finishEvent = false;
  bool gameOverEvent = false;
  bool offRoad = false;

  int get trackLength => segments.length * kSegmentLength;
  double get finishZ => trackLength.toDouble();

  RacerGame() {
    _buildRoad();
    _resetCars();
  }

  Segment findSegment(double z) =>
      segments[(z / kSegmentLength).floor() % segments.length];

  double get lastY => segments.isEmpty ? 0 : segments.last.p2.wy;

  double _randDouble() => rng.nextDouble();
  int _randInt(int min, int max) => min + rng.nextInt(max - min + 1);
  T _randChoice<T>(List<T> list) => list[rng.nextInt(list.length)];

  void _addSegment(double curve, double y) {
    final n = segments.length;
    final color = (n ~/ kRumbleLength) % 2 == 1 ? kDark : kLight;
    final seg = Segment(n, curve, color);
    seg.p1.wz = (n * kSegmentLength).toDouble();
    seg.p1.wy = lastY;
    seg.p2.wz = ((n + 1) * kSegmentLength).toDouble();
    seg.p2.wy = y;
    segments.add(seg);
  }

  void _addRoad(int enter, int hold, int leave, double curve, double y) {
    final startY = lastY;
    final endY = startY + y * kSegmentLength;
    final total = enter + hold + leave;
    for (var n = 0; n < enter; n++) {
      _addSegment(
          easeIn(0, curve, n / enter), easeInOut(startY, endY, n / total));
    }
    for (var n = 0; n < hold; n++) {
      _addSegment(curve, easeInOut(startY, endY, (enter + n) / total));
    }
    for (var n = 0; n < leave; n++) {
      _addSegment(easeInOut(curve, 0, n / leave),
          easeInOut(startY, endY, (enter + hold + n) / total));
    }
  }

  static const lShort = 25, lMedium = 50, lLong = 100;
  static const cEasy = 2.0, cMedium = 4.0;
  static const hNone = 0.0, hLow = 20.0, hMedium = 40.0, hHigh = 60.0;

  void _addStraight([int num = lMedium]) => _addRoad(num, num, num, 0, 0);
  void _addHill([int num = lMedium, double height = hMedium]) =>
      _addRoad(num, num, num, 0, height);
  void _addCurve(
          [int num = lMedium, double curve = cMedium, double height = hNone]) =>
      _addRoad(num, num, num, curve, height);

  void _addLowRollingHills([int num = lShort, double height = hLow]) {
    _addRoad(num, num, num, 0, height / 2);
    _addRoad(num, num, num, 0, -height);
    _addRoad(num, num, num, cEasy, height);
    _addRoad(num, num, num, 0, 0);
    _addRoad(num, num, num, -cEasy, height / 2);
    _addRoad(num, num, num, 0, 0);
  }

  void _addSCurves() {
    _addRoad(lMedium, lMedium, lMedium, -cEasy, hNone);
    _addRoad(lMedium, lMedium, lMedium, cMedium, hMedium);
    _addRoad(lMedium, lMedium, lMedium, cEasy, -hLow);
    _addRoad(lMedium, lMedium, lMedium, -cEasy, hMedium);
    _addRoad(lMedium, lMedium, lMedium, -cMedium, -hMedium);
  }

  void _addBumps() {
    _addRoad(10, 10, 10, 0, 5);
    _addRoad(10, 10, 10, 0, -2);
    _addRoad(10, 10, 10, 0, -5);
    _addRoad(10, 10, 10, 0, 8);
    _addRoad(10, 10, 10, 0, 5);
    _addRoad(10, 10, 10, 0, -7);
    _addRoad(10, 10, 10, 0, 5);
    _addRoad(10, 10, 10, 0, -2);
  }

  void _addDownhillToEnd([int num = 200]) {
    _addRoad(num, num, num, -cEasy, -lastY / kSegmentLength);
  }

  void _buildRoad() {
    segments.clear();
    _addStraight(lShort);
    _addLowRollingHills();
    _addSCurves();
    _addCurve(lMedium, cMedium, hLow);
    _addBumps();
    _addLowRollingHills();
    _addCurve(lLong * 2, cMedium, hMedium);
    _addStraight();
    _addHill(lMedium, hHigh);
    _addSCurves();
    _addCurve(lLong, -cMedium, hNone);
    _addHill(lLong, hHigh);
    _addCurve(lLong, cMedium, -hLow);
    _addBumps();
    _addHill(lLong, -hMedium);
    _addStraight();
    _addSCurves();
    _addDownhillToEnd();

    _resetSprites();
    _setupCheckpoints();

    // start line (just ahead of the player) and finish line (at the very end)
    for (var n = 0; n < kRumbleLength; n++) {
      _color(2 + n, kStartColor);
      _color(segments.length - 1 - n, kFinishColor);
    }
  }

  void _color(int index, RoadColors c) {
    if (index >= 0 && index < segments.length) segments[index].color = c;
  }

  void _setupCheckpoints() {
    _checkpointZ = [];
    _checkpointPassed = [];
    for (var i = 1; i <= kNumCheckpoints; i++) {
      final z = finishZ * i / (kNumCheckpoints + 1);
      _checkpointZ.add(z);
      _checkpointPassed.add(false);
      // paint a bright gate band so the checkpoint is visible
      final idx = (z / kSegmentLength).floor();
      for (var k = 0; k < kRumbleLength; k++) {
        _color(idx + k, kStartColor);
      }
    }
  }

  void _addSprite(int index, Rect src, double offset) {
    if (index >= 0 && index < segments.length) {
      segments[index].sprites.add(RoadSprite(src, offset));
    }
  }

  void _resetSprites() {
    _addSprite(20, Atlas.billboard07, -1);
    _addSprite(40, Atlas.billboard06, -1);
    _addSprite(60, Atlas.billboard08, -1);
    _addSprite(80, Atlas.billboard09, -1);
    _addSprite(100, Atlas.billboard01, -1);
    _addSprite(120, Atlas.billboard02, -1);
    _addSprite(140, Atlas.billboard03, -1);
    _addSprite(160, Atlas.billboard04, -1);
    _addSprite(180, Atlas.billboard05, -1);

    _addSprite(240, Atlas.billboard07, -1.2);
    _addSprite(240, Atlas.billboard06, 1.2);
    _addSprite(segments.length - 25, Atlas.billboard07, -1.2);
    _addSprite(segments.length - 25, Atlas.billboard06, 1.2);

    for (var n = 10; n < 200; n += 4 + (n ~/ 100)) {
      _addSprite(n, Atlas.palmTree, 0.5 + _randDouble() * 0.5);
      _addSprite(n, Atlas.palmTree, 1 + _randDouble() * 2);
    }

    for (var n = 250; n < 1000; n += 5) {
      _addSprite(n, Atlas.column, 1.1);
      _addSprite(n + _randInt(0, 5), Atlas.tree1, -1 - (_randDouble() * 2));
      _addSprite(n + _randInt(0, 5), Atlas.tree2, -1 - (_randDouble() * 2));
    }

    for (var n = 200; n < segments.length; n += 3) {
      _addSprite(n, _randChoice(Atlas.plants),
          _randChoice([1.0, -1.0]) * (2 + _randDouble() * 5));
    }

    for (var n = 1000; n < segments.length - 50; n += 100) {
      final side = _randChoice([1.0, -1.0]);
      _addSprite(n + _randInt(0, 50), _randChoice(Atlas.billboards), -side);
      for (var i = 0; i < 20; i++) {
        final sprite = _randChoice(Atlas.plants);
        final offset = side * (1.5 + _randDouble());
        _addSprite(n + _randInt(0, 50), sprite, offset);
      }
    }
  }

  void _resetCars() {
    cars.clear();
    for (final s in segments) {
      s.cars.clear();
    }
    const totalCars = 200;
    for (var n = 0; n < totalCars; n++) {
      final offset = _randDouble() * _randChoice([-0.8, 0.8]);
      final z = (rng.nextInt(segments.length) * kSegmentLength).toDouble();
      final sprite = _randChoice(Atlas.cars);
      final speed = kMaxSpeed / 4 +
          _randDouble() * kMaxSpeed / (sprite == Atlas.semi ? 4 : 2);
      final car = Car(offset, z, speed, sprite);
      cars.add(car);
      findSegment(z).cars.add(car);
    }
  }

  // -------------------------------------------------------------------------
  // Update
  // -------------------------------------------------------------------------
  void update(double dt) {
    if (state == RaceState.title) {
      speed = 0;
      offRoad = false;
      return;
    }
    if (state == RaceState.countdown) {
      speed = 0;
      offRoad = false;
      countdownTimer -= dt;
      if (countdownTimer <= 0) {
        state = RaceState.racing;
        totalTime = 0;
        timeLeft = kInitialTime;
      }
      return;
    }
    if (state != RaceState.racing) {
      // finished / timeUp: coast to a stop; clock and inputs are frozen
      speed = limit(accelerate(speed, kDecel, dt), 0, kMaxSpeed);
      position = position + dt * speed;
      offRoad = false;
      return;
    }

    final playerSegment = findSegment(position + kPlayerZ);
    const playerW = 80 * kSpriteScale;
    final speedPercent = speed / kMaxSpeed;
    final dx = dt * 2 * speedPercent;
    final startPosition = position;

    _updateCars(dt, playerSegment, playerW);

    position = position + dt * speed; // finite track — no wrap

    if (keyLeft) {
      playerX -= dx;
    } else if (keyRight) {
      playerX += dx;
    }
    playerX -= dx * speedPercent * playerSegment.curve * kCentrifugal;

    if (keyFaster) {
      speed = accelerate(speed, kAccel, dt);
    } else if (keySlower) {
      speed = accelerate(speed, kBreaking, dt);
    } else {
      speed = accelerate(speed, kDecel, dt);
    }

    offRoad = (playerX < -1 || playerX > 1) && speed > kOffRoadLimit / 2;
    if ((playerX < -1 || playerX > 1) && speed > kOffRoadLimit) {
      speed = accelerate(speed, kOffRoadDecel, dt);
      for (final sprite in playerSegment.sprites) {
        final spriteW = sprite.src.width * kSpriteScale;
        if (overlap(
            playerX,
            playerW,
            sprite.offset + spriteW / 2 * (sprite.offset > 0 ? 1 : -1),
            spriteW)) {
          speed = kMaxSpeed / 5;
          position = playerSegment.p1.wz - kPlayerZ;
          collisionEvent = true;
          break;
        }
      }
    }

    for (final car in playerSegment.cars) {
      final carW = car.sprite.width * kSpriteScale;
      if (speed > car.speed &&
          overlap(playerX, playerW, car.offset, carW, 0.8)) {
        speed = car.speed * (car.speed / speed);
        position = increase(car.z, -kPlayerZ, trackLength.toDouble());
        collisionEvent = true;
        break;
      }
    }

    playerX = limit(playerX, -3, 3);
    speed = limit(speed, 0, kMaxSpeed);
    if (position < 0) position = 0;

    final delta = (position - startPosition) / kSegmentLength;
    skyOffset = increase(skyOffset, kSkySpeed * playerSegment.curve * delta, 1);
    hillOffset =
        increase(hillOffset, kHillSpeed * playerSegment.curve * delta, 1);
    treeOffset =
        increase(treeOffset, kTreeSpeed * playerSegment.curve * delta, 1);

    // --- timing / checkpoints / finish ---
    totalTime += dt;
    timeLeft -= dt;
    if (flashTimer > 0) flashTimer -= dt;

    for (var i = 0; i < _checkpointZ.length; i++) {
      if (!_checkpointPassed[i] && position >= _checkpointZ[i]) {
        _checkpointPassed[i] = true;
        checkpointsHit++;
        timeLeft += kCheckpointBonus;
        flashTimer = 2.0;
        flashText = 'CHECKPOINT  +${kCheckpointBonus.toInt()}s';
        checkpointEvent = true;
      }
    }

    if (position + kPlayerZ >= finishZ) {
      state = RaceState.finished;
      if (bestTime == 0 || totalTime < bestTime) bestTime = totalTime;
      finishEvent = true;
    } else if (timeLeft <= 0) {
      timeLeft = 0;
      state = RaceState.timeUp;
      gameOverEvent = true;
    }
  }

  void _updateCars(double dt, Segment playerSegment, double playerW) {
    for (final car in cars) {
      final oldSegment = findSegment(car.z);
      car.offset += _updateCarOffset(car, oldSegment, playerSegment, playerW);
      car.z = increase(car.z, dt * car.speed, trackLength.toDouble());
      car.percent = percentRemaining(car.z, kSegmentLength);
      final newSegment = findSegment(car.z);
      if (oldSegment != newSegment) {
        oldSegment.cars.remove(car);
        newSegment.cars.add(car);
      }
    }
  }

  double _updateCarOffset(
      Car car, Segment carSegment, Segment playerSegment, double playerW) {
    const lookahead = 20;
    final carW = car.sprite.width * kSpriteScale;

    if ((carSegment.index - playerSegment.index).abs() > kDrawDistance) {
      return 0;
    }

    for (var i = 1; i < lookahead; i++) {
      final segment = segments[(carSegment.index + i) % segments.length];

      if (segment == playerSegment &&
          car.speed > speed &&
          overlap(playerX, playerW, car.offset, carW, 1.2)) {
        double dir;
        if (playerX > 0.5) {
          dir = -1;
        } else if (playerX < -0.5) {
          dir = 1;
        } else {
          dir = car.offset > playerX ? 1 : -1;
        }
        return dir / i * (car.speed - speed) / kMaxSpeed;
      }

      for (final otherCar in segment.cars) {
        final otherCarW = otherCar.sprite.width * kSpriteScale;
        if (car.speed > otherCar.speed &&
            overlap(car.offset, carW, otherCar.offset, otherCarW, 1.2)) {
          final dir = otherCar.offset > car.offset ? -1 : 1;
          return dir / i * (car.speed - otherCar.speed) / kMaxSpeed;
        }
      }
    }
    if (car.offset < -0.9) return 0.1;
    if (car.offset > 0.9) return -0.1;
    return 0;
  }

  /// Reset all race variables and begin the 3-2-1-GO countdown.
  void startCountdown() {
    position = 0;
    speed = 0;
    playerX = 0;
    timeLeft = kInitialTime;
    totalTime = 0;
    checkpointsHit = 0;
    flashTimer = 0;
    flashText = '';
    for (var i = 0; i < _checkpointPassed.length; i++) {
      _checkpointPassed[i] = false;
    }
    collisionEvent = false;
    checkpointEvent = false;
    finishEvent = false;
    gameOverEvent = false;
    _resetCars();
    countdownTimer = 3.7;
    state = RaceState.countdown;
  }

  /// Restart after finishing or running out of time (re-runs the countdown).
  void restart() => startCountdown();
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------
class RacerScreen extends StatefulWidget {
  const RacerScreen({super.key});

  @override
  State<RacerScreen> createState() => _RacerScreenState();
}

class _RacerScreenState extends State<RacerScreen>
    with SingleTickerProviderStateMixin {
  final RacerGame game = RacerGame();
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _accumulator = 0;
  final FocusNode _focus = FocusNode();
  bool _audioStarted = false;
  bool _muted = false;
  String _lastCount = '';

  ui.Image? _sprites;
  ui.Image? _background;

  void _ensureAudio() {
    if (!_audioStarted) {
      _audioStarted = true;
      EngineAudio.start();
      EngineAudio.musicPlay(kMusicUrl);
      EngineAudio.musicSetMuted(_muted);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadImages();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<void> _loadImages() async {
    final s = await _loadImage('assets/sprites.png');
    final b = await _loadImage('assets/background.png');
    if (mounted) {
      setState(() {
        _sprites = s;
        _background = b;
      });
    }
  }

  Future<ui.Image> _loadImage(String path) async {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _onTick(Duration now) {
    if (_last == Duration.zero) {
      _last = now;
      return;
    }
    var frame = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (frame > 0.1) frame = 0.1;
    _accumulator += frame;
    while (_accumulator >= kStep) {
      game.update(kStep);
      _accumulator -= kStep;
    }
    if (_audioStarted) {
      EngineAudio.setRpm(game.speed / kMaxSpeed);
      EngineAudio.offroad(game.offRoad);
      if (game.collisionEvent) {
        EngineAudio.crash();
        game.collisionEvent = false;
      }
      if (game.checkpointEvent) {
        EngineAudio.sfxCheckpoint();
        game.checkpointEvent = false;
      }
      if (game.finishEvent) {
        EngineAudio.sfxFinish();
        game.finishEvent = false;
      }
      if (game.gameOverEvent) {
        EngineAudio.sfxGameOver();
        game.gameOverEvent = false;
      }
      // 3-2-1-GO beeps
      if (game.state == RaceState.countdown) {
        final label = game.countdownLabel;
        if (label != _lastCount) {
          _lastCount = label;
          if (label == 'GO!') {
            EngineAudio.sfxFinish();
          } else {
            EngineAudio.sfxCheckpoint();
          }
        }
      } else {
        _lastCount = '';
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _ensureAudio();
    game.startCountdown();
    _focus.requestFocus();
  }

  void _restart() {
    game.restart();
    _focus.requestFocus();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    EngineAudio.musicSetMuted(_muted);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    final up = event is KeyUpEvent;
    if (!down && !up) return KeyEventResult.ignored;
    if (down) _ensureAudio();
    final k = event.logicalKey;
    // any key starts the race from the title screen
    if (down && game.state == RaceState.title) {
      _start();
      return KeyEventResult.handled;
    }
    if (down &&
        k == LogicalKeyboardKey.keyR &&
        (game.state == RaceState.finished ||
            game.state == RaceState.timeUp)) {
      _restart();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      game.keyLeft = down;
    } else if (k == LogicalKeyboardKey.arrowRight) {
      game.keyRight = down;
    } else if (k == LogicalKeyboardKey.arrowUp) {
      game.keyFaster = down;
    } else if (k == LogicalKeyboardKey.arrowDown) {
      game.keySlower = down;
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final state = game.state;
    final racing = state == RaceState.racing;
    final showHud = state == RaceState.racing || state == RaceState.countdown;
    final ended =
        state == RaceState.finished || state == RaceState.timeUp;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: (_) {
            _ensureAudio();
            if (game.state == RaceState.title) game.startCountdown();
            _focus.requestFocus();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: RoadPainter(game, _sprites, _background),
                ),
              ),
              if (showHud)
                Positioned(
                    top: 0, left: 0, right: 0, child: _TopHud(game: game)),
              if (game.flashTimer > 0)
                Positioned.fill(
                  child: Align(
                    alignment: const Alignment(0, -0.35),
                    child: _Flash(text: game.flashText),
                  ),
                ),
              // mute button
              Positioned(
                top: 14,
                right: 14,
                child: GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                        _muted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                        size: 26),
                  ),
                ),
              ),
              if (racing) Positioned.fill(child: _TouchControls(game: game)),
              if (state == RaceState.title)
                Positioned.fill(child: _TitleOverlay(onStart: _start)),
              if (state == RaceState.countdown)
                Positioned.fill(child: _CountdownOverlay(game: game)),
              if (ended)
                Positioned.fill(
                  child: _EndOverlay(game: game, onRestart: _restart),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtTime(double t) {
  if (t < 0) t = 0;
  final m = t ~/ 60;
  final s = t % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(2).padLeft(5, '0')}';
}

class _TopHud extends StatelessWidget {
  final RacerGame game;
  const _TopHud({required this.game});

  @override
  Widget build(BuildContext context) {
    final kmh = (game.speed / 100).round();
    final secs = game.timeLeft.ceil();
    final low = game.timeLeft <= 10;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          // big Out Run-style countdown
          Text('TIME',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3)),
          Text('$secs',
              style: TextStyle(
                color: low ? Colors.redAccent : Colors.yellowAccent,
                fontSize: 56,
                height: 1.0,
                fontWeight: FontWeight.w900,
                shadows: const [
                  Shadow(color: Colors.black, blurRadius: 4, offset: Offset(2, 2))
                ],
              )),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(6)),
            child: DefaultTextStyle(
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()]),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('$kmh km/h',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
                const SizedBox(width: 14),
                Text('⛳ ${game.checkpointsHit}/$kNumCheckpoints'),
                const SizedBox(width: 14),
                Text('⏱ ${_fmtTime(game.totalTime)}'),
              ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Flash extends StatelessWidget {
  final String text;
  const _Flash({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.shade700.withOpacity(0.9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 1)),
    );
  }
}

class _EndOverlay extends StatelessWidget {
  final RacerGame game;
  final VoidCallback onRestart;
  const _EndOverlay({required this.game, required this.onRestart});

  @override
  Widget build(BuildContext context) {
    final finished = game.state == RaceState.finished;
    return GestureDetector(
      onTap: onRestart,
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(finished ? 'FINISH!' : 'TIME UP',
                style: TextStyle(
                    color: finished ? Colors.yellowAccent : Colors.redAccent,
                    fontSize: 64,
                    fontWeight: FontWeight.w900,
                    shadows: const [
                      Shadow(
                          color: Colors.black,
                          blurRadius: 6,
                          offset: Offset(3, 3))
                    ])),
            const SizedBox(height: 8),
            if (finished)
              Text('Your time: ${_fmtTime(game.totalTime)}',
                  style: const TextStyle(color: Colors.white, fontSize: 22)),
            if (finished && game.bestTime > 0)
              Text('Best: ${_fmtTime(game.bestTime)}',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.8), fontSize: 16)),
            if (!finished)
              Text('Checkpoints: ${game.checkpointsHit}/$kNumCheckpoints',
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 24),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30)),
              child: const Text('TAP / PRESS R TO RESTART',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TitleOverlay extends StatelessWidget {
  final VoidCallback onStart;
  const _TitleOverlay({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onStart,
      child: Container(
        color: Colors.black.withOpacity(0.45),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('JS RACER',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 72,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                  shadows: [
                    Shadow(color: Colors.black, blurRadius: 8, offset: Offset(3, 3)),
                  ],
                )),
            Text('OUT RUN MODE',
                style: TextStyle(
                    color: Colors.yellowAccent,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4, offset: Offset(2, 2)),
                    ])),
            const SizedBox(height: 40),
            _Blink(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Text('PRESS ANY KEY / TAP TO START',
                    style: TextStyle(
                        color: Colors.black,
                        fontSize: 17,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 28),
            Text('↑ accelerate   ↓ brake   ← → steer',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.85), fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// Simple fade in/out blinker for the "press start" prompt.
class _Blink extends StatefulWidget {
  final Widget child;
  const _Blink({required this.child});
  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(_c),
      child: widget.child,
    );
  }
}

class _CountdownOverlay extends StatelessWidget {
  final RacerGame game;
  const _CountdownOverlay({required this.game});

  @override
  Widget build(BuildContext context) {
    final label = game.countdownLabel;
    final go = label == 'GO!';
    return IgnorePointer(
      child: Center(
        child: Text(label,
            style: TextStyle(
              color: go ? Colors.greenAccent : Colors.white,
              fontSize: go ? 90 : 130,
              fontWeight: FontWeight.w900,
              shadows: const [
                Shadow(color: Colors.black, blurRadius: 12, offset: Offset(4, 4)),
              ],
            )),
      ),
    );
  }
}

class _TouchControls extends StatelessWidget {
  final RacerGame game;
  const _TouchControls({required this.game});

  Widget _btn(IconData icon, void Function(bool) set, Color color) {
    return Listener(
      onPointerDown: (_) => set(true),
      onPointerUp: (_) => set(false),
      onPointerCancel: (_) => set(false),
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white38, width: 2),
        ),
        child: Icon(icon, size: 40, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _btn(Icons.arrow_left, (v) => game.keyLeft = v, Colors.white24),
                const SizedBox(width: 14),
                _btn(Icons.arrow_right, (v) => game.keyRight = v,
                    Colors.white24),
              ]),
            ),
          ),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _btn(Icons.keyboard_arrow_down, (v) => game.keySlower = v,
                    Colors.white24),
                const SizedBox(width: 14),
                _btn(Icons.keyboard_arrow_up, (v) => game.keyFaster = v,
                    Colors.greenAccent.withOpacity(0.25)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------
class RoadPainter extends CustomPainter {
  final RacerGame game;
  final ui.Image? sprites;
  final ui.Image? background;
  RoadPainter(this.game, this.sprites, this.background);

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final g = game;
    final resolution = height / 480.0;

    final baseSegment = g.findSegment(g.position);
    final basePercent = percentRemaining(g.position, kSegmentLength);
    final playerSegment = g.findSegment(g.position + kPlayerZ);
    final playerPercent =
        percentRemaining(g.position + kPlayerZ, kSegmentLength);
    final playerY =
        interpolate(playerSegment.p1.wy, playerSegment.p2.wy, playerPercent);
    g.playerY = playerY;

    double maxy = height;
    double x = 0;
    double dx = -(baseSegment.curve * basePercent);

    _drawBackground(canvas, width, height, resolution, playerY);

    final paint = Paint()..isAntiAlias = false;

    for (var n = 0; n < kDrawDistance; n++) {
      final segment = g.segments[(baseSegment.index + n) % g.segments.length];
      segment.looped = segment.index < baseSegment.index;
      segment.fog = exponentialFog(n / kDrawDistance, kFogDensity);
      segment.clip = maxy;

      final camOffsetZ = g.position - (segment.looped ? g.trackLength : 0);
      project(segment.p1, (g.playerX * kRoadWidth) - x, playerY + kCameraHeight,
          camOffsetZ, kCameraDepth, width, height, kRoadWidth);
      project(segment.p2, (g.playerX * kRoadWidth) - x - dx,
          playerY + kCameraHeight, camOffsetZ, kCameraDepth, width, height,
          kRoadWidth);

      x += dx;
      dx += segment.curve;

      if (segment.p1.cz <= kCameraDepth ||
          segment.p2.sy >= segment.p1.sy ||
          segment.p2.sy >= maxy) {
        continue;
      }

      _renderSegment(canvas, paint, width, segment.p1, segment.p2, segment.fog,
          segment.color);

      maxy = segment.p2.sy;
    }

    final imgPaint = Paint()..filterQuality = FilterQuality.low;
    for (var n = kDrawDistance - 1; n > 0; n--) {
      final segment = g.segments[(baseSegment.index + n) % g.segments.length];

      for (final car in segment.cars) {
        final spriteScale =
            interpolate(segment.p1.scale, segment.p2.scale, car.percent);
        final spriteX = interpolate(segment.p1.sx, segment.p2.sx, car.percent) +
            (spriteScale * car.offset * kRoadWidth * width / 2);
        final spriteY =
            interpolate(segment.p1.sy, segment.p2.sy, car.percent);
        _renderSprite(canvas, imgPaint, width, height, car.sprite, spriteScale,
            spriteX, spriteY, -0.5, -1, segment.clip);
      }

      for (final sprite in segment.sprites) {
        final spriteScale = segment.p1.scale;
        final spriteX = segment.p1.sx +
            (spriteScale * sprite.offset * kRoadWidth * width / 2);
        final spriteY = segment.p1.sy;
        _renderSprite(canvas, imgPaint, width, height, sprite.src, spriteScale,
            spriteX, spriteY, sprite.offset < 0 ? -1 : 0, -1, segment.clip);
      }

      if (segment == playerSegment) {
        _renderPlayer(canvas, imgPaint, width, height, resolution,
            g.speed / kMaxSpeed, playerSegment, playerPercent);
      }
    }
  }

  void _drawBackground(
      Canvas canvas, double w, double h, double resolution, double playerY) {
    if (background == null) {
      canvas.drawRect(
          Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF72D7EE));
      return;
    }
    final p = Paint()..filterQuality = FilterQuality.low;
    _bgLayer(canvas, w, h, Bg.sky, game.skyOffset,
        resolution * kSkySpeed * playerY, p);
    _bgLayer(canvas, w, h, Bg.hills, game.hillOffset,
        resolution * kHillSpeed * playerY, p);
    _bgLayer(canvas, w, h, Bg.trees, game.treeOffset,
        resolution * kTreeSpeed * playerY, p);
  }

  void _bgLayer(Canvas c, double w, double h, Rect layer, double rotation,
      double offset, Paint p) {
    final imageW = layer.width / 2;
    final imageH = layer.height;
    final sourceX = layer.left + (layer.width * rotation).floorToDouble();
    final sourceY = layer.top;
    final sourceW = math.min(imageW, layer.left + layer.width - sourceX);
    final sourceH = imageH;
    final destY = offset;
    final destW = w * (sourceW / imageW);
    final destH = h;
    c.drawImageRect(
        background!,
        Rect.fromLTWH(sourceX, sourceY, sourceW, sourceH),
        Rect.fromLTWH(0, destY, destW, destH),
        p);
    if (sourceW < imageW) {
      c.drawImageRect(
          background!,
          Rect.fromLTWH(layer.left, sourceY, imageW - sourceW, sourceH),
          Rect.fromLTWH(destW - 1, destY, w - destW, destH),
          p);
    }
  }

  void _renderSegment(Canvas canvas, Paint paint, double width, P p1, P p2,
      double fog, RoadColors color) {
    final r1 = _rumbleWidth(p1.sw);
    final r2 = _rumbleWidth(p2.sw);
    final l1 = _laneMarkerWidth(p1.sw);
    final l2 = _laneMarkerWidth(p2.sw);

    paint.color = color.grass;
    canvas.drawRect(Rect.fromLTRB(0, p2.sy, width, p1.sy), paint);

    paint.color = color.rumble;
    _poly(canvas, paint, p1.sx - p1.sw - r1, p1.sy, p1.sx - p1.sw, p1.sy,
        p2.sx - p2.sw, p2.sy, p2.sx - p2.sw - r2, p2.sy);
    _poly(canvas, paint, p1.sx + p1.sw + r1, p1.sy, p1.sx + p1.sw, p1.sy,
        p2.sx + p2.sw, p2.sy, p2.sx + p2.sw + r2, p2.sy);

    paint.color = color.road;
    _poly(canvas, paint, p1.sx - p1.sw, p1.sy, p1.sx + p1.sw, p1.sy,
        p2.sx + p2.sw, p2.sy, p2.sx - p2.sw, p2.sy);

    if (color.lane != Colors.transparent) {
      paint.color = color.lane;
      final lanew1 = p1.sw * 2 / kLanes;
      final lanew2 = p2.sw * 2 / kLanes;
      var lanex1 = p1.sx - p1.sw + lanew1;
      var lanex2 = p2.sx - p2.sw + lanew2;
      for (var lane = 1; lane < kLanes; lane++) {
        _poly(canvas, paint, lanex1 - l1 / 2, p1.sy, lanex1 + l1 / 2, p1.sy,
            lanex2 + l2 / 2, p2.sy, lanex2 - l2 / 2, p2.sy);
        lanex1 += lanew1;
        lanex2 += lanew2;
      }
    }

    if (fog < 1) {
      paint.color = kColorFog.withOpacity(1 - fog);
      canvas.drawRect(Rect.fromLTRB(0, p2.sy, width, p1.sy), paint);
    }
  }

  double _rumbleWidth(double w) => w / (kLanes + 2);
  double _laneMarkerWidth(double w) => w / (kLanes * 8);

  void _poly(Canvas canvas, Paint paint, double x1, double y1, double x2,
      double y2, double x3, double y3, double x4, double y4) {
    final path = Path()
      ..moveTo(x1, y1)
      ..lineTo(x2, y2)
      ..lineTo(x3, y3)
      ..lineTo(x4, y4)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _renderSprite(Canvas canvas, Paint paint, double width, double height,
      Rect src, double scale, double destX, double destY, double offsetX,
      double offsetY, double clipY) {
    if (sprites == null) return;
    final destW = (src.width * scale * width / 2) * (kSpriteScale * kRoadWidth);
    final destH = (src.height * scale * width / 2) * (kSpriteScale * kRoadWidth);
    final dx = destX + destW * offsetX;
    final dy = destY + destH * offsetY;
    if (destW < 0.5) return;
    final clipH = clipY > 0 ? math.max(0.0, dy + destH - clipY) : 0.0;
    if (clipH >= destH) return;
    canvas.drawImageRect(
        sprites!,
        Rect.fromLTWH(
            src.left, src.top, src.width, src.height - src.height * clipH / destH),
        Rect.fromLTWH(dx, dy, destW, destH - clipH),
        paint);
  }

  void _renderPlayer(Canvas canvas, Paint paint, double width, double height,
      double resolution, double speedPercent, Segment playerSegment,
      double playerPercent) {
    final g = game;
    final bounce =
        1.5 * speedPercent * resolution * math.sin(g.position * 0.1);
    final updown = playerSegment.p2.wy - playerSegment.p1.wy;
    final steer = g.keyLeft ? -1 : (g.keyRight ? 1 : 0);

    Rect src;
    if (steer < 0) {
      src = updown > 0 ? Atlas.playerUphillLeft : Atlas.playerLeft;
    } else if (steer > 0) {
      src = updown > 0 ? Atlas.playerUphillRight : Atlas.playerRight;
    } else {
      src = updown > 0 ? Atlas.playerUphillStraight : Atlas.playerStraight;
    }

    final scale = kCameraDepth / kPlayerZ;
    final camY =
        interpolate(playerSegment.p1.cy, playerSegment.p2.cy, playerPercent);
    final destX = width / 2;
    final destY = (height / 2) - (scale * camY * height / 2) + bounce;
    _renderSprite(
        canvas, paint, width, height, src, scale, destX, destY, -0.5, -1, 0);
  }

  @override
  bool shouldRepaint(covariant RoadPainter oldDelegate) => true;
}
