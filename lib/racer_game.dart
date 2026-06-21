import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'engine_audio.dart';

/// A faithful Flutter (CustomPaint) port of Jake Gordon's javascript-racer.
/// https://github.com/jakesgordon/javascript-racer/
///
/// Pseudo-3D road projection: curves, hills, rumble strips, lane markings,
/// exponential fog, parallax background, roadside sprites and traffic.

// ---------------------------------------------------------------------------
// Constants (mirrors the original game's settings)
// ---------------------------------------------------------------------------
const double kFps = 60;
const double kStep = 1 / kFps;
const int kSegmentLength = 200; // length of a single road segment
const int kRumbleLength = 3; // segments per red/white rumble strip
const double kRoadWidth = 2000; // half-width of the road
const int kLanes = 3;
const double kFieldOfView = 100; // degrees
const double kCameraHeight = 1000;
const int kDrawDistance = 300; // segments drawn ahead
const double kFogDensity = 5;
const double kCentrifugal = 0.3; // how much curves push the player sideways

final double kCameraDepth =
    1 / math.tan((kFieldOfView / 2) * math.pi / 180);
final double kPlayerZ = kCameraHeight * kCameraDepth;

const double kMaxSpeed = kSegmentLength / kStep; // 12000
final double kAccel = kMaxSpeed / 5;
final double kBreaking = -kMaxSpeed;
final double kDecel = -kMaxSpeed / 5;
final double kOffRoadDecel = -kMaxSpeed / 2;
final double kOffRoadLimit = kMaxSpeed / 4;

// Sprite scaling (matches: 0.3 * (1/playerWidth), roadWidth multiplier folded in)
const double kSpriteScale = 0.3 / 80.0;

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------
class RoadColors {
  final Color road, grass, rumble, lane;
  const RoadColors(this.road, this.grass, this.rumble, [this.lane = Colors.transparent]);
}

const kColorSky = Color(0xFF72D7EE);
const kColorTree = Color(0xFF005108);
const kColorFog = Color(0xFF005108);

const kLight = RoadColors(
    Color(0xFF6B6B6B), Color(0xFF10AA10), Color(0xFF555555), Color(0xFFCCCCCC));
const kDark =
    RoadColors(Color(0xFF696969), Color(0xFF009A00), Color(0xFFBBBBBB));
const kStartColor = RoadColors(Colors.white, Colors.white, Colors.white);
const kFinishColor = RoadColors(Colors.black, Colors.black, Colors.black);

// ---------------------------------------------------------------------------
// Math helpers (Util in original)
// ---------------------------------------------------------------------------
double _toInt(double? v, double d) => v ?? d;
double increase(double start, double inc, double max) {
  double result = start + inc;
  while (result >= max) result -= max;
  while (result < 0) result += max;
  return result;
}

double accelerate(double v, double accel, double dt) => v + accel * dt;
double limit(double value, double lo, double hi) => math.max(lo, math.min(value, hi));
double interpolate(double a, double b, double percent) => a + (b - a) * percent;
double easeIn(double a, double b, double p) => a + (b - a) * math.pow(p, 2);
double easeInOut(double a, double b, double p) =>
    a + (b - a) * (-math.cos(p * math.pi) / 2 + 0.5);
double exponentialFog(double distance, double density) =>
    1 / math.pow(math.e, distance * distance * density);
double percentRemaining(double n, int total) => (n % total) / total;

