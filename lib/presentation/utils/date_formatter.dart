/// تنسيق التواريخ باللغة العربية بطريقة مبسطة ودقيقة دون اعتماديات معقدة
class ArabicDateFormatter {
  static String format(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final itemDate = DateTime(dt.year, dt.month, dt.day);
    final differenceDays = today.difference(itemDate).inDays;

    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';

    if (differenceDays == 0) {
      return 'اليوم $timeStr';
    } else if (differenceDays == 1) {
      return 'أمس $timeStr';
    } else if (differenceDays < 7 && differenceDays > 1) {
      const weekdays = [
        'الإثنين',
        'الثلاثاء',
        'الأربعاء',
        'الخميس',
        'الجمعة',
        'السبت',
        'الأحد'
      ];
      final dayName = weekdays[dt.weekday - 1];
      return '$dayName $timeStr';
    } else {
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    }
  }

  static String formatTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
