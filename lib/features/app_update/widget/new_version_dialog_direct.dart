import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

class NewVersionDialogDirect extends HookConsumerWidget with PresLogger {
  NewVersionDialogDirect(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});

  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    
    final downloadProgress = useState<double?>(null);
    final isDownloading = useState(false);
    final downloadError = useState<String?>(null);

    Future<void> downloadAndInstall() async {
      isDownloading.value = true;
      downloadProgress.value = 0;
      downloadError.value = null;
      
      try {
        final dio = Dio();
        final tempDir = await getTemporaryDirectory();
        final apkPath = '${tempDir.path}/belderchin-${newVersion.version}.apk';
        
        // پیدا کردن لینک APK مناسب - arm64-v8a برای اکثر گوشی‌ها
        String apkUrl = newVersion.url;
        // اگر url خود ریلیز هست، باید asset مناسب رو پیدا کنیم
        // از newVersion.assets استفاده میکنیم اگر موجود باشه
        // فعلا فرض میکنیم newVersion.url مستقیم به APK هست یا به صفحه ریلیز
        // برای سادگی، از universal استفاده میکنیم
        
        // اگر newVersion دارای assets هست
        if (newVersion is RemoteVersionEntity) {
          // سعی کن arm64-v8a رو پیدا کنی
          // این منطق باید با github_release_parser هماهنگ باشه
        }
        
        // دانلود با نمایش درصد
        await dio.download(
          newVersion.url,
          apkPath,
          onReceiveProgress: (received, total) {
            if (total != -1) {
              downloadProgress.value = received / total;
            }
          },
        );

        isDownloading.value = false;
        
        // نصب APK
        final result = await OpenFilex.open(apkPath);
        if (result.type != ResultType.done) {
          downloadError.value = 'خطا در نصب: ${result.message}';
        }
      } catch (e, st) {
        loggy.error('Download failed', e, st);
        isDownloading.value = false;
        downloadError.value = 'خطا در دانلود: $e';
      }
    }

    return AlertDialog(
      title: Text('🚀 نسخه جدید بلدرچین'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('نسخه جدید ${newVersion.presentVersion} منتشر شد!'),
          const Gap(12),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'نسخه فعلی: ', style: theme.textTheme.bodySmall),
                TextSpan(text: currentVersion, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'نسخه جدید: ', style: theme.textTheme.bodySmall),
                TextSpan(text: newVersion.presentVersion, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
              ],
            ),
          ),
          const Gap(12),
          if (isDownloading.value) ...[
            LinearProgressIndicator(value: downloadProgress.value),
            const Gap(8),
            Text(
              downloadProgress.value != null 
                ? 'در حال دانلود: ${(downloadProgress.value! * 100).toStringAsFixed(0)}%'
                : 'در حال دانلود...',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (downloadError.value != null) ...[
            const Gap(8),
            Text(downloadError.value!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const Gap(8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
                const Gap(8),
                Expanded(
                  child: Text(
                    'بعد از دانلود، نصب خودکار شروع میشه. اگر نشد، از پوشه دانلود نصب کن.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (canIgnore)
          TextButton(
            onPressed: isDownloading.value ? null : () async {
              await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
              if (context.mounted) context.pop();
            },
            child: Text('نادیده بگیر'),
          ),
        TextButton(
          onPressed: isDownloading.value ? null : () => context.pop(), 
          child: Text('بعداً'),
        ),
        FilledButton(
          onPressed: isDownloading.value ? null : downloadAndInstall,
          child: isDownloading.value 
            ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Text('دانلود و نصب مستقیم'),
        ),
      ],
    );
  }
}

// برای اینکه بدون open_filex هم کار کنه، یه نسخه ساده با url_launcher:
class NewVersionDialogSimple extends HookConsumerWidget {
  NewVersionDialogSimple(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});
  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    return AlertDialog(
      title: Text('🚀 آپدیت بلدرچین'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('نسخه ${newVersion.presentVersion} اومده!'),
          const Gap(8),
          Text('فعلی: $currentVersion -> جدید: ${newVersion.presentVersion}'),
          const Gap(12),
          // نمایش حجم باقی‌مونده کاربر هم اینجا میتونه باشه
        ],
      ),
      actions: [
        TextButton(onPressed: () => context.pop(), child: Text('بعداً')),
        FilledButton(
          onPressed: () async {
            await UriUtils.tryLaunch(Uri.parse(newVersion.url));
          },
          child: Text('دانلود از گیت‌هاب'),
        ),
      ],
    );
  }
}
