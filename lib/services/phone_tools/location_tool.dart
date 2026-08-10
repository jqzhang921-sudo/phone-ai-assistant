import 'package:geolocator/geolocator.dart';
import '../../models/mcp_tool.dart';

class LocationTool {
  static McpTool get definition => McpTool(
    name: 'get_location',
    description: '获取手机的 GPS 定位信息',
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

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          // 避免室内/信号差时无限等待定位结果
          timeLimit: Duration(seconds: 15),
        ),
      );

      return {
        'success': true,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'altitude': pos.altitude,
        'timestamp': pos.timestamp.toIso8601String(),
        'source': 'gps',
      };
    } catch (e) {
      // GPS 定位超时/失败时，仅当存在足够新的最近位置时才回退，
      // 避免把很久以前的旧坐标当成当前位置返回给 AI。
      try {
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
      } catch (_) {}
      return {'success': false, 'error': '获取位置失败（GPS 超时且无 5 分钟内的缓存位置）: $e'};
    }
  }
}
