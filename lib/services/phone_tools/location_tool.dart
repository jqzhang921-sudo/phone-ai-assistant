import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import '../../models/mcp_tool.dart';

class LocationTool {
  static McpTool get definition => McpTool(
    name: 'get_location',
    description: '获取手机的 GPS 定位信息（经纬度）',
    inputSchema: {'type': 'object', 'properties': {}},
    category: '手机工具',
  );

  /// 两点间大致距离（公里），用于判断新拿到的定位是不是"离谱跳变"。
  /// 用的是简化的球面距离公式，够用，不追求精确到米。
  static double _distanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371.0; // 地球半径，公里
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {'success': false, 'error': 'GPS 定位未开启，请在手机设置中打开位置服务'};
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return {'success': false, 'error': '定位权限被拒绝，请在设置中允许定位权限'};
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return {
          'success': false,
          'error': '定位权限被永久拒绝，请在系统设置中开启（设置 → 应用 → 手机 AI 助手 → 权限）',
        };
      }

      // 拿上一次已知的位置，后面既当"离谱跳变"的参照，也当最终兜底
      final lastKnown = await Geolocator.getLastKnownPosition();

      // 1) 先尝试高精度 GPS（室内首次定位可能较慢，最多等 25 秒）
      Position? pos;
      var source = 'gps';
      String? gpsFailReason;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            timeLimit: Duration(seconds: 25),
          ),
        );
      } catch (e) {
        pos = null;
        gpsFailReason = e.toString();
      }

      // 2) 高精度失败时退回网络定位（Wi-Fi/基站，室内快且可用）
      String? networkFailReason;
      if (pos == null) {
        source = 'network';
        try {
          pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              distanceFilter: 0,
              timeLimit: Duration(seconds: 8),
            ),
          );
        } catch (e) {
          pos = null;
          networkFailReason = e.toString();
        }
      }

      // 2.5) 合理性校验：如果拿到的位置跟上一次已知位置差得离谱（短时间内
      // 人不可能移动这么远），大概率是网络定位数据库出错（常见于部分国产
      // 安卓机的网络定位实现），直接丢弃，不要把错误坐标传给 AI。
      if (pos != null && lastKnown != null) {
        final minutesSinceLast =
            DateTime.now().difference(lastKnown.timestamp).inMinutes;
        final distanceKm = _distanceKm(
          pos.latitude,
          pos.longitude,
          lastKnown.latitude,
          lastKnown.longitude,
        );
        // 30分钟内跳变超过200公里，判定为不可信（正常交通工具很难达到）
        if (minutesSinceLast <= 30 && distanceKm > 200) {
          networkFailReason =
              '拿到的坐标跟 $minutesSinceLast 分钟前的位置相差约 ${distanceKm.round()} 公里，'
              '判定为不可信数据，已丢弃';
          pos = null;
        }
      }

      // 3) 实时定位都失败时，使用最近缓存（不限制 5 分钟，但注明新鲜度）
      if (pos == null) {
        if (lastKnown != null) {
          final age = DateTime.now().difference(lastKnown.timestamp);
          final note =
              age.inMinutes <= 5
                  ? 'GPS 与网络定位均失败，使用约 ${age.inMinutes} 分钟前的最近位置，仅供参考'
                  : '实时定位失败，使用 ${age.inMinutes} 分钟前的旧位置，可能不准确，仅供参考';
          return {
            'success': true,
            'latitude': lastKnown.latitude,
            'longitude': lastKnown.longitude,
            'accuracy': lastKnown.accuracy,
            'timestamp': lastKnown.timestamp.toIso8601String(),
            'source': 'last_known',
            'note': note,
            'debug_gps_fail': gpsFailReason,
            'debug_network_fail': networkFailReason,
          };
        }
      }

      if (pos != null) {
        return {
          'success': true,
          'latitude': pos.latitude,
          'longitude': pos.longitude,
          'accuracy': pos.accuracy,
          'altitude': pos.altitude,
          'timestamp': pos.timestamp.toIso8601String(),
          'source': source,
        };
      }

      return {
        'success': false,
        'error':
            '获取位置失败（GPS 与网络定位均超时且无缓存）。请确认手机定位模式为「高精度」（GPS+WLAN+移动网络），并到室外或窗边重试',
        'debug_gps_fail': gpsFailReason,
        'debug_network_fail': networkFailReason,
      };
    } catch (e) {
      return {'success': false, 'error': '获取位置失败: $e'};
    }
  }
}
