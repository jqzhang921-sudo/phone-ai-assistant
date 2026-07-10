import 'package:shared_preferences/shared_preferences.dart';

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
  static Future<List<ApiKeyConfig>> loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    if (providers.isEmpty) {
      // First run — return defaults without keys
      return ApiKeyConfig.defaults;
    }
    return providers.map((p) {
      final key = prefs.getString('${ApiKeyConfig._keyPrefix}$p') ?? '';
      final endpoint =
          prefs.getString('${ApiKeyConfig._endpointPrefix}$p') ?? '';
      final model = prefs.getString('${ApiKeyConfig._modelPrefix}$p') ?? '';
      final name = prefs.getString('api_name_$p') ??
          ApiKeyConfig.defaults
              .where((d) => d.provider == p)
              .firstOrNull
              ?.name ??
          p;
      return ApiKeyConfig(
        provider: p,
        name: name,
        apiKey: key.isEmpty ? null : key,
        endpoint: endpoint.isEmpty ? null : endpoint,
        model: model.isEmpty ? null : model,
      );
    }).toList();
  }

  static Future<void> saveKey(ApiKeyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    if (!providers.contains(config.provider)) {
      providers.add(config.provider);
      await prefs.setStringList('api_providers', providers);
    }
    await prefs.setString(
        '${ApiKeyConfig._keyPrefix}${config.provider}', config.apiKey ?? '');
    await prefs.setString(
        '${ApiKeyConfig._endpointPrefix}${config.provider}',
        config.endpoint ?? '');
    await prefs.setString(
        '${ApiKeyConfig._modelPrefix}${config.provider}', config.model ?? '');
    await prefs.setString('api_name_${config.provider}', config.name);
  }

  static Future<void> deleteKey(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    providers.remove(provider);
    await prefs.setStringList('api_providers', providers);
    await prefs.remove('${ApiKeyConfig._keyPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._endpointPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._modelPrefix}$provider');
    await prefs.remove('api_name_$provider');
  }
}
