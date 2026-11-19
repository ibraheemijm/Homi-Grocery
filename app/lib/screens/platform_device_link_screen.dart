import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
  PlatformActivationRequest? _request;
  bool _working = false;
  bool _proofVerified = false;
  bool _completed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadPendingRequest();
  }

  Future<void> _loadPendingRequest() async {
    try {
      final pending = await widget.service.readPendingActivationRequest();
      if (!mounted || pending == null) return;
      setState(() {
        _request = pending;
        _proofVerified = pending.proofVerified;
        _message = pending.proofVerified
            ? 'يوجد طلب تفعيل محفوظ. يمكنك إرسال بياناته للإدارة أو التحقق من حالته.'
            : 'يوجد طلب تفعيل محفوظ. أكمل إثبات ملكية هذا الجهاز قبل إرساله للإدارة.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    }
  }

  Future<void> _requestActivation() async {
    setState(() {
      _working = true;
      _message = null;
      _completed = false;
      _proofVerified = false;
    });
    try {
      final request = await widget.service.requestActivation();
      if (!mounted) return;
      setState(() {
        _request = request;
        _message =
            'تم إنشاء الطلب. أكمل إثبات ملكية الجهاز، ثم أرسل بيانات الطلب إلى إدارة Homi عبر WhatsApp.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _verifyAndCheckStatus() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final status = await widget.service.completePendingActivation();
      if (!mounted) return;
      switch (status) {
        case PlatformDeviceLinkStatus.waitingForAdmin:
          setState(() {
            _proofVerified = true;
            _message =
                'تم إثبات امتلاك الجهاز بنجاح. أرسل رقم الطلب وبصمة الجهاز إلى إدارة Homi لمراجعتهما.';
          });
          break;
        case PlatformDeviceLinkStatus.licensePending:
          setState(() {
            _proofVerified = true;
            _message =
                'تمت الموافقة على الطلب. يجري تجهيز ملف الترخيص الموقّع؛ تحقق مرة أخرى بعد قليل.';
          });
          break;
        case PlatformDeviceLinkStatus.linked:
          setState(() {
            _proofVerified = true;
            _completed = true;
            _message =
                'اكتمل التفعيل وتم التحقق من ملف الترخيص وتطابق بصمة هذا الجهاز.';
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

  String get _supportMessage =>
      _request?.toSupportMessage(proofVerified: _proofVerified) ?? '';

  Future<void> _copyRequest() async {
    if (_supportMessage.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _supportMessage));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم نسخ بيانات طلب التفعيل.')),
    );
  }

  Future<void> _shareRequest() async {
    if (_supportMessage.isEmpty) return;
    final number = _request?.supportWhatsApp;
    if (number != null && number.isNotEmpty) {
      final uri = Uri.https('wa.me', '/$number', {'text': _supportMessage});
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    }
    await Share.share(
      _supportMessage,
      subject: 'طلب تفعيل Homi Grocery',
    );
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('ACTIVATION_CHALLENGE_EXPIRED')) {
      return 'انتهت صلاحية إثبات الجهاز. أنشئ طلب تفعيل جديدًا.';
    }
    if (text.contains('ACTIVATION_REQUEST_REJECTED')) {
      return 'تم رفض طلب التفعيل. تواصل مع إدارة Homi لمعرفة السبب.';
    }
    if (text.contains('ACTIVATION_REQUEST_EXPIRED') ||
        text.contains('ACTIVATION_REQUEST_CANCELLED')) {
      return 'لم يعد طلب التفعيل صالحًا. أنشئ طلبًا جديدًا.';
    }
    if (text.contains('DEVICE_ALREADY_ACTIVATED')) {
      return 'هذا الجهاز مرتبط بتفعيل قائم بالفعل.';
    }
    if (text.contains('TRIAL_ALREADY_USED')) {
      return 'سبق استخدام الفترة التجريبية لهذه المؤسسة. تواصل مع الإدارة للاشتراك.';
    }
    if (text.contains('ACTIVE_SUBSCRIPTION_EXISTS')) {
      return 'توجد رخصة اشتراك نشطة لهذا المنتج بالفعل.';
    }
    if (text.contains('DEVICE_ALREADY_REGISTERED')) {
      return 'مفتاح هذا الجهاز مرتبط بسجل آخر. يلزم طلب نقل الجهاز من الإدارة.';
    }
    if (text.contains('PLATFORM_NOT_SUPPORTED')) {
      return 'هذا الإصدار أو نوع الجهاز غير مدعوم حاليًا لهذا المنتج.';
    }
    if (text.contains('PlatformApiConfigurationException')) {
      return 'لم يتم إعداد الاتصال بمنصة Homi في هذا الإصدار.';
    }
    return 'تعذر إكمال التفعيل. تحقق من اتصال الإنترنت ثم أعد المحاولة. التفاصيل: $text';
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
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
                          'تفعيل Homi Grocery',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'لا تحتاج إلى حساب أو بريد إلكتروني أو كلمة مرور. ينشئ التطبيق طلبًا مرتبطًا بمفتاح هذا الجهاز، ثم ترسل بياناته إلى إدارة Homi عبر WhatsApp لمراجعته.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: _working || _completed ? null : _requestActivation,
                          icon: const Icon(Icons.add_link),
                          label: Text(request == null ? 'إنشاء طلب تفعيل' : 'تجديد تحدي إثبات الجهاز'),
                        ),
                        if (request != null) ...[
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F6F3),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFD8E3DC)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('بيانات الطلب', style: TextStyle(fontWeight: FontWeight.w800)),
                                const SizedBox(height: 10),
                                _detail('رقم الطلب', request.requestId),
                                _detail('المنصة', '${request.platform} · ${request.architecture}'),
                                _detail('بصمة الجهاز', request.keyFingerprint),
                                if (request.supportWhatsApp != null)
                                  _detail('رقم دعم WhatsApp', request.supportWhatsApp!),
                                _detail('إثبات الملكية', _proofVerified ? 'مكتمل' : 'بانتظار الإكمال'),
                                const SizedBox(height: 10),
                                SelectableText(
                                  _supportMessage,
                                  style: const TextStyle(fontSize: 12, height: 1.5),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _working ? null : _copyRequest,
                            icon: const Icon(Icons.copy),
                            label: const Text('نسخ بيانات طلب التفعيل'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _working ? null : _shareRequest,
                            icon: const Icon(Icons.chat),
                            label: Text(request.supportWhatsApp == null
                                ? 'مشاركة الطلب (اختر WhatsApp)'
                                : 'التواصل مع دعم WhatsApp'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _working || _completed ? null : _verifyAndCheckStatus,
                            icon: const Icon(Icons.verified_outlined),
                            label: Text(_proofVerified ? 'التحقق من حالة التفعيل' : 'إثبات ملكية الجهاز والتحقق'),
                          ),
                        ],
                        if (_working) ...[
                          const SizedBox(height: 14),
                          const Center(child: CircularProgressIndicator()),
                        ],
                        if (_message != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _message!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _completed ? const Color(0xFF173D32) : null,
                              fontWeight: _completed ? FontWeight.w700 : FontWeight.normal,
                            ),
                          ),
                        ],
                        if (request != null) ...[
                          const SizedBox(height: 14),
                          const Text(
                            'إثبات ملكية الجهاز لا يعني الموافقة على التجربة أو تأكيد استلام أي مبلغ. تبدأ التجربة أو الاشتراك بعد اعتماد الإدارة وإصدار الترخيص.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Colors.black54),
                          ),
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

  Widget _detail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
            SelectableText(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
