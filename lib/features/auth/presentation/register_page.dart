import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/ui/app_ui.dart';
import '../../../core/constants/app_roles.dart';
import 'auth_gate.dart';

class RegisterPage extends StatefulWidget {
  final String? initialToken;

  const RegisterPage({super.key, this.initialToken});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  bool _checkingToken = false;
  bool _submitting = false;
  bool _obscure = true;

  // Invite details returned from RPC check_invite
  bool _inviteChecked = false;
  bool _inviteValid = false;
  String? _inviteMessage;
  String? _tenantName;
  String? _roleId;
  String? _inviteEmail;

  @override
  void initState() {
    super.initState();
    if (widget.initialToken != null && widget.initialToken!.trim().isNotEmpty) {
      final extracted = _extractInviteTokenStatic(widget.initialToken!.trim());
      if (extracted.isNotEmpty) {
        _tokenController.text = extracted;
        // Auto check invite if a valid token was provided via deep-link
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _checkInvite();
        });
      }
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// Static version for use in initState before build context is available.
  static String _extractInviteTokenStatic(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    try {
      final uri = Uri.parse(trimmed);
      final invite = uri.queryParameters['invite'];
      if (invite != null && invite.isNotEmpty) return invite.trim();
    } catch (_) {}
    final regExp = RegExp(r'[?&]invite=([^&]+)');
    final match = regExp.firstMatch(trimmed);
    if (match != null && match.groupCount >= 1) {
      final token = match.group(1);
      if (token != null && token.isNotEmpty) return token.trim();
    }
    // Return as-is if no URL structure detected (raw token)
    return trimmed;
  }

  String _extractInviteToken(String input) {
    return _RegisterPageState._extractInviteTokenStatic(input);
  }

  Future<void> _checkInvite() async {
    final tokenInput = _tokenController.text.trim();
    final token = _extractInviteToken(tokenInput);
    if (token.isEmpty) {
      AppUi.showSnack('Masukkan kode atau link undangan.');
      return;
    }

    if (token != tokenInput) {
      _tokenController.text = token;
    }

    setState(() {
      _checkingToken = true;
      _inviteChecked = false;
      _inviteValid = false;
    });

    try {
      final response = await _client.rpc('check_invite', params: {
        'p_token': token,
      });

      if (response != null && response is List && response.isNotEmpty) {
        final data = Map<String, dynamic>.from(response.first as Map);
        final isValid = data['is_valid'] as bool? ?? false;
        final tenantName = data['tenant_name'] as String?;
        final roleId = data['role_id'] as String?;
        final email = data['email'] as String?;

        setState(() {
          _inviteChecked = true;
          _inviteValid = isValid;
          _inviteMessage = isValid ? 'Undangan valid' : 'Undangan tidak valid atau sudah kedaluwarsa.';
          _tenantName = tenantName;
          _roleId = roleId;
          _inviteEmail = email;

          if (isValid && email != null && email.isNotEmpty) {
            _emailController.text = email;
          }
        });

        if (!isValid) {
          AppUi.showSnack('Undangan tidak valid atau sudah kedaluwarsa.');
        }
      } else {
        setState(() {
          _inviteChecked = true;
          _inviteValid = false;
          _inviteMessage = 'Undangan tidak valid atau sudah kedaluwarsa.';
        });
        AppUi.showSnack('Undangan tidak valid atau sudah kedaluwarsa.');
      }
    } catch (e, st) {
      debugPrint('[CHECK_INVITE_ERROR] $e\n$st');
      setState(() {
        _inviteChecked = true;
        _inviteValid = false;
        _inviteMessage = 'Undangan tidak valid atau sudah kedaluwarsa.';
      });
      AppUi.showSnack('Undangan tidak valid atau sudah kedaluwarsa.');
    } finally {
      setState(() {
        _checkingToken = false;
      });
    }
  }

  Future<void> _submitInvite() async {
    FocusManager.instance.primaryFocus?.unfocus();

    final token = _tokenController.text.trim();
    final name = _nameController.text.trim();
    final username = _usernameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || username.isEmpty) {
      AppUi.showSnack('NAMA DAN USERNAME WAJIB DIISI.');
      return;
    }

    setState(() => _submitting = true);

