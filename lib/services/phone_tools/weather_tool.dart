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
    description:
        '查天气（当前实况 + 未来几天预报）。'
        '问到天气、要不要带伞、明天冷不冷、适不适合出门这类事情时用这个，'
        '**不要用 web_search 查天气**——搜索引擎抓回来的是城市百科，查不到天气。'
        '\n'
        '两种用法，优先用坐标：\n'
        '1. 用户问「我这儿」「附近」「今天要不要带伞」这类跟自身位置有关的，'
        '**先调 get_location 拿到经纬度，再把 latitude / longitude 传进来**。'
        '这样最准，也绕开了地名查不到的问题。\n'
        '2. 用户明确说了地方，就传 location 地名。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'location': {
          'type': 'string',
          'description':
              '地名。中文，例如「郑州」「玉溪」。只写地名，'
              '不要带「明天」「天气」这类词。'
              '县和区经常查不到，查不到时改用它所在的市。',
        },
        'latitude': {
          'type': 'number',
          'description':
              '纬度。和 longitude 成对给，给了就直接用坐标查，'
              '不再查地名——从 get_location 拿到的坐标走这里。',
        },
        'longitude': {'type': 'number', 'description': '经度，和 latitude 成对给。'},
        'days': {'type': 'integer', 'description': '要几天的预报，含今天。默认 3，最多 7。'},
      },
    },
    category: '网络工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    // 不用 as String?：模型偶尔会塞别的类型，硬转会抛。
    final location = (args['location']?.toString() ?? '').trim();
    final lat = double.tryParse(args['latitude']?.toString() ?? '');
    final lon = double.tryParse(args['longitude']?.toString() ?? '');
    final hasCoords = lat != null && lon != null;

    if (!hasCoords && location.isEmpty) {
      return {
        'success': false,
        'error':
            '要么给 location（地名），要么给 latitude + longitude（坐标）。'
            '要查用户当前所在位置的天气，先调 get_location 拿坐标，再传进来。',
      };
    }

    final rawDays = int.tryParse(args['days']?.toString() ?? '') ?? 3;
    final days = rawDays.clamp(1, 7);

    try {
      // 给了坐标就直接用，跳过地名解析这一整套。
      //
      // 这条路是最准的：地名库里县、区大面积缺失，而手机上的 GPS 本来就直接
      // 给经纬度，open-meteo 的预报接口本来就按坐标查——中间那次「名字→坐标」
      // 纯属自找麻烦。
      final place =
          hasCoords
              ? {
                'latitude': lat,
                'longitude': lon,
                'timezone': null,
                'label':
                    '坐标 ${lat.toStringAsFixed(3)}, ${lon.toStringAsFixed(3)}',
                'weak': false,
              }
              : await _resolvePlace(location);

      if (place == null) {
        return {
          'success': false,
          'error':
              '没找到「$location」这个地方。'
              '如果是县或区，改用它所在的市试试；'
              '如果问的是用户当前位置，先调 get_location 拿坐标再传 '
              'latitude / longitude 过来，那条路不受地名库限制。',
        };
      }

      final uri = Uri.parse(_forecastUrl).replace(
        queryParameters: {
          'latitude': '${place['latitude']}',
          'longitude': '${place['longitude']}',
          'current':
              'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m',
          'daily':
              'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
          // 没有时区就交给接口按坐标自己判断，别写死 Asia/Shanghai——
          // 那样查国外的地方时间会全错。
          'timezone': place['timezone']?.toString() ?? 'auto',
          'forecast_days': '$days',
        },
      );

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
          'match_warning':
              '只匹配到「${place['label']}」这个小地名，'
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
    // 去掉行政后缀再试一次：open-meteo 的中文库里「新平县」查不到，「新平」有
    // （虽然可能是别处的同名地）。有总比没有强，弱匹配会带警告。
    final bare = cleaned.replaceAll(
      RegExp(r'(彝族|傣族|回族|苗族|壮族|藏族|维吾尔族?|蒙古族?|自治)*[县区市旗盟]$'),
      '',
    );
    final variants = <String>{
      raw.trim(),
      cleaned,
      if (cleaned.isNotEmpty && !cleaned.endsWith('市')) '$cleaned市',
      bare,
    }..removeWhere((e) => e.isEmpty);

    final all = <Map<String, dynamic>>[];
    for (final name in variants) {
      all.addAll(await _geocodeAll(name));
      // 只有拿到地级市以上才收工。用 _isStrong 当停止条件会太松：
      // 「玉溪」第一条是重庆一个 1.6 万人的乡镇（PPLA4，有人口所以算 strong），
      // 就此打住的话永远试不到云南玉溪市。宁可多打一次接口。
      if (all.any(_isDefinitive)) break;
    }
    all.sort((a, b) => _score(b).compareTo(_score(a)));

    if (all.isNotEmpty && _isStrong(all.first)) {
      return _toPlace(all.first, weak: false);
    }

    // open-meteo 的中文地名库缺县、区一级——实测「新平县」「新平彝族傣族自治县」
    // 「杨浦区」全都查不到，而这些名字日常说得最多。OSM 有，拿它兜底。
    final osm = await _geocodeOsm(cleaned.isEmpty ? raw.trim() : cleaned);
    if (osm != null) return osm;

    // OSM 也没有就退回弱匹配，总比直接报「没找到」强，反正会带警告
    if (all.isNotEmpty) return _toPlace(all.first, weak: true);
    return null;
  }

  /// OSM 地名兜底。它有县和区，open-meteo 没有。
  ///
  /// ⚠️ 实测这个域名在国内被 DNS 污染（解析到 103.246.246.144 和一个
  /// face:b00c 开头的 IPv6，都连不上），**没有代理的手机上多半走不通**。
  /// 所以它只是锦上添花：超时压到 6 秒，失败就退回 open-meteo 的弱匹配，
  /// 不能让它拖住整个工具调用。
  ///
  /// 按 Nominatim 的使用规范带上能标识应用的 User-Agent，且只在 open-meteo
  /// 拿不到像样结果时才发，一次天气查询最多一发。
  static const _osmTimeout = Duration(seconds: 6);

  static Future<Map<String, dynamic>?> _geocodeOsm(String name) async {
    if (name.isEmpty) return null;
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search',
      ).replace(
        queryParameters: {
          'q': name,
          'format': 'json',
          'limit': '1',
          'accept-language': 'zh',
        },
      );
      final resp = await http
          .get(
            uri,
            headers: {
              'User-Agent':
                  'phone-ai-assistant/1.0 '
                  '(https://github.com/jqzhang921-sudo/phone-ai-assistant)',
              'Accept-Language': 'zh-CN,zh;q=0.9',
            },
          )
          .timeout(_osmTimeout);
      if (resp.statusCode != 200) return null;

      final list = jsonDecode(resp.body) as List?;
      if (list == null || list.isEmpty) return null;
      final r = list.first as Map<String, dynamic>;

      final lat = double.tryParse(r['lat']?.toString() ?? '');
      final lon = double.tryParse(r['lon']?.toString() ?? '');
      if (lat == null || lon == null) return null;

      // display_name 是「新平县, 玉溪市, 云南省, 中国」，倒过来拼成
      // 「中国 云南省 玉溪市 新平县」，和 open-meteo 那边的标签格式对齐。
      // 顺手滤掉邮编那种纯数字段。
      final label = (r['display_name']?.toString() ?? name)
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !RegExp(r'^\d+$').hasMatch(e))
          .toList()
          .reversed
          .join(' ');

      return {
        'latitude': lat,
        'longitude': lon,
        // OSM 不给时区，交给预报接口按坐标自己判断
        'timezone': null,
        'label': label,
        'weak': false,
      };
    } catch (_) {
      return null;
    }
  }

  /// 地级市及以上。够到这一级才值得停下来不再换写法试。
  static bool _isDefinitive(Map<String, dynamic> r) {
    final fc = r['feature_code']?.toString() ?? '';
    return fc == 'PPLC' || fc == 'PPLA' || fc == 'PPLA2';
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

  /// 排序分：像样的一律排在前面，然后才比行政级别和人口。
  ///
  /// 这两条判据必须一致，否则会出岔子：早先只按「级别 × 1e8 + 人口」排，
  /// 一个人口为 0 的 PPLA3（rank 3，得 3e8）会压过一个有人口的 PPL（得几千）。
  /// 于是「有像样候选就停」判定为真、循环提前退出，最后却取到了那个弱的——
  /// 实测「玉溪」就这么变成了贵州遵义的一个同名村。
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
    final strongBonus = _isStrong(r) ? 1000000000000 : 0;
    return strongBonus + (rank[fc] ?? 0) * 100000000 + pop;
  }

  /// 剥掉时间词和「天气/气温/预报」这类赘词，只留地名。
  static String _stripNoise(String s) =>
      s
          .replaceAll(
            RegExp(
              r'(今天|明天|后天|昨天|前天|今日|明日|未来几天|这几天|周末|'
              r'天气|气温|温度|预报|情况|怎么样|如何|查一下|查询|的)',
            ),
            '',
          )
          .trim();

  /// 拿一批候选回来，挑哪个交给上面的排序。
  static Future<List<Map<String, dynamic>>> _geocodeAll(String name) async {
    try {
      final uri = Uri.parse(_geoUrl).replace(
        queryParameters: {
          'name': name,
          'count': '6',
          'language': 'zh',
          'format': 'json',
        },
      );
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
        if (i < rain.length && rain[i] != null) 'rain_chance': '${rain[i]}%',
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
