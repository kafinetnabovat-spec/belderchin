import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// ویجت نمایش حجم باقی‌مونده برای هر کاربر - مخصوص بلدرچین 10 گیگ نامحدود
class BelderchinVolumeWidget extends HookConsumerWidget {
  const BelderchinVolumeWidget({super.key, required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };

    if (subInfo == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.cloud_off, color: theme.colorScheme.error),
              const Gap(12),
              Text('اطلاعات حجم در دسترس نیست'),
            ],
          ),
        ),
      );
    }

    final usedGB = subInfo.consumption / (1024 * 1024 * 1024);
    final totalGB = subInfo.total / (1024 * 1024 * 1024);
    final remainingGB = subInfo.remainingBW / (1024 * 1024 * 1024);
    final percent = (subInfo.ratio * 100).clamp(0, 100);
    final isUnlimitedTime = subInfo.expire.millisecondsSinceEpoch == 0 || subInfo.expire.year > 2090;
    final isLow = remainingGB < 1; // کمتر از 1 گیگ
    final isExpired = subInfo.isExpired;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isExpired ? theme.colorScheme.errorContainer : 
                           isLow ? theme.colorScheme.errorContainer :
                           theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isExpired ? Icons.error_outline :
                    isLow ? Icons.warning_amber_rounded :
                    Icons.data_usage_rounded,
                    color: isExpired ? theme.colorScheme.error :
                           isLow ? theme.colorScheme.error :
                           theme.colorScheme.primary,
                  ),
                ),
                const Gap(12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        isExpired ? '⛔ منقضی شده' :
                        isUnlimitedTime ? '♾️ زمان نامحدود' :
                        '⏳ ${subInfo.remaining.inDays} روز باقی‌مونده',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isExpired ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isExpired)
                  FilledButton(
                    onPressed: () {
                      // TODO: تمدید خودکار 10 گیگ
                    },
                    child: Text('تمدید'),
                  ),
              ],
            ),
            const Gap(16),
            
            // نوار پیشرفت حجم
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('حجم مصرفی', style: theme.textTheme.bodySmall),
                Text('${percent.toStringAsFixed(0)}%', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const Gap(6),
            LinearProgressIndicator(
              value: subInfo.ratio,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: theme.colorScheme.surfaceVariant,
              valueColor: AlwaysStoppedAnimation(
                isExpired ? theme.colorScheme.error :
                isLow ? theme.colorScheme.error :
                percent > 80 ? Colors.orange :
                theme.colorScheme.primary,
              ),
            ),
            const Gap(12),
            
            // جزئیات حجم
            Row(
              children: [
                Expanded(
                  child: _VolumeItem(
                    icon: Icons.upload_rounded,
                    label: 'آپلود',
                    value: '${(subInfo.upload / 1024 / 1024 / 1024).toStringAsFixed(2)} GB',
                    color: theme.colorScheme.secondary,
                  ),
                ),
                Expanded(
                  child: _VolumeItem(
                    icon: Icons.download_rounded,
                    label: 'دانلود',
                    value: '${(subInfo.download / 1024 / 1024 / 1024).toStringAsFixed(2)} GB',
                    color: theme.colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: _VolumeItem(
                    icon: Icons.storage_rounded,
                    label: 'باقی‌مونده',
                    value: '${remainingGB.toStringAsFixed(2)} GB',
                    color: isLow ? theme.colorScheme.error : Colors.green,
                    isBold: true,
                  ),
                ),
              ],
            ),
            
            const Gap(12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const Gap(6),
                  Expanded(
                    child: Text(
                      'کل: ${totalGB.toStringAsFixed(0)} گیگ | مصرف: ${usedGB.toStringAsFixed(2)} گیگ | باقی: ${remainingGB.toStringAsFixed(2)} گیگ',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumeItem extends StatelessWidget {
  const _VolumeItem({required this.icon, required this.label, required this.value, required this.color, this.isBold = false});
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool isBold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, size: 20, color: color),
        const Gap(4),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
        Text(value, style: theme.textTheme.bodySmall?.copyWith(fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
      ],
    );
  }
}

/// ویجت ساده برای نمایش توی صفحه اصلی
class BelderchinHomeVolumeCard extends HookConsumerWidget {
  const BelderchinHomeVolumeCard({super.key, required this.profile});
  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subInfo = switch (profile) {
      RemoteProfileEntity(:final subInfo) => subInfo,
      _ => null,
    };
    
    if (subInfo == null) return const SizedBox.shrink();
    
    final remainingGB = subInfo.remainingBW / (1024 * 1024 / 1024);
    final totalGB = subInfo.total / (1024 * 1024 / 1024);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue.shade600, Colors.purple.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 8, offset: Offset(0, 4))],
      ),
      child: Row(
        children: [
          Icon(Icons.account_circle, color: Colors.white, size: 32),
          const Gap(12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(profile.name, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Text(
                  '💾 ${remainingGB.toStringAsFixed(1)} گیگ از ${totalGB.toStringAsFixed(0)} گیگ باقی‌مونده | ♾️ نامحدود',
                  style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12),
                ),
              ],
            ),
          ),
          CircularProgressIndicator(
            value: 1 - subInfo.ratio,
            backgroundColor: Colors.white.withOpacity(0.3),
            valueColor: AlwaysStoppedAnimation(Colors.white),
          ),
        ],
      ),
    );
  }
}