    try {
      User? currentUser = _client.auth.currentUser;

      if (currentUser == null) {
        // Sign up first
        final email = _emailController.text.trim().toLowerCase();
        final password = _passwordController.text;

        if (email.isEmpty || password.isEmpty) {
          AppUi.showSnack('EMAIL DAN PASSWORD WAJIB DIISI UNTUK DAFTAR.');
          setState(() => _submitting = false);
          return;
        }

        // Verify case-insensitive email matching if invite has a specific email
        if (_inviteEmail != null && _inviteEmail!.isNotEmpty) {
          if (email != _inviteEmail!.toLowerCase()) {
            AppUi.showSnack('EMAIL HARUS SAMA DENGAN EMAIL UNDANGAN.');
            setState(() => _submitting = false);
            return;
          }
        }

        final authResponse = await _client.auth.signUp(
          email: email,
          password: password,
          data: {'nama': name},
        );

        currentUser = authResponse.user;
        if (currentUser == null) {
          throw Exception('Gagal melakukan pendaftaran akun.');
        }
      } else {
        // User already logged in, check email matching if invite email is specified
        if (_inviteEmail != null && _inviteEmail!.isNotEmpty) {
          final currentEmail = currentUser.email?.toLowerCase() ?? '';
          if (currentEmail != _inviteEmail!.toLowerCase()) {
            AppUi.showSnack('SESI LOGIN AKTIF BERBEDA DENGAN EMAIL UNDANGAN.');
            setState(() => _submitting = false);
            return;
          }
        }
      }

      // Accept the invite
      final acceptResponse = await _client.rpc('accept_invite', params: {
        'p_token': token,
        'p_nama': name,
        'p_username': username,
        'p_nomor_hp': phone.isEmpty ? null : phone,
      });

      final isOk = acceptResponse != null &&
          acceptResponse is Map &&
          (acceptResponse['ok'] as bool? ?? false);

      if (isOk) {
        AppUi.showSnack('PENDAFTARAN BERHASIL! SELAMAT BERGABUNG.');
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const AuthGate()),
            (route) => false,
          );
        }
      } else {
        throw Exception('Gagal memproses persetujuan undangan.');
      }
    } catch (e) {
      AppUi.showSnack(AppUi.userMessage(e.toString().replaceAll('Exception:', '')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentUser = _client.auth.currentUser;

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
                          child: const Icon(Icons.mail_outline_rounded, color: Colors.black, size: 38),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Daftar Lewat Undangan',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Masukkan kode khusus untuk bergabung'.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),

                    // Token Verification NiceCard
                    NiceCard(
                      borderColor: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Kode / Link Undangan',
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Masukkan kode undangan atau link invite yang diberikan oleh Platform Owner.',
                            style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _tokenController,
                                  enabled: !_checkingToken && !_submitting,
                                  decoration: const InputDecoration(
                                    hintText: 'Masukkan kode atau link...',
                                    prefixIcon: Icon(Icons.key),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 50,
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 40),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: (_checkingToken || _submitting) ? null : _checkInvite,
                                  icon: _checkingToken
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                        )
                                      : const Icon(Icons.search),
                                  label: const Text('Cek Undangan'),
                                ),
                              ),
                            ],
                          ),
                          if (_inviteChecked && !_inviteValid) ...[
                            const SizedBox(height: 12),
                            Text(
                              _inviteMessage ?? 'Token tidak valid.',
                              style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w800, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Registration Form NiceCard
                    if (_inviteChecked && _inviteValid)
                      NiceCard(
                        borderColor: Colors.black,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppUi.green.withOpacity(isDark ? 0.2 : 0.1),
                                border: Border.all(color: AppUi.green, width: 2),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'UNDANGAN VALID'.toUpperCase(),
                                    style: const TextStyle(fontWeight: FontWeight.w900, color: AppUi.green, fontSize: 13),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Tenant: ${_tenantName ?? '-'}',
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                                  ),
                                  Text(
                                    'Role: ${appRoleFromRoleId(_roleId).label}',
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),

                            // If not logged in, show Auth credentials
                            if (currentUser == null) ...[
                              const Text(
                                'KREDENSIAL LOGIN BARU',
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _emailController,
                                enabled: _inviteEmail == null || _inviteEmail!.isEmpty,
                                keyboardType: TextInputType.emailAddress,
                                decoration: const InputDecoration(
                                  labelText: 'EMAIL',
                                  prefixIcon: Icon(Icons.email),
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _passwordController,
                                obscureText: _obscure,
                                decoration: InputDecoration(
                                  labelText: 'PASSWORD',
                                  prefixIcon: const Icon(Icons.lock),
                                  suffixIcon: IconButton(
                                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                ),
                              ),
                              const Divider(height: 32, thickness: 2, color: Colors.black),
                            ] else ...[
                              // If logged in
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.black, width: 2),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.check_circle, color: AppUi.green),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Terotentikasi sebagai: ${currentUser.email}',
                                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 18),
                            ],

                            // Profile Fields
                            const Text(
                              'PROFIL PENGGUNA',
                              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _nameController,
                              decoration: const InputDecoration(
                                labelText: 'NAMA LENGKAP',
                                prefixIcon: Icon(Icons.badge),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _usernameController,
                              decoration: const InputDecoration(
                                labelText: 'USERNAME',
                                prefixIcon: Icon(Icons.alternate_email),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'NOMOR HP (OPSIONAL)',
                                prefixIcon: Icon(Icons.phone),
                              ),
                            ),
                            const SizedBox(height: 22),

                            FilledButton(
                              onPressed: _submitting ? null : _submitInvite,
                              child: _submitting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                    )
                                  : Text(
                                      (currentUser == null ? 'DAFTAR & BERGABUNG' : 'BERGABUNG KE TENANT').toUpperCase(),
                                    ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 24),
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
