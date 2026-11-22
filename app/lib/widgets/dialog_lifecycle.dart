import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

/// يعرض حوارًا وينتظر انتهاء حركة إغلاقه قبل إعادة التحكم إلى المستدعي.
///
/// قد يكتمل Future الخاص بفتح الحوار عند بدء الإغلاق، بينما تبقى حقول
/// TextField في شجرة الواجهة أثناء حركة الانتقال العكسية. انتظار اكتمال
/// المسار يمنع التخلص من TextEditingController قبل إزالة الحقول المرتبطة به.
Future<T?> showDialogAndWaitForExit<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useSafeArea = true,
  bool useRootNavigator = true,
}) async {
  // نحافظ على سلوك الحوارات في Linux وWindows كما كان؛ الانتظار الإضافي خاص بـ Android.
  if (defaultTargetPlatform != TargetPlatform.android) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
    );
  }

  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    useSafeArea: useSafeArea,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );

  final result = await navigator.push<T>(route);
  // لا نعيد النتيجة قبل انتهاء حركة الإغلاق وإزالة عناصر الحوار.
  await route.completed;
  return result;
}