bool overlap(double x1, double w1, double x2, double w2, [double percent = 1.0]) {
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
  double wx = 0, wy = 0, wz = 0; // world
  double cx = 0, cy = 0, cz = 0; // camera
  double sx = 0, sy = 0, sw = 0, scale = 0; // screen
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

enum SpriteKind { tree, billboard, boulder }

class RoadSprite {
  final SpriteKind kind;
  final double offset; // in road widths (negative = left)
  RoadSprite(this.kind, this.offset);
}

class Car {
  double offset; // -1..1 across the road
  double z; // world z
  double speed;
  double percent = 0;
  final Color color;
  Car(this.offset, this.z, this.speed, this.color);
}

class Segment {
  final int index;
  final P p1 = P();
  final P p2 = P();
  double curve;
  double fog = 0;
  double clip = 0;
  bool looped = false;
  final RoadColors color;
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
  double playerX = 0; // -1..1 (offset from center, in road widths)
  double playerY = 0;

  double skyOffset = 0;
  double hillOffset = 0;
  double treeOffset = 0;

  int lap = 1;
  double currentLapTime = 0;
  double lastLapTime = 0;
  double bestLapTime = 0;

  bool keyLeft = false, keyRight = false, keyFaster = false, keySlower = false;

  // audio events (read & cleared by the view layer each frame)
  bool collisionEvent = false;
  bool offRoad = false;

  int get trackLength => segments.length * kSegmentLength;

  RacerGame() {
    _buildRoad();
    _resetCars();
  }

  Segment findSegment(double z) =>
      segments[(z / kSegmentLength).floor() % segments.length];

  double get lastY => segments.isEmpty ? 0 : segments.last.p2.wy;

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
    final endY = startY + _toInt(y, 0) * kSegmentLength;
    final total = enter + hold + leave;
    for (var n = 0; n < enter; n++) {
      _addSegment(easeIn(0, curve, n / enter),
          easeInOut(startY, endY, n / total));
    }
    for (var n = 0; n < hold; n++) {
      _addSegment(curve, easeInOut(startY, endY, (enter + n) / total));
    }
    for (var n = 0; n < leave; n++) {
      _addSegment(easeInOut(curve, 0, n / leave),
          easeInOut(startY, endY, (enter + hold + n) / total));
    }
  }

  // length presets
  static const lNone = 0, lShort = 25, lMedium = 50, lLong = 100;
  // curve presets
  static const cNone = 0.0, cEasy = 2.0, cMedium = 4.0, cHard = 6.0;
  // hill presets
  static const hNone = 0.0, hLow = 20.0, hMedium = 40.0, hHigh = 60.0;

  void _addStraight([int num = lMedium]) =>
      _addRoad(num, num, num, 0, 0);
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

    // start/finish line decoration
    for (var n = 0; n < kRumbleLength; n++) {
      _setColor(segments.length - 1 - n, kStartColor);
    }
    for (var n = 0; n < kRumbleLength; n++) {
      _setColor(n, kFinishColor);
    }
  }

  void _setColor(int index, RoadColors color) {
    final old = segments[index];
    final s = Segment(old.index, old.curve, color);
    s.p1.wy = old.p1.wy;
    s.p1.wz = old.p1.wz;
    s.p2.wy = old.p2.wy;
    s.p2.wz = old.p2.wz;
    s.sprites.addAll(old.sprites);
    segments[index] = s;
  }

  void _addSprite(int index, SpriteKind kind, double offset) {
    if (index < segments.length) {
      segments[index].sprites.add(RoadSprite(kind, offset));
    }
  }

  void _resetSprites() {
    // billboards along the way
    _addSprite(20, SpriteKind.billboard, -1.2);
    _addSprite(40, SpriteKind.billboard, -1.2);
    _addSprite(60, SpriteKind.billboard, -1.2);
    _addSprite(80, SpriteKind.billboard, -1.2);
    _addSprite(100, SpriteKind.billboard, -1.2);

    _addSprite(240, SpriteKind.billboard, -1.1);
    _addSprite(240, SpriteKind.billboard, 1.1);

    // dense trees near start
    for (var n = 10; n < 200; n += 4 + (n ~/ 100)) {
      _addSprite(n, SpriteKind.tree, 1 + rng.nextDouble() * 2);
      _addSprite(n, SpriteKind.tree, -1 - rng.nextDouble() * 2);
    }

    // scattered trees / boulders rest of the track
    for (var n = 250; n < segments.length - 50; n += 3) {
      _addSprite(
          n,
          rng.nextBool() ? SpriteKind.tree : SpriteKind.boulder,
          (rng.nextBool() ? 1 : -1) * (1.2 + rng.nextDouble() * 3));
    }
  }

  void _resetCars() {
    cars.clear();
    for (final s in segments) {
      s.cars.clear();
    }
    const totalCars = 100;
    final palette = [
      const Color(0xFFE53935),
      const Color(0xFF1E88E5),
      const Color(0xFFFDD835),
      const Color(0xFF8E24AA),
      const Color(0xFFFB8C00),
      const Color(0xFF00ACC1),
    ];
    for (var n = 0; n < totalCars; n++) {
      final offset = rng.nextDouble() * 2 - 1; // -1..1, biased later
      final z = (rng.nextInt(segments.length) * kSegmentLength).toDouble();
      final speed = kMaxSpeed / 4 + rng.nextDouble() * kMaxSpeed / 2;
      final car = Car(offset * 0.8, z, speed, palette[n % palette.length]);
      cars.add(car);
      findSegment(z).cars.add(car);
    }
  }

  // -------------------------------------------------------------------------
  // Update
  // -------------------------------------------------------------------------
  void update(double dt) {
    final playerSegment = findSegment(position + kPlayerZ);
    const playerW = 80 * kSpriteScale;
    final speedPercent = speed / kMaxSpeed;
    final dx = dt * 2 * speedPercent;
    final startPosition = position;

    _updateCars(dt, playerSegment, playerW);

    position = increase(position, dt * speed, trackLength.toDouble());

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

    // off-road
    offRoad = (playerX < -1 || playerX > 1) && speed > kOffRoadLimit / 2;
    if ((playerX < -1 || playerX > 1) && speed > kOffRoadLimit) {
      speed = accelerate(speed, kOffRoadDecel, dt);
      for (final sprite in playerSegment.sprites) {
        final spriteW = _spriteWidth(sprite.kind) * kSpriteScale;
        if (overlap(
            playerX,
            playerW,
            sprite.offset + spriteW / 2 * (sprite.offset > 0 ? 1 : -1),
            spriteW)) {
          speed = kMaxSpeed / 5;
          position =
              increase(playerSegment.p1.wz, -kPlayerZ, trackLength.toDouble());
          collisionEvent = true;
          break;
        }
      }
    }

    // car collisions
    for (final car in playerSegment.cars) {
      final carW = 80 * kSpriteScale;
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

    // parallax + lap timing
    final delta = (position - startPosition) / kSegmentLength;
    skyOffset = increase(skyOffset, 0.001 * playerSegment.curve * delta, 1);
    hillOffset = increase(hillOffset, 0.002 * playerSegment.curve * delta, 1);
    treeOffset = increase(treeOffset, 0.003 * playerSegment.curve * delta, 1);

    if (position > kPlayerZ) {
      if (currentLapTime > 0 && startPosition < kPlayerZ) {
        lastLapTime = currentLapTime;
        if (bestLapTime == 0 || lastLapTime < bestLapTime) {
          bestLapTime = lastLapTime;
        }
        currentLapTime = 0;
        lap++;
      } else {
        currentLapTime += dt;
      }
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
    final lookahead = 20;
    final carW = 80 * kSpriteScale;

    // avoid the player if on the same line of sight
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
        if (car.speed > otherCar.speed &&
            overlap(car.offset, carW, otherCar.offset, carW, 1.2)) {
          final dir = otherCar.offset > car.offset ? -1 : 1;
          return dir / i * (car.speed - otherCar.speed) / kMaxSpeed;
        }
      }
    }
    // pull back toward the road if off it
    if (car.offset < -0.9) return 0.1;
    if (car.offset > 0.9) return -0.1;
    return 0;
  }

  double _spriteWidth(SpriteKind kind) {
    switch (kind) {
      case SpriteKind.tree:
        return 150;
      case SpriteKind.billboard:
        return 220;
      case SpriteKind.boulder:
        return 100;
    }
  }

  void reset() {
    position = 0;
    speed = 0;
    playerX = 0;
    lap = 1;
    currentLapTime = 0;
    lastLapTime = 0;
    _resetCars();
  }
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

  void _ensureAudio() {
    if (!_audioStarted) {
      _audioStarted = true;
      EngineAudio.start();
    }
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _onTick(Duration now) {
    if (_last == Duration.zero) {
      _last = now;
      return;
    }
    var frame = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (frame > 0.1) frame = 0.1; // clamp big stalls
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
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    final up = event is KeyUpEvent;
    if (!down && !up) return KeyEventResult.ignored;
    if (down) _ensureAudio();
    final k = event.logicalKey;
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: (_) {
            _ensureAudio();
            _focus.requestFocus();
          },
          child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: RoadPainter(game)),
            ),
            // HUD
            Positioned(
              top: 16,
              left: 16,
              child: _Hud(game: game),
            ),
            // touch controls
            Positioned.fill(child: _TouchControls(game: game)),
          ],
          ),
        ),
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  final RacerGame game;
  const _Hud({required this.game});

  String _fmt(double t) {
    final m = (t ~/ 60);
    final s = (t % 60);
    return '${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(2).padLeft(5, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final kmh = (game.speed / 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()]),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$kmh km/h',
                style: const TextStyle(
                    color: Colors.yellowAccent,
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
            Text('LAP $kLapsHint  •  Lap ${game.lap}'),
            Text('Time   ${_fmt(game.currentLapTime)}'),
            Text('Last   ${game.lastLapTime == 0 ? "--:--.--" : _fmt(game.lastLapTime)}'),
            Text('Best   ${game.bestLapTime == 0 ? "--:--.--" : _fmt(game.bestLapTime)}'),
          ],
        ),
      ),
    );
  }
}

