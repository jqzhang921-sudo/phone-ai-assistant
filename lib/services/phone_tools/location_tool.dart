import 'package:geolocator/geolocator.dart';
import '../../models/mcp_tool.dart';

class LocationTool {
  static McpTool get definition => McpTool(
    name: 'get_location',
    description: '获取手机的 GPS 定位信息（经纬度）',
    inputSchema: {'type': 'object', 'properties': {}},
    category: '手机工具',
  );

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

      // 1) 先尝试高精度 GPS（室内可能较慢，最多等 15 秒）
      Position? pos;
      var source = 'gps';
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            timeLimit: Duration(seconds: 15),
          ),
        );
      } catch (_) {
        pos = null;
      }

      // 2) 高精度失败时退回网络定位（Wi-Fi/基站，室内快且可用）
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
        } catch (_) {
          pos = null;
        }
      }

      // 3) 实时定位都失败时，用 5 分钟内的最近缓存
      if (pos == null) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          final age = DateTime.now().difference(last.timestamp);
          if (age.inMinutes <= 5) {
            return {
              'success': true,
              'latitude': last.latitude,
              'longitude': last.longitude,
              'accuracy': last.accuracy,
              'timestamp': last.timestamp.toIso8601String(),
              'source': 'last_known',
              'note': 'GPS 定位超时，使用约 ${age.inMinutes} 分钟前的最近位置，仅供参考',
            };
          }
        }
        return {
          'success': false,
          'error': '获取位置失败（GPS 与网络定位均超时，且无 5 分钟内的缓存位置）',
        };
      }

      return {
        'success': true,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'altitude': pos.altitude,
        'timestamp': pos.timestamp.toIso8601String(),
        'source': source,
      };
    } catch (e) {
      return {'success': false, 'error': '获取位置失败: $e'};
    }
  }
}
