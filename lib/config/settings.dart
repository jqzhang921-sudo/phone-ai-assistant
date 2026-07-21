import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 语音来源：系统（免费，离线）或 ElevenLabs（云端，音质好，按量计费）
enum TtsProvider { system, elevenlabs }

class AppSettings {
  static const _themeKey = 'theme_mode';
  static const _ttsEnabledKey = 'tts_enabled';
  static const _autoTtsKey = 'auto_tts';
  static const _webSocketPortKey = 'websocket_port';
  static const _serverEnabledKey = 'server_enabled';
  static const _ttsProviderKey = 'tts_provider';

  // ElevenLabs — key stored in secure storage
  static const _elevenLabsKeyKey = 'elevenlabs_api_key';
  static const _elevenLabsVoiceKey = 'elevenlabs_voice_id';
  static const defaultElevenLabsVoice = '21m00Tcm4TlvDq8ikWAM';

  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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

    // ElevenLabs key: try secure storage first, then migrate from plain text
    String elevenLabsKey =
        await _secureStorage.read(key: _elevenLabsKeyKey) ?? '';
    if (elevenLabsKey.isEmpty) {
      final oldValue = prefs.getString(_elevenLabsKeyKey);
      if (oldValue != null && oldValue.isNotEmpty) {
        try {
          await _secureStorage.write(key: _elevenLabsKeyKey, value: oldValue);
          await prefs.remove(_elevenLabsKeyKey);
          elevenLabsKey = oldValue;
          debugPrint('[secure] Migrated ElevenLabs key');
        } catch (e) {
          elevenLabsKey = oldValue; // fallback
          debugPrint('[secure] ElevenLabs migration failed: $e');
        }
      }
    }

    return AppSettings(
      ttsEnabled: prefs.getBool(_ttsEnabledKey) ?? true,
      autoTts: prefs.getBool(_autoTtsKey) ?? false,
      webSocketPort: prefs.getInt(_webSocketPortKey) ?? 8765,
      serverEnabled: prefs.getBool(_serverEnabledKey) ?? false,
      themeMode: ThemeMode.values[prefs.getInt(_themeKey) ?? 0],
      ttsProvider: TtsProvider.values[prefs.getInt(_ttsProviderKey) ?? 0],
      elevenLabsApiKey: elevenLabsKey,
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

    // Sensitive → secure storage
    await _secureStorage.write(key: _elevenLabsKeyKey, value: elevenLabsApiKey);
    // Clean up plain-text copy
    await prefs.remove(_elevenLabsKeyKey);

    await prefs.setString(_elevenLabsVoiceKey, elevenLabsVoiceId);
  }
}
