# فهرست منابع امضاشده (Source List)

بلدرچین هیچ پنلی ندارد. به‌جای آن یک فایل JSON کوچک و **امضاشده با Ed25519** به برنامه می‌گوید از کجا اتصال بگیرد:

| لایه | محتوا | مصرف‌کننده |
|---|---|---|
| `warp` | فعال/غیرفعال بودن WARP + بازه‌های IP و پورت‌های Cloudflare برای اسکنر | فاز ۵ |
| `workers` | لینک‌های اشتراک استاندارد از Cloudflare Workers | زنجیرهٔ اتصال خودکار |
| `backup` | اشتراک‌ها یا کانفیگ‌های درون‌خطی برای مواقع اضطراری | زنجیرهٔ اتصال خودکار |
| `health_check` | آدرس‌های تست سلامت داخل تونل و حداقل تعداد موفقیت (N از M) | فاز ۴ |
| `mirrors` | آینه‌های اضافی برای دریافت نسخه‌های بعدی همین فایل | همین ماژول |

## مدل امنیتی (خلاصه)
- فقط **کلید عمومی** داخل برنامه است (`lib/features/sources/data/trusted_keys.dart`). کلید خصوصی نزد نگه‌دارنده و خارج از مخزن است.
- امضا روی `belderchin-sources-v1:` + بایت‌های payload زده می‌شود (جداسازی دامنه؛ امضای هیچ سند دیگری قابل استفادهٔ مجدد نیست).
- برنامه در هر بار اجرا نسخهٔ کش‌شده و نسخهٔ همراه APK را **دوباره تأیید** می‌کند؛ فایل کش دست‌کاری‌شده بی‌صدا دور ریخته می‌شود.
- **ضد بازگشت (anti-rollback):** نسخه‌ای با `version` کمتر از آخرین نسخهٔ پذیرفته‌شده هرگز قبول نمی‌شود؛ حتی اگر امضای معتبر داشته باشد.
- `issued_at` نباید بیش از ۳۶ ساعت در آینده باشد (تحمل ساعت غلط دستگاه‌ها).
- گذشتن `expires_at` باعث رد شدن **نمی‌شود**؛ فهرست منقضی همچنان استفاده می‌شود ولی به‌عنوان «کهنه» علامت می‌خورد و برنامه تلاش می‌کند نسخهٔ تازه بگیرد (در ابزار فیلترشکن، در دسترس بودن مهم‌تر از تازگی است).
- آینه‌ها فقط `https` هستند، هم‌زمان پرس‌وجو می‌شوند و **جدیدترین نسخهٔ معتبر** برنده است. اعتماد به آینه/CDN/TLS لازم نیست؛ فقط امضا معیار است.
- اندازهٔ پاکت حداکثر ۲۵۶ کیلوبایت است؛ بزرگ‌تر بدون پارس شدن رد می‌شود.

## آینه‌های پیش‌فرض (`SourceListConstants.builtInMirrors`)
1. `https://raw.githubusercontent.com/kafinetnabovat-spec/belderchin/main/assets/sources/sources.signed.json`
2. `https://belderchin.pages.dev/sources.signed.json` ← باید پروژهٔ Cloudflare Pages ساخته شود (پایین را ببینید)
3. `https://cdn.jsdelivr.net/gh/kafinetnabovat-spec/belderchin@main/assets/sources/sources.signed.json`
4. آینهٔ دلخواه کاربر (تنظیمات پیشرفته → «آینهٔ سفارشی»؛ فقط https)

اگر دامنهٔ Pages چیز دیگری شد، همان یک خط را در `source_list_constants.dart` عوض کنید. آینه‌های جدید را می‌توان بدون انتشار نسخهٔ جدید برنامه، از طریق فیلد `mirrors` خودِ فهرست هم اعلام کرد.

## گردش کار به‌روزرسانی فهرست
پیش‌نیاز یک‌باره: `pip install cryptography`

