import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/notify_name.dart';

/// 通知标题用她自己起的备注，像给联系人改备注。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('填了备注：通知就用备注', () async {
    await NotifyName.setRemark('Mu5e');
    expect(await NotifyName.remark(), 'Mu5e');
    expect(await NotifyName.resolve('它回你了'), 'Mu5e');
  });

  test('备注前后的空格不算', () async {
    await NotifyName.setRemark('  小克  ');
    expect(await NotifyName.resolve('它说'), '小克');
  });

  test('清空备注：回到原来的称呼', () async {
    await NotifyName.setRemark('Mu5e');
    await NotifyName.setRemark('   ');
    expect(await NotifyName.remark(), isEmpty);
    expect(await NotifyName.resolve('它说'), '它说');
  });

  test('什么都没设：用调用方给的默认称呼', () async {
    expect(await NotifyName.resolve('它回你了'), '它回你了');
  });
}
