import 'package:flutter/services.dart';

/// Android 原生录音封装（MethodChannel → MainActivity.kt）
/// 录 16kHz 单声道 PCM，停止时转 WAV。
/// 不依赖任何第三方录音插件，规避 record_linux 兼容问题。
class VoiceRecorder {
  static const _channel = MethodChannel('voice_recorder');

  Future<bool> hasPermission() async {
    final ok = await _channel.invokeMethod<bool>('hasPermission');
    return ok ?? false;
  }

  /// 开始录音，返回录音文件路径
  Future<String> start() async {
    final path = await _channel.invokeMethod<String>('start');
    if (path == null) throw Exception('录音启动失败');
    return path;
  }

  /// 停止录音，返回 wav 文件路径
  Future<String> stop() async {
    final path = await _channel.invokeMethod<String>('stop');
    if (path == null) throw Exception('录音停止失败');
    return path;
  }

  Future<void> cancel() async {
    await _channel.invokeMethod<void>('cancel');
  }
}