const String kLapsHint = '∞';

class _TouchControls extends StatelessWidget {
  final RacerGame game;
  const _TouchControls({required this.game});

  Widget _pad(IconData icon, void Function(bool) set, Alignment a) {
    return Align(
      alignment: a,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Listener(
          onPointerDown: (_) => set(true),
          onPointerUp: (_) => set(false),
          onPointerCancel: (_) => set(false),
          child: Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: Colors.white24,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white38, width: 2),
            ),
            child: Icon(icon, size: 38, color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _pad(Icons.arrow_left, (v) => game.keyLeft = v, Alignment.bottomLeft),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 110, bottom: 18),
            child: Listener(
              onPointerDown: (_) => game.keyRight = true,
              onPointerUp: (_) => game.keyRight = false,
              onPointerCancel: (_) => game.keyRight = false,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 2),
                ),
                child: const Icon(Icons.arrow_right,
                    size: 38, color: Colors.white),
              ),
            ),
          ),
        ),
        _pad(Icons.keyboard_arrow_down, (v) => game.keySlower = v,
            Alignment.bottomRight),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 110, bottom: 18),
            child: Listener(
              onPointerDown: (_) => game.keyFaster = true,
              onPointerUp: (_) => game.keyFaster = false,
              onPointerCancel: (_) => game.keyFaster = false,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.25),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38, width: 2),
                ),
                child: const Icon(Icons.keyboard_arrow_up,
                    size: 42, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------
class RoadPainter extends CustomPainter {
  final RacerGame game;
  RoadPainter(this.game);

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final g = game;

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

    _drawBackground(canvas, size, playerY);

    final paint = Paint()..isAntiAlias = false;

    // road
    for (var n = 0; n < kDrawDistance; n++) {
      final segment =
          g.segments[(baseSegment.index + n) % g.segments.length];
      segment.looped = segment.index < baseSegment.index;
      segment.fog = exponentialFog(n / kDrawDistance, kFogDensity);
      segment.clip = maxy;

      final camOffsetZ =
          g.position - (segment.looped ? g.trackLength : 0);
      project(segment.p1, (g.playerX * kRoadWidth) - x,
          playerY + kCameraHeight, camOffsetZ, kCameraDepth, width, height,
          kRoadWidth);
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

      _renderSegment(
          canvas, paint, width, segment.p1, segment.p2, segment.fog,
          segment.color);

      maxy = segment.p2.sy;
    }

    // sprites & cars, back to front
    for (var n = kDrawDistance - 1; n > 0; n--) {
      final segment =
          g.segments[(baseSegment.index + n) % g.segments.length];

      for (final car in segment.cars) {
        final spriteScale =
            interpolate(segment.p1.scale, segment.p2.scale, car.percent);
        final spriteX = interpolate(segment.p1.sx, segment.p2.sx, car.percent) +
            (spriteScale * car.offset * kRoadWidth * width / 2);
        final spriteY =
            interpolate(segment.p1.sy, segment.p2.sy, car.percent);
        _renderCar(canvas, width, height, spriteScale, spriteX, spriteY,
            segment.clip, car.color);
      }

      for (final sprite in segment.sprites) {
        final spriteScale = segment.p1.scale;
        final spriteX = segment.p1.sx +
            (spriteScale * sprite.offset * kRoadWidth * width / 2);
        final spriteY = segment.p1.sy;
        _renderSprite(canvas, width, height, sprite, spriteScale, spriteX,
            spriteY, sprite.offset < 0 ? -1 : 0, segment.clip);
      }

      if (segment == playerSegment) {
        _renderPlayer(canvas, width, height, g.speed / kMaxSpeed, playerSegment);
      }
    }
  }

  // ---- background -------------------------------------------------------
  void _drawBackground(Canvas canvas, Size size, double playerY) {
    final w = size.width, h = size.height;
    final horizon = h * 0.5;

    // sky gradient
    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF52B8E8), kColorSky, Color(0xFFBDEBF7)],
      ).createShader(Rect.fromLTWH(0, 0, w, horizon + 40));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, horizon + 40), sky);

    // sun
    canvas.drawCircle(
        Offset(w * (0.5 + (game.skyOffset - 0.5) * 0.4), horizon * 0.45),
        h * 0.06,
        Paint()..color = const Color(0xFFFFF3B0));

    // distant hills (parallax)
    final hillShift = (game.hillOffset - 0.5) * w * 2;
    final hillBase = horizon + 6 - playerY * 0.001 * h;
    final hills = Paint()..color = const Color(0xFF2E8B57);
    final hp = Path();
    hp.moveTo(0, hillBase);
    for (var i = -1; i <= 6; i++) {
      final cx = w * i / 5 - (hillShift % (w / 5)) - 40;
      hp.quadraticBezierTo(
          cx + w / 10, hillBase - h * 0.10, cx + w / 5, hillBase);
    }
    hp.lineTo(w, hillBase + 40);
    hp.lineTo(0, hillBase + 40);
    hp.close();
    canvas.drawPath(hp, hills);

    // treeline band
    final treeY = horizon + 2 - playerY * 0.001 * h;
    canvas.drawRect(
        Rect.fromLTWH(0, treeY, w, 8), Paint()..color = kColorTree);

    // grass below horizon (will be mostly overdrawn by road grass polys,
    // but fills gaps at the very bottom)
    canvas.drawRect(Rect.fromLTWH(0, horizon, w, h - horizon),
        Paint()..color = kLight.grass);
  }

  // ---- road segment -----------------------------------------------------
  void _renderSegment(Canvas canvas, Paint paint, double width, P p1, P p2,
      double fog, RoadColors color) {
    final r1 = _rumbleWidth(p1.sw);
    final r2 = _rumbleWidth(p2.sw);
    final l1 = _laneMarkerWidth(p1.sw);
    final l2 = _laneMarkerWidth(p2.sw);

    // grass spans full width
    paint.color = color.grass;
    canvas.drawRect(Rect.fromLTRB(0, p2.sy, width, p1.sy), paint);

    // rumble strips
    paint.color = color.rumble;
    _poly(canvas, paint, p1.sx - p1.sw - r1, p1.sy, p1.sx - p1.sw, p1.sy,
        p2.sx - p2.sw, p2.sy, p2.sx - p2.sw - r2, p2.sy);
    _poly(canvas, paint, p1.sx + p1.sw + r1, p1.sy, p1.sx + p1.sw, p1.sy,
        p2.sx + p2.sw, p2.sy, p2.sx + p2.sw + r2, p2.sy);

    // road
    paint.color = color.road;
    _poly(canvas, paint, p1.sx - p1.sw, p1.sy, p1.sx + p1.sw, p1.sy,
        p2.sx + p2.sw, p2.sy, p2.sx - p2.sw, p2.sy);

    // lane markers
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

    // fog
    if (fog < 1) {
      paint.color = kColorFog.withOpacity(1 - fog);
      canvas.drawRect(Rect.fromLTRB(0, p2.sy, width, p1.sy), paint);
    }
  }

  double _rumbleWidth(double projectedRoadWidth) =>
      projectedRoadWidth / (kLanes + 2);
  double _laneMarkerWidth(double projectedRoadWidth) =>
      projectedRoadWidth / (kLanes * 8);

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

  // ---- sprites ----------------------------------------------------------
  void _renderSprite(Canvas canvas, double width, double height,
      RoadSprite sprite, double scale, double destX, double destY,
      double offsetX, double clipY) {
    final logicalW = game._spriteWidth(sprite.kind);
    final logicalH = logicalW * (sprite.kind == SpriteKind.tree ? 1.4 : 1.0);
    final destW = logicalW * scale * width / 2 * (kSpriteScale * kRoadWidth);
    final destH = logicalH * scale * width / 2 * (kSpriteScale * kRoadWidth);
    var dx = destX + destW * offsetX;
    final dy = destY - destH; // sit on the ground
    final clipH = clipY > 0 ? math.max(0.0, dy + destH - clipY) : 0.0;
    if (clipH >= destH) return;
    if (destW < 0.5) return;

    final rect = Rect.fromLTWH(dx, dy, destW, destH - clipH);
    canvas.save();
    canvas.clipRect(rect);
    switch (sprite.kind) {
      case SpriteKind.tree:
        _drawTree(canvas, dx, dy, destW, destH);
        break;
      case SpriteKind.billboard:
        _drawBillboard(canvas, dx, dy, destW, destH);
        break;
      case SpriteKind.boulder:
        _drawBoulder(canvas, dx, dy, destW, destH);
        break;
    }
    canvas.restore();
  }

  void _drawTree(Canvas c, double x, double y, double w, double h) {
    final trunk = Paint()..color = const Color(0xFF5D3A1A);
    final tw = w * 0.16;
    c.drawRect(
        Rect.fromLTWH(x + w / 2 - tw / 2, y + h * 0.65, tw, h * 0.35), trunk);
    final leaf = Paint()..color = const Color(0xFF1B7A1B);
    for (var i = 0; i < 3; i++) {
      final ty = y + h * (0.05 + i * 0.22);
      final th = h * 0.42;
      final tipW = w * (1 - i * 0.18);
      final path = Path()
        ..moveTo(x + w / 2, ty)
        ..lineTo(x + w / 2 - tipW / 2, ty + th)
        ..lineTo(x + w / 2 + tipW / 2, ty + th)
        ..close();
      c.drawPath(path, leaf);
    }
  }

  void _drawBillboard(Canvas c, double x, double y, double w, double h) {
    final post = Paint()..color = const Color(0xFF7A5230);
    c.drawRect(Rect.fromLTWH(x + w * 0.45, y + h * 0.5, w * 0.1, h * 0.5), post);
    final board = Rect.fromLTWH(x, y, w, h * 0.55);
    c.drawRect(board, Paint()..color = const Color(0xFFD32F2F));
    c.drawRect(
        board.deflate(w * 0.04),
        Paint()..color = Colors.white);
    final txt = Paint()..color = const Color(0xFF1565C0);
    c.drawRect(
        Rect.fromLTWH(x + w * 0.12, y + h * 0.12, w * 0.76, h * 0.06), txt);
    c.drawRect(
        Rect.fromLTWH(x + w * 0.12, y + h * 0.26, w * 0.5, h * 0.06), txt);
  }

  void _drawBoulder(Canvas c, double x, double y, double w, double h) {
    final p = Paint()..color = const Color(0xFF7E7E7E);
    final path = Path()
      ..moveTo(x + w * 0.1, y + h)
      ..lineTo(x + w * 0.0, y + h * 0.5)
      ..lineTo(x + w * 0.3, y + h * 0.15)
      ..lineTo(x + w * 0.7, y + h * 0.1)
      ..lineTo(x + w, y + h * 0.55)
      ..lineTo(x + w * 0.9, y + h)
      ..close();
    c.drawPath(path, p);
    c.drawPath(path, Paint()
      ..color = const Color(0xFF5A5A5A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.03);
  }

  // ---- traffic car ------------------------------------------------------
  void _renderCar(Canvas canvas, double width, double height, double scale,
      double destX, double destY, double clipY, Color color) {
    const logicalW = 80.0, logicalH = 56.0;
    final destW = logicalW * scale * width / 2 * (kSpriteScale * kRoadWidth);
    final destH = logicalH * scale * width / 2 * (kSpriteScale * kRoadWidth);
    if (destW < 0.5) return;
    final dx = destX - destW / 2;
    final dy = destY - destH;
    final clipH = clipY > 0 ? math.max(0.0, dy + destH - clipY) : 0.0;
    if (clipH >= destH) return;
    final rect = Rect.fromLTWH(dx, dy, destW, destH - clipH);
    canvas.save();
    canvas.clipRect(rect);
    _drawCarShape(canvas, dx, dy, destW, destH, color);
    canvas.restore();
  }

  void _drawCarShape(
      Canvas c, double x, double y, double w, double h, Color color) {
    // shadow
    c.drawOval(
        Rect.fromLTWH(x, y + h * 0.82, w, h * 0.3),
        Paint()..color = Colors.black.withOpacity(0.25));
    // body
    final body = Paint()..color = color;
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.05, y + h * 0.35, w * 0.9, h * 0.55),
            Radius.circular(w * 0.08)),
        body);
    // cabin
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.2, y + h * 0.1, w * 0.6, h * 0.4),
            Radius.circular(w * 0.06)),
        Paint()..color = color.withOpacity(0.85));
    // rear window
    c.drawRect(
        Rect.fromLTWH(x + w * 0.28, y + h * 0.16, w * 0.44, h * 0.22),
        Paint()..color = const Color(0xFF223344));
    // tail lights
    final light = Paint()..color = const Color(0xFFFFCC33);
    c.drawRect(Rect.fromLTWH(x + w * 0.08, y + h * 0.5, w * 0.1, h * 0.14),
        light);
    c.drawRect(Rect.fromLTWH(x + w * 0.82, y + h * 0.5, w * 0.1, h * 0.14),
        light);
    // wheels
    final tire = Paint()..color = const Color(0xFF111111);
    c.drawRect(Rect.fromLTWH(x + w * 0.06, y + h * 0.78, w * 0.18, h * 0.2),
        tire);
    c.drawRect(Rect.fromLTWH(x + w * 0.76, y + h * 0.78, w * 0.18, h * 0.2),
        tire);
  }

  // ---- player car -------------------------------------------------------
  void _renderPlayer(Canvas canvas, double width, double height,
      double speedPercent, Segment playerSegment) {
    final g = game;
    final bounce = 1.5 * speedPercent * math.sin(g.position * 0.05);
    final steer = g.keyLeft ? -1 : (g.keyRight ? 1 : 0);
    final updown = playerSegment.p2.wy - playerSegment.p1.wy;

    const logicalW = 90.0, logicalH = 60.0;
    // scale similar to a nearby segment
    final scale = kCameraDepth / kPlayerZ;
    final destW = logicalW * scale * width / 2 * (kSpriteScale * kRoadWidth);
    final destH = logicalH * scale * width / 2 * (kSpriteScale * kRoadWidth);

    final destX = width / 2;
    final destY = height - destH * 0.5 - 10 + bounce;

    canvas.save();
    canvas.translate(destX, destY);
    _drawPlayerCar(
        canvas, destW, destH, steer, speedPercent, updown);
    canvas.restore();
  }

  void _drawPlayerCar(Canvas c, double w, double h, int steer,
      double speedPercent, double updown) {
    final x = -w / 2;
    final y = -h / 2;
    // shadow
    c.drawOval(Rect.fromLTWH(x, y + h * 0.8, w, h * 0.35),
        Paint()..color = Colors.black.withOpacity(0.3));
    // body
    final body = Paint()..color = const Color(0xFFE53935);
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y + h * 0.25, w, h * 0.65),
            Radius.circular(w * 0.07)),
        body);
    // cabin
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.2 + steer * w * 0.03, y, w * 0.6, h * 0.45),
            Radius.circular(w * 0.06)),
        Paint()..color = const Color(0xFFEF5350));
    // rear window
    c.drawRect(
        Rect.fromLTWH(x + w * 0.27 + steer * w * 0.03, y + h * 0.06,
            w * 0.46, h * 0.26),
        Paint()..color = const Color(0xFF1A2A3A));
    // spoiler
    c.drawRect(Rect.fromLTWH(x - w * 0.03, y + h * 0.22, w * 1.06, h * 0.08),
        Paint()..color = const Color(0xFF222222));
    // tail lights
    final light = Paint()..color = const Color(0xFFFFEB3B);
    c.drawRect(Rect.fromLTWH(x + w * 0.05, y + h * 0.45, w * 0.12, h * 0.16),
        light);
    c.drawRect(Rect.fromLTWH(x + w * 0.83, y + h * 0.45, w * 0.12, h * 0.16),
        light);
    // wheels
    final tire = Paint()..color = const Color(0xFF0A0A0A);
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.02, y + h * 0.78, w * 0.2, h * 0.26),
            Radius.circular(w * 0.03)),
        tire);
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.78, y + h * 0.78, w * 0.2, h * 0.26),
            Radius.circular(w * 0.03)),
        tire);
  }

  @override
  bool shouldRepaint(covariant RoadPainter oldDelegate) => true;
}
