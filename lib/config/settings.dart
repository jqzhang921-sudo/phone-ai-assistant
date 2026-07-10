import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _themeKey = 'theme_mode';
  static const _ttsEnabledKey = 'tts_enabled';
  static const _autoTtsKey = 'auto_tts';
  static const _webSocketPortKey = 'websocket_port';
  static const _serverEnabledKey = 'server_enabled';

  bool ttsEnabled;
  bool autoTts;
  int webSocketPort;
  bool serverEnabled;
  ThemeMode themeMode;

  AppSettings({
    this.ttsEnabled = true,
    this.autoTts = false,
    this.webSocketPort = 8765,
    this.serverEnabled = false,
    this.themeMode = ThemeMode.system,
  });

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      ttsEnabled: prefs.getBool(_ttsEnabledKey) ?? true,
      autoTts: prefs.getBool(_autoTtsKey) ?? false,
      webSocketPort: prefs.getInt(_webSocketPortKey) ?? 8765,
      serverEnabled: prefs.getBool(_serverEnabledKey) ?? false,
      themeMode: ThemeMode.values[prefs.getInt(_themeKey) ?? 0],
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ttsEnabledKey, ttsEnabled);
    await prefs.setBool(_autoTtsKey, autoTts);
    await prefs.setInt(_webSocketPortKey, webSocketPort);
    await prefs.setBool(_serverEnabledKey, serverEnabled);
    await prefs.setInt(_themeKey, themeMode.index);
  }
}

