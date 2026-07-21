import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiKeyConfig {
  static const _keyPrefix = 'api_key_';
  static const _endpointPrefix = 'api_endpoint_';
  static const _modelPrefix = 'api_model_';

  final String provider;
  final String name;
  String? apiKey;
  String? endpoint;
  String? model;

  ApiKeyConfig({
    required this.provider,
    required this.name,
    this.apiKey,
    this.endpoint,
    this.model,
  });

  static List<ApiKeyConfig> get defaults => [
        ApiKeyConfig(
          provider: 'openai',
          name: 'OpenAI',
          endpoint: 'https://api.openai.com/v1',
          model: 'gpt-4o',
        ),
        ApiKeyConfig(
          provider: 'anthropic',
          name: 'Claude',
          endpoint: 'https://api.anthropic.com/v1',
          model: 'claude-sonnet-5',
        ),
        ApiKeyConfig(
          provider: 'custom',
          name: '自定义',
          endpoint: '',
          model: 'deepseek-chat',
        ),
      ];
}

class ApiKeyService {
  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Migrate an old plain-text key from SharedPreferences to secure storage,
  /// then delete the plain-text copy. Returns the migrated key (or empty).
  static Future<String> _migrateIfNeeded(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = prefs.getString('${ApiKeyConfig._keyPrefix}$provider');
    if (oldKey != null && oldKey.isNotEmpty) {
      try {
        await _secureStorage.write(
          key: '${ApiKeyConfig._keyPrefix}$provider',
          value: oldKey,
        );
        await prefs.remove('${ApiKeyConfig._keyPrefix}$provider');
        debugPrint('[secure] Migrated API key for $provider');
        return oldKey;
      } catch (e) {
        debugPrint('[secure] Migration failed for $provider: $e');
        return oldKey; // fall back to the plain-text value
      }
    }
    return '';
  }

  static Future<List<ApiKeyConfig>> loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    if (providers.isEmpty) {
      return ApiKeyConfig.defaults;
    }
    final result = <ApiKeyConfig>[];
    for (final p in providers) {
      // 1) Try secure storage
      String? key =
          await _secureStorage.read(key: '${ApiKeyConfig._keyPrefix}$p');

      // 2) If not found, try migration from old SharedPreferences
      if (key == null || key.isEmpty) {
        key = await _migrateIfNeeded(p);
      }

      final endpoint =
          prefs.getString('${ApiKeyConfig._endpointPrefix}$p') ?? '';
      final model = prefs.getString('${ApiKeyConfig._modelPrefix}$p') ?? '';
      final name = prefs.getString('api_name_$p') ??
          ApiKeyConfig.defaults
              .where((d) => d.provider == p)
              .firstOrNull
              ?.name ??
          p;
      result.add(ApiKeyConfig(
        provider: p,
        name: name,
        apiKey: (key.isNotEmpty) ? key : null,
        endpoint: endpoint.isEmpty ? null : endpoint,
        model: model.isEmpty ? null : model,
      ));
    }
    return result;
  }

  static Future<void> saveKey(ApiKeyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    if (!providers.contains(config.provider)) {
      providers.add(config.provider);
      await prefs.setStringList('api_providers', providers);
    }

    // API key → encrypted storage
    await _secureStorage.write(
      key: '${ApiKeyConfig._keyPrefix}${config.provider}',
      value: config.apiKey ?? '',
    );

    // Non-sensitive metadata stays in SharedPreferences
    await prefs.setString(
        '${ApiKeyConfig._endpointPrefix}${config.provider}',
        config.endpoint ?? '');
    await prefs.setString(
        '${ApiKeyConfig._modelPrefix}${config.provider}',
        config.model ?? '');
    await prefs.setString('api_name_${config.provider}', config.name);

    // Clean up any lingering plain-text copy
    await prefs.remove('${ApiKeyConfig._keyPrefix}${config.provider}');
  }

  static Future<void> deleteKey(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    providers.remove(provider);
    await prefs.setStringList('api_providers', providers);

    await _secureStorage.delete(
        key: '${ApiKeyConfig._keyPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._endpointPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._modelPrefix}$provider');
    await prefs.remove('api_name_$provider');
    // Clean up old plain-text copy if it was never migrated
    await prefs.remove('${ApiKeyConfig._keyPrefix}$provider');
  }
}
