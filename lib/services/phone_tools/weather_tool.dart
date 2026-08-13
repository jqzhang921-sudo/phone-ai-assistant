import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/mcp_tool.dart';

/// 天气走专门的接口，不要再让模型去 web_search 查。
///
/// 抓搜索引擎查天气这条路本身不通：Bing 返回的静态页里根本没有天气答案卡
/// （实测 b_ans / wtr_ / weather / ° 全为 0），能解析出来的只有城市百科词条。
/// open-meteo 免 key、无需注册、国内直连正常，中文城市名直接支持。
class WeatherTool {
  static const _geoUrl = 'https://geocoding-api.open-meteo.com/v1/search';
  static const _forecastUrl = 'https://api.open-meteo.com/v1/forecast';
  static const _timeout = Duration(seconds: 20);

  static McpTool get definition => McpTool(
        name: 'get_weather',
        description: '查某个地方的天气（当前实况 + 未来几天预报）。'
            '问到天气、要不要带伞、明天冷不冷、适不适合出门这类事情时用这个，'
            '**不要用 web_search 查天气**——搜索引擎抓回来的是城市百科，查不到天气。'
            '地名写中文即可，市、区、县都能查。',
        inputSchema: {
          'type': 'object',
          'properties': {
            'location': {
              'type': 'string',
              'description': '地名，必填。中文，例如「郑州」「上海杨浦」「新平」。'
                  '不要写「明天」「天气」这类词，只写地名。',
              'minLength': 1,
            },
            'days': {
              'type': 'integer',
              'description': '要几天的预报，含今天。默认 3，最多 7。',
            },
          },
          'required': ['location'],
        },
        category: '网络工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    // 不用 as String?：模型偶尔会塞别的类型，硬转会抛。
    final location = (args['location']?.toString() ?? '').trim();
    if (location.isEmpty) {
      return {
        'success': false,
        'error': 'location 参数为空。请重新调用 get_weather 并给出地名，'
            '例如 {"location": "郑州"}。',
      };
    }

    final rawDays = int.tryParse(args['days']?.toString() ?? '') ?? 3;
    final days = rawDays.clamp(1, 7);

    try {
      final place = await _geocode(location);
      if (place == null) {
        return {
          'success': false,
          'error': '没找到「$location」这个地方。'
              '换个写法试试——只写地名，别带「明天」「天气」这类词；'
              '小地方可以写成「县名」或者上一级的市名。',
        };
      }

      final uri = Uri.parse(_forecastUrl).replace(queryParameters: {
        'latitude': '${place['latitude']}',
        'longitude': '${place['longitude']}',
        'current':
            'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'timezone': place['timezone']?.toString() ?? 'Asia/Shanghai',
        'forecast_days': '$days',
      });

      final resp = await http.get(uri).timeout(_timeout);
      if (resp.statusCode != 200) {
        return {'success': false, 'error': '天气接口返回 ${resp.statusCode}'};
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;

      final current = data['current'] as Map<String, dynamic>?;
      final daily = data['daily'] as Map<String, dynamic>?;

      return {
        'success': true,
        'location': place['label'],
        if (current != null)
          'current': {
            'time': current['time'],
            'temperature': '${current['temperature_2m']}°C',
            'feels_like': '${current['apparent_temperature']}°C',
            'humidity': '${current['relative_humidity_2m']}%',
            'wind': '${current['wind_speed_10m']} km/h',
            'condition': _wmo(current['weather_code']),
          },
        if (daily != null) 'forecast': _buildForecast(daily),
        'source': 'open-meteo',
      };
    } catch (e) {
      return {'success': false, 'error': '查天气失败：$e'};
    }
  }

  /// 地名 → 经纬度。取第一条，并拼一个「河南 郑州市」这样的可读标签，
  /// 免得同名地方查错了没人发现。
  static Future<Map<String, dynamic>?> _geocode(String name) async {
    final uri = Uri.parse(_geoUrl).replace(queryParameters: {
      'name': name,
      'count': '1',
      'language': 'zh',
      'format': 'json',
    });
    final resp = await http.get(uri).timeout(_timeout);
    if (resp.statusCode != 200) return null;

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = data['results'] as List?;
    if (results == null || results.isEmpty) return null;

    final r = results.first as Map<String, dynamic>;
    final parts = [
      r['country'],
      r['admin1'],
      r['admin2'],
      r['name'],
    ].where((e) => e != null && e.toString().isNotEmpty).map((e) => '$e');
    // 去掉重复的层级（「河南 郑州市 郑州」这种）
    final seen = <String>{};
    final label = parts.where(seen.add).join(' ');

    return {
      'latitude': r['latitude'],
      'longitude': r['longitude'],
      'timezone': r['timezone'],
      'label': label,
    };
  }

  static List<Map<String, dynamic>> _buildForecast(Map<String, dynamic> daily) {
    final times = (daily['time'] as List?) ?? [];
    final codes = (daily['weather_code'] as List?) ?? [];
    final highs = (daily['temperature_2m_max'] as List?) ?? [];
    final lows = (daily['temperature_2m_min'] as List?) ?? [];
    final rain = (daily['precipitation_probability_max'] as List?) ?? [];

    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < times.length; i++) {
      out.add({
        'date': times[i],
        'condition': _wmo(i < codes.length ? codes[i] : null),
        'high': i < highs.length ? '${highs[i]}°C' : null,
        'low': i < lows.length ? '${lows[i]}°C' : null,
        if (i < rain.length && rain[i] != null)
          'rain_chance': '${rain[i]}%',
      });
    }
    return out;
  }

  /// WMO 天气代码 → 中文。接口只回数字，不翻译的话模型看到的是「weather_code: 80」。
  static String _wmo(dynamic code) {
    final c = int.tryParse(code?.toString() ?? '');
    if (c == null) return '未知';
    return _wmoTable[c] ?? '未知天气（代码 $c）';
  }

  static const _wmoTable = <int, String>{
    0: '晴',
    1: '晴间多云',
    2: '多云',
    3: '阴',
    45: '雾',
    48: '雾凇',
    51: '毛毛雨',
    53: '小雨',
    55: '中雨',
    56: '冻毛毛雨',
    57: '强冻毛毛雨',
    61: '小雨',
    63: '中雨',
    65: '大雨',
    66: '冻雨',
    67: '强冻雨',
    71: '小雪',
    73: '中雪',
    75: '大雪',
    77: '米雪',
    80: '阵雨',
    81: '强阵雨',
    82: '暴雨',
    85: '小阵雪',
    86: '大阵雪',
    95: '雷阵雨',
    96: '雷阵雨伴冰雹',
    99: '雷阵雨伴强冰雹',
  };
}
