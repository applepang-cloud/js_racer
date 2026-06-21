# JS Racer (Flutter)

A faithful **Flutter (CustomPaint) port** of Jake Gordon's classic
[javascript-racer](https://github.com/jakesgordon/javascript-racer/) — a
pseudo-3D arcade road racer in the spirit of *Out Run* / *Pole Position*.

🎮 **Play it:** https://applepang-cloud.github.io/js_racer/

> Not a WebView wrapper — the pseudo-3D road projection is implemented directly
> in Dart and rendered every frame with `CustomPaint`.

## Features
- Pseudo-3D road projection with **curves, hills, rumble strips and lane markings**
- **Exponential fog** into the distance
- **Parallax background** (sky gradient, sun, distant hills, treeline)
- Roadside **sprites** (trees, billboards, boulders) — drawn procedurally, no image assets
- **Traffic** — 100 AI cars that overtake and avoid each other
- Off-road slow-down, centrifugal force on curves, lap timing HUD
- **Procedural audio** (Web Audio): engine note that tracks your speed, off-road
  tyre noise, and a crash thump on collisions
- Keyboard **and** on-screen touch controls

## Controls
| Action | Keyboard | Touch |
|--------|----------|-------|
| Steer  | ← / →    | bottom-left arrows |
| Accelerate | ↑    | bottom-right ▲ |
| Brake  | ↓        | bottom-right ▼ |

## Run locally
```bash
flutter pub get
flutter run -d chrome          # or any device
flutter test                   # engine + widget tests
```

## Build for web
```bash
flutter build web --release
```

## Project layout
- `lib/racer_game.dart` — game model (`RacerGame`) + renderer (`RoadPainter`)
- `lib/engine_audio*.dart` — Web Audio engine (conditional import; no-op on VM/mobile)
- `web/engine_audio.js` — procedural Web Audio synthesis
- `docs/` — built web bundle served by GitHub Pages

## Credits
Game design & track based on the MIT-licensed
[javascript-racer](https://github.com/jakesgordon/javascript-racer/) by Jake Gordon.