```bash
# 1) ویرایش فهرست خوانا
$EDITOR assets/sources/sources.json          # workers/backup را اضافه کنید

# 2) امضا (نسخه را بالا ببرید، تاریخ صدور = الان، اعتبار ۱۸۰ روز)
python3 tools/sources/belderchin_sources.py sign \
  --key ~/belderchin-secrets/bld-2026-09.private.hex --key-id bld-2026-09 \
  --in assets/sources/sources.json --out assets/sources/sources.signed.json \
  --version 2 --issue-now --valid-days 180 --rewrite-input

# 3) تأیید مثل برنامه
python3 tools/sources/belderchin_sources.py verify \
  --pub ~/belderchin-secrets/bld-2026-09.public.hex --in assets/sources/sources.signed.json

# 4) تست‌ها (تست bundled_sources_test هر کلید/تاریخ اشتباهی را می‌گیرد)
flutter test test/features/sources

# 5) commit + push به main  → آینهٔ ۱ و ۳ خودکار به‌روز می‌شوند؛ Pages هم اگر به مخزن وصل باشد.
```

قواعد: `version` همیشه افزایشی؛ `id`ها یکتا و ثابت (برنامه بر اساس id سابقهٔ موفقیت/شکست نگه می‌دارد)؛ URLها فقط https؛ وزن (`weight`) بزرگ‌تر = اولویت بالاتر داخل همان لایه.

نمونهٔ کامل: `tools/sources/sources.example.json` (همهٔ مقادیر جای‌گزین هستند).

## راه‌اندازی آینهٔ Cloudflare Pages
1. Cloudflare Dashboard → Workers & Pages → Create → Pages → Connect to Git → مخزن `belderchin`.
2. Build command: خالی. Build output directory: `assets/sources`. Production branch: `main`.
3. نام پروژه: `belderchin` → آدرس `https://belderchin.pages.dev/sources.signed.json`.
4. اگر نام آزاد نبود، دامنهٔ به‌دست‌آمده را در `source_list_constants.dart` جایگزین کنید.

## چرخش کلید
1. `python3 tools/sources/belderchin_sources.py gen-key --out ~/belderchin-secrets --key-id bld-2027-01`
2. کلید عمومی جدید را **در کنار** کلید قدیمی به `kTrustedSourceKeys` اضافه کنید و نسخهٔ جدید برنامه را منتشر کنید.
3. پس از مدتی امضا را با کلید جدید انجام دهید؛ نسخه‌های قدیمی برنامه که کلید جدید را ندارند، فهرست را رد می‌کنند و روی آخرین فهرست معتبرِ خود می‌مانند (بدون خرابی، فقط بدون به‌روزرسانی).
4. در انتشار بعدی کلید قدیمی را حذف کنید.

اگر کلید خصوصی لو رفت: بلافاصله کلید جدید بسازید، کلید قدیمی را از `kTrustedSourceKeys` حذف کنید و نسخهٔ جدید برنامه بدهید. تا پیش از به‌روزرسانی کاربران، مهاجم می‌تواند فهرست جعلی (ولی فقط با `version` بالاتر) منتشر کند؛ به همین دلیل کلید را آفلاین نگه دارید.

## رفتار شبکه‌ای این ماژول
- در **شروع برنامه هیچ درخواستی** ارسال نمی‌شود؛ فقط کش و فایل همراه خوانده می‌شوند.
- دریافت از آینه‌ها فقط با `refresh()`/`refreshIfDue()` انجام می‌شود که جریان اتصال آن را (۱) پیش از اتصال و (۲) پس از برقراری تونل صدا می‌زند؛ حداکثر هر ۶ ساعت یک‌بار، مگر فهرست منقضی شده باشد.
- درخواست‌ها از کلاینت HTTP مشترک برنامه می‌روند: اگر هستهٔ اتصال بالا باشد از تونل (`PROXY 127.0.0.1:<mixed-port>; DIRECT`) و در غیر این صورت مستقیم. هر آینه ۱۲ ثانیه مهلت دارد و کل عملیات ۲۰ ثانیه.
- هیچ داده‌ای دربارهٔ کاربر ارسال نمی‌شود؛ درخواست یک GET سادهٔ فایل عمومی است. در لاگ فقط نام میزبان آینه، زمان و نتیجه ثبت می‌شود (بدون بدنهٔ پاسخ).
