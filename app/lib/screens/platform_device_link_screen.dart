import 'package:flutter/material.dart';

import '../data/platform_device_link_service.dart';

class PlatformDeviceLinkScreen extends StatefulWidget {
  const PlatformDeviceLinkScreen({
    required this.service,
    this.onLinked,
    this.websiteBaseUrl = '',
    super.key,
  });

  final PlatformDeviceLinkOperations service;
  final VoidCallback? onLinked;
  final String websiteBaseUrl;

  @override
  State<PlatformDeviceLinkScreen> createState() =>
      _PlatformDeviceLinkScreenState();
}

class _PlatformDeviceLinkScreenState extends State<PlatformDeviceLinkScreen> {
  final _email = TextEditingController();
  bool _working = false;
  bool _requested = false;
  String? _message;
  bool _completed = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _requestLink() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _message = 'أدخل البريد الإلكتروني المرتبط بحساب Homi.');
      return;
    }
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await widget.service.requestLink(email);
      if (!mounted) return;
      setState(() {
        _requested = true;
        _message =
            'إذا كان البريد مسجلًا ومؤكدًا، فستصلك رسالة ربط. افتح الرسالة واضغط رابط التأكيد، ثم ارجع إلى التطبيق.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _completeLink() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final status = await widget.service.completePendingLink();
      if (!mounted) return;
      switch (status) {
        case PlatformDeviceLinkStatus.waitingForEmail:
          setState(() => _message =
              'لم يتم تأكيد البريد بعد. افتح رسالة Homi واضغط رابط التأكيد، ثم حاول مرة أخرى.');
          break;
        case PlatformDeviceLinkStatus.licensePending:
          setState(() => _message =
              'تم إثبات البريد والجهاز وبدأت الفترة التجريبية. يجري تجهيز الترخيص الموقّع؛ اضغط تحقق مرة أخرى بعد قليل.');
          break;
        case PlatformDeviceLinkStatus.linked:
          setState(() {
            _completed = true;
            _message =
                'اكتمل ربط هذا الجهاز بنجاح وأصبح ترخيص Homi جاهزًا.';
          });
          widget.onLinked?.call();
          break;
      }
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('DEVICE_LINK_EXPIRED')) {
      return 'انتهت صلاحية الرابط. اطلب رابطًا جديدًا.';
    }
    if (text.contains('TRIAL_ALREADY_USED')) {
      return 'سبق استخدام الفترة التجريبية لهذه المؤسسة. راجع خيارات الاشتراك من موقع Homi.';
    }
    if (text.contains('ACTIVE_SUBSCRIPTION_EXISTS')) {
      return 'توجد رخصة اشتراك نشطة لهذا المنتج بالفعل.';
    }
    if (text.contains('DEVICE_LINK_CONFLICT')) {
      return 'تعذر ربط هذا الجهاز بسبب تعارض في هوية الجهاز أو ارتباطه بترخيص آخر.';
    }
    if (text.contains('PlatformApiConfigurationException')) {
      return 'لم يتم إعداد الاتصال بمنصة Homi في هذا الإصدار.';
    }
    return 'تعذر إكمال ربط الجهاز. تحقق من اتصال الإنترنت ثم أعد المحاولة. التفاصيل: $text';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.verified_user_outlined,
                          size: 54,
                          color: Color(0xFF173D32),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'ربط Homi Grocery بحسابك',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'أدخل البريد الإلكتروني المسجل في Homi Platform. لن نطلب كلمة مرور المنصة؛ سيصلك رابط لمرة واحدة لإثبات ملكية البريد.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _email,
                          enabled: !_working && !_completed,
                          keyboardType: TextInputType.emailAddress,
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) =>
                              _working || _completed ? null : _requestLink(),
                          decoration: const InputDecoration(
                            labelText: 'البريد الإلكتروني',
                            prefixIcon: Icon(Icons.email_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: _working || _completed ? null : _requestLink,
                          icon: const Icon(Icons.mark_email_read_outlined),
                          label: const Text('إرسال رابط التأكيد'),
                        ),
                        if (_requested && !_completed) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _working ? null : _completeLink,
                            icon: const Icon(Icons.verified_outlined),
                            label: const Text('أكدت البريد، أكمل الربط'),
                          ),
                        ],
                        if (widget.websiteBaseUrl.trim().isNotEmpty) ...[
                          const SizedBox(height: 16),
                          SelectableText(
                            'إذا لم يكن لديك حساب أو لم تؤكد بريدك، أكمل التسجيل من موقع Homi: ${widget.websiteBaseUrl}',
                            textAlign: TextAlign.center,
                          ),
                        ] else ...[
                          const SizedBox(height: 16),
                          const Text(
                            'إذا لم تصلك رسالة، أنشئ حسابًا من موقع Homi أو أكد بريد حسابك الحالي، ثم أعد طلب الرابط.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                        if (_message != null) ...[
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _completed
                                  ? const Color(0xFFDCE9DF)
                                  : const Color(0xFFF7F4EA),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              _message!,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                        if (_working) ...[
                          const SizedBox(height: 16),
                          const Center(child: CircularProgressIndicator()),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
