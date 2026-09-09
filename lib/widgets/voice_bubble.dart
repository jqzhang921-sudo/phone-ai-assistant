import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/voice_message.dart';

/// 一条语音消息的条子。
///
/// ## 为什么默认不显示文字
///
/// 2026-09-09 定的：**文字和语音摆在一起，语音就白发了** —— 眼睛比耳朵快，
/// 你会直接读完，不会点播放。而它选择用说的，多半是想让你听见语气。
///
/// 所以文字藏在长按里（见 [MessageBubble] 的长按菜单）。微信藏文字是同一个
/// 道理，不是偷懒。
///
/// ## 波形是假的，而且是故意的
///
/// 真波形要解码整个 mp3 采样，为了一条几秒的语音不值当。这里用**消息 id 当
/// 种子**生成一组固定高度的竖条：同一条消息每次画出来一样，不会闪；不同消息
/// 长得不一样，看着像真的。
///
/// 它的作用本来也不是「让你看出声音长什么样」，是**让你一眼认出这是一条语音**。
class VoiceBubble extends StatefulWidget {
  final VoiceMessage voice;

  /// 用来生成波形，也用来判断是不是这一条在播
  final String messageId;

  final Color textColor;

  const VoiceBubble({
    super.key,
    required this.voice,
    required this.messageId,
    required this.textColor,
  });

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _progress = 0;
      });
    });
    _player.onPositionChanged.listen((pos) {
      if (!mounted) return;
      final total = widget.voice.seconds;
      if (total == null || total == 0) return;
      setState(() => _progress = (pos.inMilliseconds / (total * 1000)).clamp(0, 1));
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() { _playing = false; _progress = 0; });
      return;
    }
    setState(() => _playing = true);
    try {
      await _player.play(DeviceFileSource(widget.voice.path));
    } catch (e) {
      if (!mounted) return;
      setState(() => _playing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条语音的文件不见了')),
      );
    }
  }

  /// 用消息 id 当种子，画一组固定的竖条。同一条每次都一样。
  List<double> get _bars {
    final rnd = math.Random(widget.messageId.hashCode);
    return List.generate(22, (_) => 0.25 + rnd.nextDouble() * 0.75);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.textColor;
    final sec = widget.voice.seconds;
    final bars = _bars;

    return InkWell(
      onTap: _toggle,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _playing
                  ? PhosphorIconsFill.pause
                  : PhosphorIconsFill.play,
              size: 18,
              color: c,
            ),
            const SizedBox(width: 10),
            // 波形。播过的部分实一点，没播的淡一点——进度就在这儿看。
            SizedBox(
              height: 22,
              width: 118,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < bars.length; i++) ...[
                    Container(
                      width: 2.5,
                      height: 22 * bars[i],
                      decoration: BoxDecoration(
                        color: c.withValues(
                          alpha: i / bars.length <= _progress ? 0.95 : 0.35,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    if (i != bars.length - 1) const SizedBox(width: 2.5),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              sec == null ? '--' : '$sec"',
              style: TextStyle(
                fontSize: 12,
                color: c.withValues(alpha: 0.75),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
