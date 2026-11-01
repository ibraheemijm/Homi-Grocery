import 'package:flutter/material.dart';

/// بيانات اعتماد مؤقتة يعاد استخدامها مباشرة لإصدار موافقة المدير.
class ManagerApprovalCredentials {
  const ManagerApprovalCredentials({
    required this.username,
    required this.password,
  });

  final String username;
  final String password;
}

/// نافذة تحقق مستقلة لا تغيّر جلسة المستخدم الحالي.
class ManagerApprovalDialog extends StatefulWidget {
  const ManagerApprovalDialog({
    required this.discountAmount,
    this.operationName = 'الخصم',
    this.cancelLabel = 'إلغاء البيع',
    super.key,
  });

  final int discountAmount;
  final String operationName;
  final String cancelLabel;

  @override
  State<ManagerApprovalDialog> createState() => _ManagerApprovalDialogState();
}

class _ManagerApprovalDialogState extends State<ManagerApprovalDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _validationMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _validationMessage = 'أدخل اسم المستخدم وكلمة المرور.');
      return;
    }

    Navigator.pop(
      context,
      ManagerApprovalCredentials(username: username, password: password),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('موافقة المدير مطلوبة'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.operationName == 'الخصم'
                ? 'الخصم الحالي: ${widget.discountAmount} ج.س'
                : 'قيمة ${widget.operationName} الحالية: ${widget.discountAmount} ج.س'),
            const SizedBox(height: 8),
            const Text(
              widget.operationName == 'الخصم'
                  ? 'هذا الخصم يتجاوز صلاحية الكاشير. أدخل بيانات حساب مدير نشط لإصدار موافقة لهذه الفاتورة فقط، صالحة لمدة دقيقتين.'
                  : 'هذه القيمة تتجاوز سقف صلاحية الكاشير. أدخل بيانات حساب مدير نشط لإصدار موافقة لهذه العملية المحددة، صالحة لمدة دقيقتين.',
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('manager-approval-username'),
              controller: _usernameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'اسم مستخدم المدير',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('manager-approval-password'),
              controller: _passwordController,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'كلمة مرور المدير',
                border: OutlineInputBorder(),
              ),
            ),
            if (_validationMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _validationMessage!,
                key: const ValueKey('manager-approval-validation'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('التحقق والموافقة'),
        ),
      ],
    );
  }
}
