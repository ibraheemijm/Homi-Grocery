import 'dart:typed_data';

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
    super.key,
  });

  final PlatformDeviceLinkOperations service;
  final VoidCallback? onLinked;

  @override
  State<PlatformDeviceLinkScreen> createState() => _PlatformDeviceLinkScreenState();
}

class _PlatformDeviceLinkScreenState extends State<PlatformDeviceLinkScreen> {
  bool _working = false;
  bool _completed = false;
  String? _message;
  final _customerNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _customerNotesController = TextEditingController();
  String _requestedPlan = 'monthly';

  @override
  void dispose() {
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    _customerNotesController.dispose();
    super.dispose();
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
    return RegExp(r'^[+][1-9][0-9]{7,14}$').hasMatch(normalized)
        ? normalized
        : null;
  }

  Future<void> _createHreqFile() async {
    final targetPlatform = Theme.of(context).platform;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final customerName = _customerNameController.text.trim();
      final customerPhone = _normalizedCustomerPhone();
      if (customerName.length < 2 || customerPhone == null) {
        throw const FormatException('أدخل اسم العميل ورقم هاتف صحيحًا بصيغة دولية.');
      }
      final requestFile = await widget.service.createActivationRequestFile(
        customerName: customerName,
        customerPhone: customerPhone,
        requestedPlan: _requestedPlan,
        customerNotes: _customerNotesController.text.trim(),
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
          text: 'أرفق هذا الملف عند مراسلة إدارة Homi لإصدار ملف التفعيل.',
        );
        if (!mounted) return;
        setState(() => _message =
            'تم إنشاء ملف الطلب ${requestFile.requestId}. اختر WhatsApp أو وسيلة الإرسال المناسبة من قائمة المشاركة.');
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
            : 'تم حفظ ملف الطلب ${requestFile.requestId}. أرسله إلى إدارة Homi لإصدار الترخيص.');
      }
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

  Future<void> _callSupport() async {
    await launchUrl(
      Uri(scheme: 'tel', path: '+2490904697455'),
      mode: LaunchMode.externalApplication,
    );
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('FormatException')) return text.replaceFirst('FormatException: ', '');
    if (text.contains('LICENSE_DEVICE_MISMATCH')) {
      return 'ملف الترخيص مخصص لجهاز آخر.';
    }
    if (text.contains('LICENSE_SIGNATURE_INVALID')) {
      return 'تعذر التحقق من توقيع ملف الترخيص.';
    }
    return 'تعذر إكمال العملية. التفاصيل: $text';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التفعيل بالملفات'),
          leading: IconButton(
            tooltip: 'رجوع أو خروج',
            icon: const BackButtonIcon(),
            onPressed: () {
              final navigator = Navigator.of(context);
              if (navigator.canPop()) {
                navigator.pop();
              } else {
                SystemNavigator.pop();
              }
            },
          ),
        ),
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
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'يتم التفعيل والتجديد عبر الملفات فقط. أنشئ ملف طلب .hreq وأرسله إلى إدارة Homi، ثم استورد ملف الترخيص .hlic الذي يصلك. لا يلزم اتصال التطبيق بالإنترنت لإتمام التفعيل.',
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
                          label: const Text('إنشاء ومشاركة ملف الطلب (.hreq)'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _importLicenseFile,
                          icon: const Icon(Icons.file_open_outlined),
                          label: const Text('استيراد ملف التفعيل (.hlic)'),
                        ),
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
