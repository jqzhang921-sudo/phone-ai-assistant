import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';
import '../../models/mcp_tool.dart';

class SensorTool {
  static McpTool get definition => McpTool(
        name: 'get_sensors',
        description: '读取手机传感器数据（加速度计、陀螺仪等）',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      // Get accelerometer data (latest reading)
      final accelStream = accelerometerEventStream();
      final gyroStream = gyroscopeEventStream();

      // Read one sample from each stream
      final accel = await accelStream.first;
      final gyro = await gyroStream.first;

      // Calculate a simple step count estimation based on acceleration magnitude
      final accelMagnitude =
          sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z);

      return {
        'success': true,
        'accelerometer': {
          'x': accel.x,
          'y': accel.y,
          'z': accel.z,
          'magnitude': accelMagnitude,
        },
        'gyroscope': {
          'x': gyro.x,
          'y': gyro.y,
          'z': gyro.z,
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
    } catch (e) {
      return {'success': false, 'error': '读取传感器失败: $e'};
    }
  }
}
