import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/background_memory.dart';

/// 退到后台时放掉图片缓存。为什么连 live 的也放，见 [freeImageCacheForBackground]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('缓存着的图会被放掉', () async {
    final cache = ImageCache();
    final image = await createTestImage(width: 64, height: 64);
    cache.putIfAbsent(
      'k',
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image.clone())),
      ),
    );
    // 放进去之后总得有东西在
    expect(cache.currentSize + cache.liveImageCount, greaterThan(0));

    freeImageCacheForBackground(cache);

    expect(cache.currentSize, 0);
    expect(cache.currentSizeBytes, 0);
    // ⚠️ live 的那部分是重点：只调 clear() 的话它们还留着，
    // 而退到后台时界面还挂在树上，图基本都是 live 的——那就等于没省。
    expect(cache.liveImageCount, 0);
  });

  test('空缓存上调用也不出事', () {
    final cache = ImageCache();
    freeImageCacheForBackground(cache);
    expect(cache.currentSize, 0);
    expect(cache.liveImageCount, 0);
  });
}
