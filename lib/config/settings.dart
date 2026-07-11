import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// 语音来源：系统（免费，离线）或 ElevenLabs（云端，音质好，按量计费）
enum TtsProvider { system, elevenlabs }

class AppSettings {
  static const _themeKey = 'theme_mode';
  static const _ttsEnabledKey = 'tts_enabled';
  static const _autoTtsKey = 'auto_tts';
  static const _webSocketPortKey = 'websocket_port';
  static const _serverEnabledKey = 'server_enabled';
  static const _ttsProviderKey = 'tts_provider';
  static const _elevenLabsKeyKey = 'elevenlabs_api_key';
  static const _elevenLabsVoiceKey = 'elevenlabs_voice_id';

  // 默认音色：Rachel（配合 eleven_multilingual_v2 可读中文），可在设置里改
  static const defaultElevenLabsVoice = '21m00Tcm4TlvDq8ikWAM';

  bool ttsEnabled;
  bool autoTts;
  int webSocketPort;
  bool serverEnabled;
  ThemeMode themeMode;
  TtsProvider ttsProvider;
  String elevenLabsApiKey;
  String elevenLabsVoiceId;

  AppSettings({
    this.ttsEnabled = true,
    this.autoTts = false,
    this.webSocketPort = 8765,
    this.serverEnabled = false,
    this.themeMode = ThemeMode.system,
    this.ttsProvider = TtsProvider.system,
    this.elevenLabsApiKey = '',
    this.elevenLabsVoiceId = defaultElevenLabsVoice,
  });

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      ttsEnabled: prefs.getBool(_ttsEnabledKey) ?? true,
      autoTts: prefs.getBool(_autoTtsKey) ?? false,
      webSocketPort: prefs.getInt(_webSocketPortKey) ?? 8765,
      serverEnabled: prefs.getBool(_serverEnabledKey) ?? false,
      themeMode: ThemeMode.values[prefs.getInt(_themeKey) ?? 0],
      ttsProvider: TtsProvider.values[prefs.getInt(_ttsProviderKey) ?? 0],
      elevenLabsApiKey: prefs.getString(_elevenLabsKeyKey) ?? '',
      elevenLabsVoiceId:
          prefs.getString(_elevenLabsVoiceKey) ?? defaultElevenLabsVoice,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ttsEnabledKey, ttsEnabled);
    await prefs.setBool(_autoTtsKey, autoTts);
    await prefs.setInt(_webSocketPortKey, webSocketPort);
    await prefs.setBool(_serverEnabledKey, serverEnabled);
    await prefs.setInt(_themeKey, themeMode.index);
    await prefs.setInt(_ttsProviderKey, ttsProvider.index);
    await prefs.setString(_elevenLabsKeyKey, elevenLabsApiKey);
    await prefs.setString(_elevenLabsVoiceKey, elevenLabsVoiceId);
  }
}
