import 'package:flutter/material.dart';
import 'racer_game.dart';

void main() {
  runApp(const RacerApp());
}

class RacerApp extends StatelessWidget {
  const RacerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JS Racer (Flutter)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const RacerScreen(),
    );
  }
}
