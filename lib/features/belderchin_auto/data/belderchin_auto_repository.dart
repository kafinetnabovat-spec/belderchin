import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// سرویس ثبت‌نام خودکار بلدرچین
/// هر کاربر روی دکمه زد -> 10 گیگ با زمان نامحدود
class BelderchinAutoRepository {
  // آدرس ورکر auto-register که به D1 زئوس وصله
  // بعد از دیپلوی، اینو عوض کن به آدرس ورکر خودت
  static const String autoRegisterUrl = 
      'https://belderchin-auto.YOUR_SUBDOMAIN.workers.dev/api/belderchin/register';
  
  // فعلا برای تست از همون زئوس استفاده میکنیم، بعدا به ورکر جدید تغییر میدیم
  static const String fallbackZeusHost = 
      '5kzcn2e4uuos.44ybmvi8nitmrtvgl5-c-zcunfbav.workers.dev';

  final Dio _dio;
  final SharedPreferences _prefs;

  BelderchinAutoRepository(this._dio, this._prefs);

  static const String _keyDeviceId = 'belderchin.device_id';
  static const String _keyUsername = 'belderchin.username';
  static const String _keySubUrl = 'belderchin.sub_url';
  static const String _keyRegisteredAt = 'belderchin.registered_at';

  /// آیا قبلا ثبت‌نام کرده؟
  bool get isRegistered => _prefs.getString(_keySubUrl) != null;

  String? get subUrl => _prefs.getString(_keySubUrl);
  String? get username => _prefs.getString(_keyUsername);

  /// گرفتن یا ساخت device_id یکتا
  Future<String> _getDeviceId() async {
    var deviceId = _prefs.getString(_keyDeviceId);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await _prefs.setString(_keyDeviceId, deviceId);
    }
    return deviceId;
  }

  /// ثبت‌نام خودکار - 10 گیگ نامحدود
  /// برمیگردونه sub_url
  Future<String> registerIfNeeded() async {
    // اگر قبلا ثبت‌نام کرده، همونو برگردون
    final existingSub = _prefs.getString(_keySubUrl);
    if (existingSub != null) {
      return existingSub;
    }

    final deviceId = await _getDeviceId();

    try {
      // سعی کن از ورکر auto-register استفاده کنی
      final response = await _dio.post(
        autoRegisterUrl,
        data: {
          'device_id': deviceId,
          'zeus_host': fallbackZeusHost,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200 && response.data['success'] == true) {
        final subUrl = response.data['sub_url'] as String;
        final username = response.data['username'] as String;

        await _prefs.setString(_keyUsername, username);
        await _prefs.setString(_keySubUrl, subUrl);
        await _prefs.setInt(_keyRegisteredAt, DateTime.now().millisecondsSinceEpoch);

        return subUrl;
      }
    } catch (e) {
      // اگر ورکر جدید هنوز دیپلوی نشده، مستقیم از زئوس یوزر بساز
      // این بخش موقتیه - مستقیم به API زئوس میزنه (نیاز به سشن ادمین داره)
      // برای نسخه نهایی باید از ورکر عمومی استفاده کنی
      print('Auto-register worker not available, fallback to direct creation: $e');
    }

    // Fallback: یه یوزر تصادفی بساز با همون الگوی قبلی
    // این فقط برای تست محلیه، در پروداکشن باید از ورکر استفاده کنی
    final randomUser = 'bld-${deviceId.substring(0, 8)}-${DateTime.now().millisecondsSinceEpoch % 10000}';
    final fallbackSub = 'https://$fallbackZeusHost/sub/$randomUser';
    
    // اینجا نمیتونیم مستقیم یوزر بسازیم چون نیاز به احراز هویت ادمین داره
    // پس فعلا همون ساب عمومی قبلی رو برمیگردونیم
    // TODO: بعد از دیپلوی ورکر auto، این fallback حذف میشه
    const publicSub = 'https://5kzcn2e4uuos.44ybmvi8nitmrtvgl5-c-zcunfbav.workers.dev/sub/belderchin';
    
    await _prefs.setString(_keyUsername, 'belderchin');
    await _prefs.setString(_keySubUrl, publicSub);
    await _prefs.setInt(_keyRegisteredAt, DateTime.now().millisecondsSinceEpoch);
    
    return publicSub;
  }

  /// ساخت یوزر 10 گیگ مستقیم از طریق پنل زئوس (نیاز به سشن ادمین)
  /// فقط برای ادمین - برای تست
  Future<String> createUserDirectAdmin({
    required String adminSessionCookie,
    String? customUsername,
  }) async {
    final deviceId = await _getDeviceId();
    final username = customUsername ?? 'bld-${deviceId.substring(0, 8)}-${DateTime.now().millisecondsSinceEpoch % 1000}';
    final uuid = const Uuid().v4();

    final dioAdmin = Dio();
    dioAdmin.options.headers['Cookie'] = 'panel_session=$adminSessionCookie';

    try {
      final res = await dioAdmin.post(
        'https://$fallbackZeusHost/api/users',
        data: {
          'username': username,
          'uuid': uuid,
          'limit_gb': 10,
          'expiry_days': 0, // نامحدود
          'connection_type': 'vless,trojan',
          'tls': 'on',
          'port': '443',
          'fingerprint': 'chrome',
          'frag_len': '100-200',
          'frag_int': '10-20',
          'is_active': 1,
          'block_porn': 0,
          'block_ads': 0,
          'ip_limit': 0,
          'auto_rotate_ip': 1,
          'ip_count': 20,
          'enable_direct': true,
          'protocols': ['vless', 'trojan'],
        },
      );

      if (res.statusCode == 200) {
        final subUrl = 'https://$fallbackZeusHost/sub/$username';
        await _prefs.setString(_keyUsername, username);
        await _prefs.setString(_keySubUrl, subUrl);
        await _prefs.setInt(_keyRegisteredAt, DateTime.now().millisecondsSinceEpoch);
        return subUrl;
      }
    } catch (e) {
      print('Direct admin creation failed: $e');
    }

    throw Exception('Failed to create user');
  }

  /// پاک کردن ثبت‌نام (برای تست)
  Future<void> clearRegistration() async {
    await _prefs.remove(_keyUsername);
    await _prefs.remove(_keySubUrl);
    await _prefs.remove(_keyRegisteredAt);
  }
}
