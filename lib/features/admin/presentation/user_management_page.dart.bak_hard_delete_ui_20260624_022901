import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';

class UserManagementPage extends StatefulWidget {
  final String? tenantId;
  final String? tenantName;

  const UserManagementPage({
    super.key,
    this.tenantId,
    this.tenantName,
  });

  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];
  String? _currentRoleId;

  bool get _isDemoSuperAdmin =>
      AppRolePermissions.isDemoSuperAdminId(_currentRoleId);
  bool get _isSuperAdmin => AppRolePermissions.isSuperRoleId(_currentRoleId);
  bool get _isOperationalAdmin =>
      AppRolePermissions.isAdminRoleId(_currentRoleId);
  bool get _canManageUsers =>
      !_isDemoSuperAdmin && (_isSuperAdmin || _isOperationalAdmin);

  static const roles = [
    'super_admin',
    'admin',
    'warehouse',
    'produksi',
    'production',
    'finance',
    'hr',
    'host_live',
    'content_creator',
    'unassigned',
  ];

  static const _adminAssignableRoles = [
    'unassigned',
    'warehouse',
    'produksi',
    'production',
    'hr',
    'host_live',
    'content_creator',
  ];

  List<String> get _assignableRoles =>
      _isOperationalAdmin ? _adminAssignableRoles : roles;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authUser = _client.auth.currentUser;
      if (authUser == null) {
        throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');
      }

      final currentProfile = await _client
          .from('users')
          .select('role_id, status, tenant_id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      final currentRoleId =
          currentProfile?['role_id']?.toString().toLowerCase();
      final currentStatus = currentProfile?['status']?.toString();

      if (currentProfile == null || currentStatus != 'active') {
        await _client.auth.signOut();
        throw Exception(
            'Akses akun tidak aktif atau belum valid. Silakan login kembali.');
      }

      final canOpen =
          AppRolePermissions.canManageOperationalUsers(currentRoleId) ||
              AppRolePermissions.isDemoSuperAdminId(currentRoleId);
      if (!canOpen) {
        throw Exception('Halaman user hanya untuk Admin dan Super Admin.');
      }

      var query = _client
          .from('users')
          .select(
              'user_id, tenant_id, nama, username, email, role_id, status, nomor_hp, created_at, updated_at')
          .neq('role_id', 'platform_owner');

      final tenantContext = widget.tenantId?.trim() ?? '';
      if (tenantContext.isNotEmpty && currentRoleId == 'platform_owner') {
        query = query.eq('tenant_id', tenantContext);
      }

      final data = await query.order('created_at', ascending: false);

      final items = (data as List)
          .map((e) => Map<String, dynamic>.from(e))
          .where(
              (e) => AppUi.text(e['role_id']).toLowerCase() != 'platform_owner')
          .toList();

      if (!mounted) return;

      setState(() {
        _currentRoleId = currentRoleId;
        _items = items;
        _applyFilter(_searchController.text, notify: false);
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilter(String value, {bool notify = true}) {
    final keyword = value.trim().toLowerCase();
    final result = _items.where((item) {
      return AppUi.text(item['nama']).toLowerCase().contains(keyword) ||
          AppUi.text(item['email']).toLowerCase().contains(keyword) ||
          AppUi.text(item['username']).toLowerCase().contains(keyword) ||
          AppUi.text(item['role_id']).toLowerCase().contains(keyword);
    }).toList();

    if (notify) {
      setState(() => _filtered = result);
    } else {
      _filtered = result;
    }
  }

  bool _guardDemoUserManagement() {
    if (_canManageUsers) return true;

    AppUi.showSnack(
      _isDemoSuperAdmin
          ? 'Akun demo hanya bisa melihat data user.'
          : 'Akses kelola user tidak tersedia untuk role ini.',
    );
    return false;
  }

  bool _canEditUser(Map<String, dynamic>? user) {
    if (!_canManageUsers) return false;
    if (user == null) return true;
    final targetRole = AppUi.text(user['role_id']).toLowerCase();
    if (targetRole == 'platform_owner') {
      return false;
    }
    if (_isOperationalAdmin &&
        AppRolePermissions.isSensitiveUserRole(targetRole)) {
      return false;
    }
    return true;
  }

  bool _canDeleteUser(Map<String, dynamic> user) {
    if (!_isSuperAdmin || _isDemoSuperAdmin) return false;
    final targetRole = AppUi.text(user['role_id']).toLowerCase();
    if (targetRole == 'platform_owner') {
      return false;
    }
    return !AppRolePermissions.isDemoSuperAdminId(targetRole);
  }

  bool _canAssignRole(String role) {
    if (_isSuperAdmin) return roles.contains(role);
    if (_isOperationalAdmin) {
      return AppRolePermissions.operationalAssignableRoles.contains(role);
    }
    return false;
  }

  String _roleLabel(String roleId) {
    try {
      return appRoleFromRoleId(roleId).label;
    } catch (_) {
      return roleId;
    }
  }

  Future<String?> _getAuthUserIdByEmail(String email) async {
    if (email.trim().isEmpty) return null;

    final data = await _client.rpc(
      'get_auth_user_id_by_email',
      params: {'p_email': email.trim().toLowerCase()},
    );

    final value = data?.toString() ?? '';
    return value.isEmpty ? null : value;
  }

  Future<void> _saveProfile({
    required String? existingId,
    required String authUserId,
    required String nama,
    required String email,
    required String username,
    required String nomorHp,
    required String role,
    required String status,
  }) async {
    if (!_guardDemoUserManagement()) return;

    Map<String, dynamic>? existingUser;
    if (existingId != null) {
      final res = await _client
          .from('users')
          .select()
          .eq('user_id', existingId)
          .maybeSingle();
      if (res != null) {
        existingUser = Map<String, dynamic>.from(res);
      }
    }

    final originalRole = existingUser?['role_id']?.toString();
    final originalTenantId = existingUser?['tenant_id']?.toString();

    String finalRole = role;
    String finalStatus = status;
    String? finalTenantId = originalTenantId;

    if (existingUser != null) {
      if (originalRole != null &&
          AppRolePermissions.isPlatformOwnerId(originalRole)) {
        finalRole = originalRole;
        finalStatus = 'active';
      } else {
        if (originalRole != role) {
          if (!_canAssignRole(role) || originalRole == 'platform_owner') {
            throw Exception(
                'Anda tidak memiliki wewenang untuk mengubah role dari $originalRole ke $role.');
          }
        }
      }
    } else {
      if (AppRolePermissions.isPlatformOwnerId(role)) {
        throw Exception(
            'Tidak dapat membuat user baru dengan role Platform Owner.');
      }
      if (!_canAssignRole(role)) {
        throw Exception(
            'Anda tidak memiliki wewenang untuk mengatur role ke $role.');
      }
      final authUser = _client.auth.currentUser;
      if (authUser != null) {
        final currentProfile = await _client
            .from('users')
            .select('tenant_id')
            .eq('user_id', authUser.id)
            .maybeSingle();
        finalTenantId = currentProfile?['tenant_id']?.toString();
      }
      if (finalTenantId == null) {
        throw Exception('Tenant ID tidak ditemukan untuk user saat ini.');
      }
    }

    final payload = {
      'user_id': authUserId,
      'nama': nama,
      'username': username.isEmpty ? nama : username,
      'email': email,
      'nomor_hp': nomorHp,
      'role_id': finalRole,
      'status': finalStatus,
      if (finalTenantId != null) 'tenant_id': finalTenantId,
      'updated_at': DateTime.now().toIso8601String(),
      if (existingId == null) 'created_at': DateTime.now().toIso8601String(),
    };

    await _client.from('users').upsert(payload);
  }

  Future<void> _openForm([Map<String, dynamic>? user]) async {
    if (!_guardDemoUserManagement()) return;
    if (!_canEditUser(user)) {
      AppUi.showSnack('Akun ini hanya bisa diubah oleh Super Admin.');
      return;
    }

    final idController = TextEditingController(
      text: AppUi.text(user?['user_id'], ''),
    );
    final nameController = TextEditingController(
      text: AppUi.text(user?['nama'], ''),
    );
    final usernameController = TextEditingController(
      text: AppUi.text(user?['username'], ''),
    );
    final emailController = TextEditingController(
      text: AppUi.text(user?['email'], ''),
    );
    final phoneController = TextEditingController(
      text: AppUi.text(user?['nomor_hp'], ''),
    );

    final originalRole = user?['role_id']?.toString();
    final dropdownRoles = List<String>.from(_assignableRoles);
    if (originalRole != null && !dropdownRoles.contains(originalRole)) {
      dropdownRoles.add(originalRole);
    }
    String role = originalRole ?? 'warehouse';
    final bool isRoleEditable = user == null ||
        (_canAssignRole(originalRole ?? '') &&
            originalRole != 'platform_owner');
    String status = AppUi.text(user?['status'], 'active');
    bool saving = false;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> lookupAuthId() async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                rootScaffoldMessengerKey.currentState?.showSnackBar(
                  const SnackBar(content: Text('Isi email dulu')),
                );
                return;
              }

              try {
                setSheetState(() => saving = true);
                final authId = await _getAuthUserIdByEmail(email);
                if (!sheetContext.mounted) return;
                if (authId == null) {
                  rootScaffoldMessengerKey.currentState?.showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Email login belum terdaftar. Buat akun login terlebih dahulu.'),
                    ),
                  );
                } else {
                  idController.text = authId;
                  rootScaffoldMessengerKey.currentState?.showSnackBar(
                    const SnackBar(content: Text('Akun login ditemukan')),
                  );
                }
              } on PostgrestException catch (error) {
                if (!sheetContext.mounted) return;
                rootScaffoldMessengerKey.currentState?.showSnackBar(
                  SnackBar(content: Text(error.message)),
                );
              } finally {
                if (sheetContext.mounted) {
                  setSheetState(() => saving = false);
                }
              }
            }

            Future<void> submit() async {
              var success = false;
              final name = nameController.text.trim();
              final email = emailController.text.trim().toLowerCase();
              var authId = idController.text.trim();

              if (name.isEmpty || email.isEmpty) {
                rootScaffoldMessengerKey.currentState?.showSnackBar(
                  const SnackBar(content: Text('Nama dan email wajib diisi')),
                );
                return;
              }

              try {
                setSheetState(() => saving = true);

                authId = authId.isEmpty
                    ? (await _getAuthUserIdByEmail(email) ?? '')
                    : authId;
                if (authId.isEmpty) {
                  throw Exception(
                    'Akun login belum ditemukan. Buat akun login terlebih dahulu.',
                  );
                }

                await _saveProfile(
                  existingId: user?['user_id']?.toString(),
                  authUserId: authId,
                  nama: name,
                  email: email,
                  username: usernameController.text.trim(),
                  nomorHp: phoneController.text.trim(),
                  role: role,
                  status: status,
                );

                success = true;
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop(true);
              } on PostgrestException catch (error) {
                if (!sheetContext.mounted) return;
                rootScaffoldMessengerKey.currentState?.showSnackBar(
                  SnackBar(content: Text(error.message)),
                );
              } catch (error) {
                if (!sheetContext.mounted) return;
                rootScaffoldMessengerKey.currentState?.showSnackBar(
                  SnackBar(content: Text(error.toString())),
                );
              } finally {
                if (!success && sheetContext.mounted) {
                  setSheetState(() => saving = false);
                }
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 18,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(
                    user == null ? 'Tambah Profile User' : 'Edit User',
                    style:
                        Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Gunakan email login yang sudah terdaftar, lalu simpan profil user.',
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email Login',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: saving ? null : lookupAuthId,
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('Cek Email Login'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: idController,
                    readOnly: user != null,
                    decoration: const InputDecoration(
                      labelText: 'ID Akun Login',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nama',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username / nama tampil',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Nomor HP',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: role,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Role',
                      border: OutlineInputBorder(),
                    ),
                    items: dropdownRoles
                        .map((r) => DropdownMenuItem(
                              value: r,
                              child: Text(_roleLabel(r)),
                            ))
                        .toList(),
                    onChanged: (saving || !isRoleEditable)
                        ? null
                        : (value) {
                            if (value == null) return;
                            setSheetState(() => role = value);
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Aktif')),
                      DropdownMenuItem(
                          value: 'inactive', child: Text('Inactive')),
                    ],
                    onChanged: saving
                        ? null
                        : (value) {
                            if (value == null) return;
                            setSheetState(() => status = value);
                          },
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan User'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      idController.dispose();
      nameController.dispose();
      usernameController.dispose();
      emailController.dispose();
      phoneController.dispose();
    });

    if (result == true) _loadData();
  }

  Future<void> _deleteUser(Map<String, dynamic> user) async {
    if (!_guardDemoUserManagement()) return;
    if (!_canDeleteUser(user)) {
      AppUi.showSnack('Hapus user hanya tersedia untuk Super Admin / Platform Owner.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus user?'),
        content: Text(
            "User ${AppUi.text(user['nama'])} akan dihapus dari aplikasi."),
        actions: [
          TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: const Text('Batal')),
          FilledButton.icon(
            onPressed: () => AppUi.safePop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Hapus'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.rpc('admin_hard_delete_user', params: {
        'p_user_id': user['user_id'],
      });
      AppUi.showSnack('User berhasil dihapus.');
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus user: $error');
    }
  }

  Future<void> _showResetPasswordDialog(Map<String, dynamic> user) async {
    final targetRole = AppUi.text(user['role_id']).toLowerCase();
    if (targetRole == 'platform_owner') {
      AppUi.showSnack(
          'Reset password Platform Owner tidak diijinkan dari tenant context.');
      return;
    }
    final passwordCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Reset Password: ${AppUi.text(user['nama'])}'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password Baru',
                prefixIcon: Icon(Icons.lock),
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) {
                  return 'Password tidak boleh kosong';
                }
                if (val.trim().length < 6) {
                  return 'Password minimal 6 karakter';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      final newPassword = passwordCtrl.text.trim();
      setState(() => _isLoading = true);
      try {
        final response = await _client.functions.invoke(
          'admin-auth',
          body: {
            'action': 'reset_password',
            'userId': user['user_id'],
            'newPassword': newPassword,
          },
        );

        if (response.status == 200) {
          AppUi.showSnack('Password berhasil direset.');
        } else {
          final errorMsg = response.data?['error'] ?? 'Gagal reset password.';
          AppUi.showSnack(errorMsg);
        }
      } catch (e) {
        AppUi.showSnack('Gagal reset password: $e');
      } finally {
        _loadData();
      }
    }
  }

  Widget _body() {
    if (_isLoading) return const LoadingState();

    if (_errorMessage != null) {
      return ErrorState(message: _errorMessage!, onRetry: _loadData);
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          FuturisticHeader(
            icon: Icons.manage_accounts_outlined,
            title: widget.tenantName?.trim().isNotEmpty == true
                ? 'Kelola User / Reset Password'
                : 'Master User',
            subtitle: _isDemoSuperAdmin
                ? 'Mode demo: data user hanya bisa dilihat.'
                : widget.tenantName?.trim().isNotEmpty == true
                    ? 'Tenant ${widget.tenantName}: kelola user aktif dan reset password non-Platform Owner.'
                    : 'Kelola user, role, dan status akun.',
            stats: [
              StatPill(label: 'Total', value: _items.length.toString()),
              StatPill(
                label: 'Aktif',
                value: _items
                    .where((e) => AppUi.text(e['status']) == 'active')
                    .length
                    .toString(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_isDemoSuperAdmin) ...[
            NiceCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Icon(Icons.lock_outline),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Akun demo hanya bisa melihat data user.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ] else if (_isOperationalAdmin) ...[
            NiceCard(
              borderColor: Theme.of(context).colorScheme.secondary,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.admin_panel_settings_outlined,
                      color: Theme.of(context).colorScheme.secondary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Admin dapat mengelola user operasional. Role Super Admin, Admin, dan Finance tetap dikunci.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          SearchBox(
            controller: _searchController,
            onChanged: _applyFilter,
            hint: 'Cari nama, email, username, atau role',
          ),
          const SizedBox(height: 14),
          if (_filtered.isEmpty)
            const EmptyState(
              title: 'Belum ada user',
              subtitle: 'Tambahkan user baru dari halaman ini.',
            )
          else
            ..._filtered.map((user) {
              final color = AppUi.statusColor(AppUi.text(user['status']));
              final canEdit = _canEditUser(user);
              final canDelete = _canDeleteUser(user);

              return NiceCard(
                padding: EdgeInsets.zero,
                onTap: canEdit ? () => _openForm(user) : null,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.14),
                    child: Icon(Icons.person_outline, color: color),
                  ),
                  title: Text(
                    AppUi.text(user['nama']),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${AppUi.text(user['email'])}\n'
                    '${AppUi.text(user['role_id'])} • ${AppUi.text(user['status'])}\n'
                    'ID: ${AppUi.text(user['user_id'])}',
                  ),
                  isThreeLine: true,
                  trailing: (_canManageUsers &&
                          AppUi.text(user['role_id']).toLowerCase() !=
                              'platform_owner')
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') _openForm(user);
                            if (value == 'delete') _deleteUser(user);
                            if (value == 'reset_password')
                              _showResetPasswordDialog(user);
                          },
                          itemBuilder: (context) => [
                            if (canEdit)
                              const PopupMenuItem(
                                  value: 'edit', child: Text('Edit')),
                            if (_currentRoleId == 'platform_owner')
                              const PopupMenuItem(
                                  value: 'reset_password',
                                  child: Text('Reset Password')),
                            if (canDelete)
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Hapus')),
                            if (!canEdit &&
                                !canDelete &&
                                _currentRoleId != 'platform_owner')
                              const PopupMenuItem(
                                  enabled: false,
                                  value: 'locked',
                                  child: Text('Dikunci')),
                          ],
                        )
                      : const Tooltip(
                          message: 'Mode lihat saja',
                          child: Icon(Icons.lock_outline),
                        ),
                ),
              );
            }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Master User'),
        actions: [
          IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: _canManageUsers
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('User'),
            )
          : null,
      body: _body(),
    );
  }
}
