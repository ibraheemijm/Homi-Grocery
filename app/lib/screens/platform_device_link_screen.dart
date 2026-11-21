import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/platform_device_link_service.dart';

class PlatformDeviceLinkScreen extends StatefulWidget {
  const PlatformDeviceLinkScreen({
    required this.service,
    this.onLinked,
    this.websiteBaseUrl = const String.fromEnvironment('HOMI_WEBSITE_BASE_URL'),
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
  final _customerNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _customerNotesController = TextEditingController();
  String _requestedPlan = 'monthly';

  @override
  void initState() {
    super.initState();
    _loadPendingRequest();
  }

  @override
  void dispose() {
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    _customerNotesController.dispose();
    super.dispose();
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

  String? _normalizedCustomerPhone() {
    final raw = _customerPhoneController.text.trim();
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    String normalized;
    if (raw.startsWith('+')) {
      normalized = '+$digits';
    } else if (digits.startsWith('00')) {
      normalized = '+${digits.substring(2)}';
    } else if (digits.startsWith('249')) {
      normalized = '+$digits';
    } else if (digits.startsWith('0')) {
      normalized = '+249${digits.substring(1)}';
    } else {
      return null;
    }
    return RegExp(r'^[+][1-9][0-9]{7,14}
    setState(() {
      _working = true;
      _message = null;
      _completed = false;
      _proofVerified = false;
    });
    try {
      final customerName = _customerNameController.text.trim();
      final customerPhone = _normalizedCustomerPhone();
      if (customerName.length < 2 || customerPhone == null) {
        throw const FormatException('أدخل اسم العميل ورقم هاتف صحيحًا بصيغة دولية.');
      }
      final request = await widget.service.requestActivation(
        customerName: customerName,
        customerPhone: customerPhone,
        requestedPlan: _requestedPlan,
        customerNotes: _customerNotesController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _request = request;
        _message =
            'تم إنشاء الطلب وإرسال بيانات العميل والجهاز إلى المنصة. أكمل إثبات الملكية، ثم تابع الحالة من موقع Homi.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _importLicenseFile() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['hlic'],
        allowMultiple: false,
        withData: true,
      );
      if (selection == null) return;
      final bytes = selection.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('تعذر قراءة محتوى ملف الترخيص المحدد.');
      }
      await widget.service.importLicenseFile(bytes);
      if (!mounted) return;
      setState(() {
        _proofVerified = true;
        _completed = true;
        _message = 'تم استيراد ملف الترخيص والتحقق من توقيعه وتطابقه مع هذا الجهاز.';
      });
      widget.onLinked?.call();
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
                'تم إثبات امتلاك الجهاز بنجاح. أصبح الطلب جاهزًا لمراجعة إدارة Homi.';
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
      if (mounted) {
        final message = error.toString();
        setState(() {
          if (message.contains('ACTIVATION_REQUEST_REJECTED') ||
              message.contains('ACTIVATION_REQUEST_CANCELLED') ||
              message.contains('ACTIVATION_REQUEST_EXPIRED')) {
            _request = null;
            _proofVerified = false;
          }
          _message = _friendlyError(error);
        });
      }
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
    await Share.share(
      _supportMessage,
      subject: 'ملخص طلب تفعيل Homi Grocery',
    );
  }

  Future<void> _createHreqFile() async {
    final targetPlatform = Theme.of(context).platform;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final requestFile = await widget.service.createActivationRequestFile(
        customerName: _customerNameController.text,
        customerPhone: _normalizedCustomerPhone() ?? '',
        requestedPlan: _requestedPlan,
        customerNotes: _customerNotesController.text,
      );
      final fileName = 'Homi-Activation-Request-${requestFile.requestId}.hreq';
      final bytes = Uint8List.fromList(requestFile.bytes);
      if (targetPlatform == TargetPlatform.android ||
          targetPlatform == TargetPlatform.iOS) {
        await Share.shareXFiles(
          [XFile.fromData(
            bytes,
            name: fileName,
            mimeType: 'application/vnd.homi.activation-request+json',
          )],
          subject: 'طلب تفعيل Homi Grocery',
          text: 'ارفع ملف الطلب إلى موقع Homi لإكمال إجراءات التفعيل.',
        );
        if (!mounted) return;
        setState(() => _message = 'تم إنشاء ملف الطلب ${requestFile.requestId} وفتح قائمة المشاركة.');
      } else {
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: const ['hreq'],
        );
        if (!mounted) return;
        setState(() => _message = savedPath == null
            ? 'تم إلغاء حفظ ملف الطلب.'
            : 'تم حفظ ملف الطلب: ${requestFile.requestId}');
      }
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openActivationWebsite() async {
    final baseUrl = widget.websiteBaseUrl.trim();
    if (baseUrl.isEmpty) {
      setState(() => _message = 'رابط موقع Homi غير مضبوط في هذا الإصدار. احفظ ملف .hreq ثم افتح الموقع من المتصفح.');
      return;
    }
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/activation/');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) setState(() => _message = 'تعذر فتح موقع Homi. افتح الرابط يدويًا من المتصفح.');
    }
  }

  Future<void> _callSupport() async {
    await launchUrl(
      Uri(scheme: 'tel', path: '+2490904697455'),
      mode: LaunchMode.externalApplication,
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
                          'لا تحتاج إلى حساب أو بريد إلكتروني أو كلمة مرور. أدخل بيانات العميل، ثم أرسل طلبًا مباشرًا أو أنشئ ملف .hreq لرفعه عبر موقع Homi.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _customerNameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'اسم العميل أو المتجر',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _customerPhoneController,
                          keyboardType: TextInputType.phone,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.left,
                          decoration: const InputDecoration(
                            labelText: 'رقم الهاتف الدولي',
                            hintText: '09... أو +249...',
                            helperText: 'يمكن إدخال رقم محلي أو دولي',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: _requestedPlan,
                          decoration: const InputDecoration(
                            labelText: 'الاشتراك المطلوب',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'monthly', child: Text('شهري — 30 يومًا')),
                            DropdownMenuItem(value: 'annual', child: Text('سنوي — 365 يومًا')),
                            DropdownMenuItem(value: 'lifetime', child: Text('دائم')),
                          ],
                          onChanged: _working ? null : (value) {
                            if (value != null) setState(() => _requestedPlan = value);
                          },
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _customerNotesController,
                          maxLength: 500,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'ملاحظات (اختياري)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _working ? null : _createHreqFile,
                          icon: const Icon(Icons.file_upload_outlined),
                          label: const Text('إنشاء ملف طلب التفعيل (.hreq)'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _openActivationWebsite,
                          icon: const Icon(Icons.language),
                          label: const Text('فتح موقع Homi لرفع الطلب'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _importLicenseFile,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('استيراد ملف الترخيص (.hlic)'),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _working || _completed || _proofVerified ? null : _requestActivation,
                          icon: const Icon(Icons.add_link),
                          label: Text(request == null ? 'إرسال الطلب عبر الإنترنت' : 'تجديد تحدي إثبات الجهاز'),
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
                                _detail('رقم الدعم', '+2490904697455'),
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
                            label: const Text('مشاركة ملخص الطلب'),
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
                        const SizedBox(height: 16),
                        const Divider(),
                        const Text('الدعم الفني', textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        const SelectableText('+249 090 469 7455', textAlign: TextAlign.center,
                            textDirection: TextDirection.ltr),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _callSupport,
                          icon: const Icon(Icons.call_outlined),
                          label: const Text('اتصال بالدعم'),
                        ),
                        if (request != null) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'إثبات ملكية الجهاز لا يعني الموافقة على الاشتراك أو تأكيد استلام أي مبلغ. يصدر الترخيص بعد مراجعة الإدارة وتأكيد الدفع.',
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
).hasMatch(normalized)
        ? normalized
        : null;
  }

  Future<void> _requestActivation() async {
    setState(() {
      _working = true;
      _message = null;
      _completed = false;
      _proofVerified = false;
    });
    try {
      final customerName = _customerNameController.text.trim();
      final customerPhone = _customerPhoneController.text.trim();
      if (customerName.length < 2 ||
          !RegExp(r'^[+][1-9][0-9]{7,14}$').hasMatch(customerPhone)) {
        throw const FormatException('أدخل اسم العميل ورقم هاتف صحيحًا بصيغة دولية.');
      }
      final request = await widget.service.requestActivation(
        customerName: customerName,
        customerPhone: customerPhone,
        requestedPlan: _requestedPlan,
        customerNotes: _customerNotesController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _request = request;
        _message =
            'تم إنشاء الطلب وإرسال بيانات العميل والجهاز إلى المنصة. أكمل إثبات الملكية، ثم تابع الحالة من موقع Homi.';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _importLicenseFile() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['hlic'],
        allowMultiple: false,
        withData: true,
      );
      if (selection == null) return;
      final bytes = selection.files.single.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('تعذر قراءة محتوى ملف الترخيص المحدد.');
      }
      await widget.service.importLicenseFile(bytes);
      if (!mounted) return;
      setState(() {
        _proofVerified = true;
        _completed = true;
        _message = 'تم استيراد ملف الترخيص والتحقق من توقيعه وتطابقه مع هذا الجهاز.';
      });
      widget.onLinked?.call();
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
                'تم إثبات امتلاك الجهاز بنجاح. أصبح الطلب جاهزًا لمراجعة إدارة Homi.';
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
      if (mounted) {
        final message = error.toString();
        setState(() {
          if (message.contains('ACTIVATION_REQUEST_REJECTED') ||
              message.contains('ACTIVATION_REQUEST_CANCELLED') ||
              message.contains('ACTIVATION_REQUEST_EXPIRED')) {
            _request = null;
            _proofVerified = false;
          }
          _message = _friendlyError(error);
        });
      }
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
    await Share.share(
      _supportMessage,
      subject: 'ملخص طلب تفعيل Homi Grocery',
    );
  }

  Future<void> _createHreqFile() async {
    final targetPlatform = Theme.of(context).platform;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final requestFile = await widget.service.createActivationRequestFile(
        customerName: _customerNameController.text,
        customerPhone: _customerPhoneController.text,
        requestedPlan: _requestedPlan,
        customerNotes: _customerNotesController.text,
      );
      final fileName = 'Homi-Activation-Request-${requestFile.requestId}.hreq';
      final bytes = Uint8List.fromList(requestFile.bytes);
      if (targetPlatform == TargetPlatform.android ||
          targetPlatform == TargetPlatform.iOS) {
        await Share.shareXFiles(
          [XFile.fromData(
            bytes,
            name: fileName,
            mimeType: 'application/vnd.homi.activation-request+json',
          )],
          subject: 'طلب تفعيل Homi Grocery',
          text: 'ارفع ملف الطلب إلى موقع Homi لإكمال إجراءات التفعيل.',
        );
        if (!mounted) return;
        setState(() => _message = 'تم إنشاء ملف الطلب ${requestFile.requestId} وفتح قائمة المشاركة.');
      } else {
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: const ['hreq'],
        );
        if (!mounted) return;
        setState(() => _message = savedPath == null
            ? 'تم إلغاء حفظ ملف الطلب.'
            : 'تم حفظ ملف الطلب: ${requestFile.requestId}');
      }
    } catch (error) {
      if (mounted) setState(() => _message = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openActivationWebsite() async {
    final baseUrl = widget.websiteBaseUrl.trim();
    if (baseUrl.isEmpty) {
      setState(() => _message = 'رابط موقع Homi غير مضبوط في هذا الإصدار. احفظ ملف .hreq ثم افتح الموقع من المتصفح.');
      return;
    }
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/activation/');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) setState(() => _message = 'تعذر فتح موقع Homi. افتح الرابط يدويًا من المتصفح.');
    }
  }

  Future<void> _callSupport() async {
    await launchUrl(
      Uri(scheme: 'tel', path: '+2490904697455'),
      mode: LaunchMode.externalApplication,
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
                          'لا تحتاج إلى حساب أو بريد إلكتروني أو كلمة مرور. أدخل بيانات العميل، ثم أرسل طلبًا مباشرًا أو أنشئ ملف .hreq لرفعه عبر موقع Homi.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _customerNameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'اسم العميل أو المتجر',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _customerPhoneController,
                          keyboardType: TextInputType.phone,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.left,
                          decoration: const InputDecoration(
                            labelText: 'رقم الهاتف الدولي',
                            hintText: '+249...',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: _requestedPlan,
                          decoration: const InputDecoration(
                            labelText: 'الاشتراك المطلوب',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'monthly', child: Text('شهري — 30 يومًا')),
                            DropdownMenuItem(value: 'annual', child: Text('سنوي — 365 يومًا')),
                            DropdownMenuItem(value: 'lifetime', child: Text('دائم')),
                          ],
                          onChanged: _working ? null : (value) {
                            if (value != null) setState(() => _requestedPlan = value);
                          },
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _customerNotesController,
                          maxLength: 500,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'ملاحظات (اختياري)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _working ? null : _createHreqFile,
                          icon: const Icon(Icons.file_upload_outlined),
                          label: const Text('إنشاء ملف طلب التفعيل (.hreq)'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _openActivationWebsite,
                          icon: const Icon(Icons.language),
                          label: const Text('فتح موقع Homi لرفع الطلب'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _importLicenseFile,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('استيراد ملف الترخيص (.hlic)'),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _working || _completed || _proofVerified ? null : _requestActivation,
                          icon: const Icon(Icons.add_link),
                          label: Text(request == null ? 'إرسال الطلب عبر الإنترنت' : 'تجديد تحدي إثبات الجهاز'),
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
                                _detail('رقم الدعم', '+2490904697455'),
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
                            label: const Text('مشاركة ملخص الطلب'),
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
                        const SizedBox(height: 16),
                        const Divider(),
                        const Text('الدعم الفني', textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        const SelectableText('+249 090 469 7455', textAlign: TextAlign.center,
                            textDirection: TextDirection.ltr),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _callSupport,
                          icon: const Icon(Icons.call_outlined),
                          label: const Text('اتصال بالدعم'),
                        ),
                        if (request != null) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'إثبات ملكية الجهاز لا يعني الموافقة على الاشتراك أو تأكيد استلام أي مبلغ. يصدر الترخيص بعد مراجعة الإدارة وتأكيد الدفع.',
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
