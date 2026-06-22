// No-op audio for non-web targets (VM unit tests, future mobile builds).
void engineStart() {}
void engineSetRpm(double v) {}
void engineOffroad(bool on) {}
void engineCrash() {}
void engineStop() {}
void sfxCheckpoint() {}
void sfxFinish() {}
void sfxGameOver() {}
void musicPlay(String url) {}
void musicSetMuted(bool m) {}
