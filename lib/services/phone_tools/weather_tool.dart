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
      final place = await _resolvePlace(location);
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
        // 只匹配到人口为 0 的小地名时说一声。地名库里同名的村镇一大堆，
        // 静默返回一个村子的天气是最坏的情况——错了也没人看得出来。
        if (place['weak'] == true)
          'match_warning': '只匹配到「${place['label']}」这个小地名，'
              '可能不是用户说的那个地方。回答时提一句你查的是哪儿，'
              '让 TA 确认，或者请 TA 补上省市。',
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

  /// 定位地名。两件事：换写法重试，以及在候选里挑对的那个。
  ///
  /// 一、提示词里写了「只写地名」，模型照样会把「周口明天天气」整串传进来，
  /// 接口对这种直接返回空。与其把错误抛回去让它重试一轮（用户看到的就是连着
  /// 好几个「未成功」卡片），不如在这儿剥掉赘词再试。
  ///
  /// 二、更要命的是**选错地方还不报错**。实测「周口」返回的三条全是人口为 0
  /// 的同名村（四川南充、广西玉林、河南洛阳），真正的河南周口市要搜「周口市」
  /// 才出得来。直接取第一条的话，用户问周口天气，拿到的是某个村子的，而且
  /// 没人看得出来错了。所以按行政级别 + 人口排序，弱的还会再补一次「市」。
  static Future<Map<String, dynamic>?> _resolvePlace(String raw) async {
    final cleaned = _stripNoise(raw);
    final variants = <String>{
      raw.trim(),
      cleaned,
      if (cleaned.isNotEmpty && !cleaned.endsWith('市')) '$cleaned市',
    }..removeWhere((e) => e.isEmpty);

    final all = <Map<String, dynamic>>[];
    for (final name in variants) {
      all.addAll(await _geocodeAll(name));
      // 已经有像样的候选（行政中心或有人口数据）就不用再多打一次接口
      if (all.any(_isStrong)) break;
    }
    if (all.isEmpty) return null;

    all.sort((a, b) => _score(b).compareTo(_score(a)));
    return _toPlace(all.first, weak: !_isStrong(all.first));
  }

  /// 地级市以上、或者有人口数据的，才算「像样的候选」。
  ///
  /// 注意不能把 PPLA3/PPLA4（乡镇级）也算进来：实测「周口」第一条是
  /// 「四川 南充市 周口」，feature_code 恰好是 PPLA3、人口 0，放行的话就在
  /// 第一轮停下了，永远试不到真正的「周口市」。
  static bool _isStrong(Map<String, dynamic> r) {
    final pop = (r['population'] as num?)?.toInt() ?? 0;
    final fc = r['feature_code']?.toString() ?? '';
    return pop > 0 || fc == 'PPLC' || fc == 'PPLA' || fc == 'PPLA2';
  }

  /// 排序分：先看行政级别，同级再比人口。
  static int _score(Map<String, dynamic> r) {
    const rank = {
      'PPLC': 6, // 首都
      'PPLA': 5, // 省会
      'PPLA2': 4, // 地级市
      'PPLA3': 3, // 县级
      'PPLA4': 2,
    };
    final fc = r['feature_code']?.toString() ?? '';
    final pop = (r['population'] as num?)?.toInt() ?? 0;
    return (rank[fc] ?? 0) * 100000000 + pop;
  }

  /// 剥掉时间词和「天气/气温/预报」这类赘词，只留地名。
  static String _stripNoise(String s) => s
      .replaceAll(
        RegExp(r'(今天|明天|后天|昨天|前天|今日|明日|未来几天|这几天|周末|'
            r'天气|气温|温度|预报|情况|怎么样|如何|查一下|查询|的)'),
        '',
      )
      .trim();

  /// 拿一批候选回来，挑哪个交给上面的排序。
  static Future<List<Map<String, dynamic>>> _geocodeAll(String name) async {
    try {
      final uri = Uri.parse(_geoUrl).replace(queryParameters: {
        'name': name,
        'count': '6',
        'language': 'zh',
        'format': 'json',
      });
      final resp = await http.get(uri).timeout(_timeout);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return ((data['results'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 拼一个「中国 河南 周口市」这样的完整标签——同名地方选错了，
  /// 至少让用户和模型都能一眼看出来。
  static Map<String, dynamic> _toPlace(
    Map<String, dynamic> r, {
    required bool weak,
  }) {
    final parts = [
      r['country'],
      r['admin1'],
      r['admin2'],
      r['name'],
    ].where((e) => e != null && e.toString().isNotEmpty).map((e) => '$e');
    // 去掉重复的层级（「河南 周口市 周口市」这种）
    final seen = <String>{};

    return {
      'latitude': r['latitude'],
      'longitude': r['longitude'],
      'timezone': r['timezone'],
      'label': parts.where(seen.add).join(' '),
      'weak': weak,
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
