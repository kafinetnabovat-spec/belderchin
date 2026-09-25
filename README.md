<div dir="rtl">

<p align="center">
  <img src="assets/images/app_icon.png" width="128" alt="بلدرچین">
</p>

# بلدرچین (Belderchin)

**فیلترشکن آزاد، رایگان و یک‌دکمه‌ای برای کاربران ایرانی — بدون پنل، بدون تنظیمات، بدون حساب کاربری.**

بلدرچین یک فورک عمومی و متن‌باز از [Hiddify](https://github.com/hiddify/hiddify-app) است. فقط یک دکمهٔ «اتصال» دارد: برنامه خودش سالم‌ترین مسیر را پیدا می‌کند و وصل می‌شود.

> ⚠️ این پروژه در حال توسعه است. تا زمان انتشار اولین نسخهٔ پایدار، از نسخه‌های آزمایشی فقط برای تست استفاده کنید.

## بلدرچین چه می‌کند؟

- **یک دکمه، همین.** بدون وارد کردن لینک، بدون انتخاب سرور، بدون تنظیمات.
- **اتصال خودکار چندلایه** روی زیرساخت Cloudflare:
  1. **WARP** با اسکن سبک آدرس/پورت‌های سالم؛
  2. **اشتراک‌های Cloudflare Workers** (به‌عنوان لینک اشتراک استاندارد)؛
  3. **فهرست پشتیبان**.
- **بررسی واقعی سلامت اتصال** از داخل تونل (چند درخواست `generate_204`) قبل از اعلام «متصل».
- **فهرست منابع امضاشده (Ed25519)** که از چند آینه دریافت و با کلید عمومیِ داخل برنامه اعتبارسنجی می‌شود؛ یک نسخهٔ آفلاین هم همراه برنامه است.
- **فارسی و راست‌به‌چپ**، با پیام‌های وضعیت قابل‌فهم.
- **صفحهٔ عیب‌یابی محلی** با امکان کپی لاگ (آدرس‌ها و توکن‌ها ماسک می‌شوند). هیچ‌چیز آپلود نمی‌شود.

## حریم خصوصی

- هیچ آمار، تحلیل، تبلیغ، حساب کاربری یا شناسهٔ کاربری وجود ندارد.
- هیچ داده‌ای از ترافیک یا دستگاه شما به سرورهای ما فرستاده نمی‌شود؛ اصلاً «سرور ما»یی وجود ندارد.
- لاگ‌ها فقط روی دستگاه شما می‌مانند.
- ارائه‌دهندهٔ زیرساخت (Cloudflare) طبیعتاً می‌تواند فراداده‌های اتصال شما را ببیند؛ این موضوع در اولین اجرا شفاف به شما گفته می‌شود.

جزئیات: [docs/PRIVACY.fa.md](docs/PRIVACY.fa.md) — فهرست منابع اتصال چگونه امضا و تأیید می‌شود: [docs/SOURCES.fa.md](docs/SOURCES.fa.md)

## دانلود و نصب

فایل‌های APK **فقط** از طریق GitHub Actions ساخته و در بخش [Releases](https://github.com/kafinetnabovat-spec/belderchin/releases) منتشر می‌شوند. هر ریلیز شامل `SHA256SUMS.txt` است؛ قبل از نصب، هش فایل را مقایسه کنید.

- برای اکثر گوشی‌ها: `Belderchin-<نسخه>-arm64-v8a.apk`
- گوشی‌های قدیمی: `armeabi-v7a`
- اگر مطمئن نیستید: `universal`

## ساخت از سورس

```bash
# پیش‌نیاز: Flutter 3.38.5، JDK 17، Android SDK
make prepare      # pub get + codegen + ترجمه‌ها + دانلود و تأیید هستهٔ پین‌شده
make android-apk  # خروجی در build/app/outputs/flutter-apk/
```

هستهٔ Go (sing-box) از ریلیز رسمی `hiddify-core v4.1.0` دانلود می‌شود و SHA256 آن در `dependencies.properties` پین شده است. ما هسته را تغییر نداده‌ایم.

## اعتبار و مجوز

بلدرچین بر پایهٔ **[Hiddify](https://github.com/hiddify/hiddify-app)** (© تیم Hiddify) ساخته شده و از همان مجوز پیروی می‌کند:
**[Hiddify Extended GNU GPL v3](LICENSE.md)** — [نسخهٔ اصلی مجوز در مخزن Hiddify](https://github.com/hiddify/hiddify-app/blob/main/LICENSE.md).

- استفادهٔ **تجاری ممنوع** است (فروش، تبلیغات، …).
- کد منبع همیشه به‌صورت عمومی در همین مخزن منتشر می‌شود.
- تمام ریلیزها با GitHub Actions ساخته می‌شوند.
- فهرست کامل تغییرات ما نسبت به Hiddify در [CHANGES.md](CHANGES.md) آمده است.

از تیم Hiddify، sing-box و همهٔ توسعه‌دهندگان آزاد سپاسگزاریم.

</div>

---

<details>
<summary><b>English</b></summary>

# Belderchin

Belderchin ("quail" in Persian) is a **free, non-commercial, one-button VPN app for Iranian users**, published as an open-source fork of [Hiddify](https://github.com/hiddify/hiddify-app) (Flutter UI + prebuilt sing-box based Go core).

- One "Connect" button; no panel, no settings, no accounts.
- Multi-layer auto-connect on Cloudflare infrastructure: WARP (with a lightweight endpoint/port scanner), Cloudflare Workers subscriptions, and a backup list.
- Real in-tunnel health checks (N of M `generate_204`-style probes) before reporting "connected".
- Ed25519-signed source list fetched from multiple mirrors and verified with an embedded public key; a bundled offline copy is always available.
- Persian, RTL, local troubleshooting page with copy-log (masked). Nothing is uploaded, ever.
- No telemetry, analytics, ads or user accounts.

**Build:** Flutter 3.38.5, JDK 17 → `make prepare && make android-apk`. The Go core is downloaded from the official `hiddify-core v4.1.0` release and SHA256-verified; it is not modified.

**License & credit:** Based on [Hiddify](https://github.com/hiddify/hiddify-app) under the [Hiddify Extended GPL v3](LICENSE.md) ([original license](https://github.com/hiddify/hiddify-app/blob/main/LICENSE.md)). Non-commercial use only. All releases are produced by GitHub Actions. Our modifications are documented in [CHANGES.md](CHANGES.md).

</details>
