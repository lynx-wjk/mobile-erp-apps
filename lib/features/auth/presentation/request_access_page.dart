import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/ui/app_ui.dart';
import 'auth_gate.dart';

class RequestAccessPage extends StatelessWidget {
  const RequestAccessPage({super.key});

  void _copyToClipboard(BuildContext context, String text, String snackMsg) {
    Clipboard.setData(ClipboardData(text: text));
    AppUi.showSnack(snackMsg);
  }

  Widget _contactRow({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required String btnLabel,
    required Color color,
    required VoidCallback onTap,
  }) {
    return NiceCard(
      borderColor: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color,
                  border: Border.all(color: Colors.black, width: 2),
                ),
                child: Icon(icon, color: Colors.black, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.black,
              side: const BorderSide(color: Colors.black, width: 2),
            ),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(btnLabel.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: AppGlobalBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  children: [
                    // Header
                    Column(
                      children: [
                        Container(
                          width: 70,
                          height: 70,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            border: Border.all(color: Colors.black, width: 3),
                            boxShadow: const [
                              BoxShadow(color: Colors.black, offset: Offset(4, 4)),
                            ],
                          ),
                          child: const Icon(Icons.lock_person_outlined, color: Colors.black, size: 38),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Request Access'.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'HUBUNGI PLATFORM OWNER UNTUK UNDANGAN'.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Main message Card
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline, color: theme.colorScheme.primary, size: 24),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'INFORMASI PENTING',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Fitur request access otomatis sedang disiapkan. Untuk mendapatkan akses, silakan hubungi Platform Owner agar dibuatkan undangan.',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Contacts List
                    _contactRow(
                      context: context,
                      icon: Icons.phone_android_rounded,
                      title: 'WhatsApp',
                      subtitle: 'wa.me/6285155338246',
                      btnLabel: 'Hubungi via WhatsApp',
                      color: AppUi.green,
                      onTap: () => _copyToClipboard(
                        context,
                        'https://wa.me/6285155338246?text=Halo%20Platform%20Owner%2C%20saya%20ingin%20request%20access%20Mobile%20ERP.',
                        'Link WhatsApp disalin ke clipboard!',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _contactRow(
                      context: context,
                      icon: Icons.email_rounded,
                      title: 'Email',
                      subtitle: 'bdchydi@sre.co.id',
                      btnLabel: 'Kirim Email',
                      color: AppUi.blue,
                      onTap: () => _copyToClipboard(
                        context,
                        'mailto:bdchydi@sre.co.id?subject=Request%20Access%20Mobile%20ERP&body=Halo%20Platform%20Owner%2C%20saya%20ingin%20request%20access%20Mobile%20ERP.',
                        'Link Email (mailto) disalin!',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _contactRow(
                      context: context,
                      icon: Icons.camera_alt_rounded,
                      title: 'Instagram',
                      subtitle: '@bdchydi',
                      btnLabel: 'Buka Instagram',
                      color: AppUi.pink,
                      onTap: () => _copyToClipboard(
                        context,
                        'https://instagram.com/bdchydi',
                        'Link Instagram disalin!',
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Back button
                    TextButton.icon(
                      onPressed: () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        } else {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => const AuthGate()),
                          );
                        }
                      },
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Kembali ke Login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
