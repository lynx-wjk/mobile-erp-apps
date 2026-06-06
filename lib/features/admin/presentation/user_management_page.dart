import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/app_roles.dart';
import '../../../core/ui/app_ui.dart';

class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});

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
          .select('role_id, status')
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

      final data = await _client
          .from('users')
          .select(
              'user_id, nama, username, email, role_id, status, nomor_hp, created_at, updated_at')
          .order('created_at', ascending: false);

      final items =
          (data as List).map((e) => Map<String, dynamic>.from(e)).toList();

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
    if (_isOperationalAdmin &&
        AppRolePermissions.isSensitiveUserRole(targetRole)) {
      return false;
    }
    return true;
  }

  bool _canDeleteUser(Map<String, dynamic> user) {
    if (!_isSuperAdmin || _isDemoSuperAdmin) return false;
    final targetRole = AppUi.text(user['role_id']).toLowerCase();
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
    if (!_canAssignRole(role)) {
      throw Exception('Role ini hanya bisa diatur oleh Super Admin.');
    }

    final payload = {
      'user_id': authUserId,
      'nama': nama,
      'username': username.isEmpty ? nama : username,
      'email': email,
      'nomor_hp': nomorHp,
      'role_id': role,
      'status': status,
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

    String role = _assignableRoles.contains(user?['role_id'])
        ? user!['role_id'].toString()
        : 'warehouse';
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
                              fontWeight: FontWeight.w900,
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
                    items: _assignableRoles
                        .map((role) => DropdownMenuItem(
                              value: role,
                              child: Text(_roleLabel(role)),
                            ))
                        .toList(),
                    onChanged: saving
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
      AppUi.showSnack('Hapus user hanya tersedia untuk Super Admin.');
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
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'users',
        'p_record_id': user['user_id'].toString(),
      });
      AppUi.showSnack('User berhasil dihapus.');
      await _loadData();
    } on PostgrestException catch (error) {
      AppUi.showSnack(error.message);
    } catch (error) {
      AppUi.showSnack('Gagal menghapus user: $error');
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
            title: 'Master User',
            subtitle: _isDemoSuperAdmin
                ? 'Mode demo: data user hanya bisa dilihat.'
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
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${AppUi.text(user['email'])}\n'
                    '${AppUi.text(user['role_id'])} • ${AppUi.text(user['status'])}\n'
                    'ID: ${AppUi.text(user['user_id'])}',
                  ),
                  isThreeLine: true,
                  trailing: _canManageUsers
                      ? PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'edit') _openForm(user);
                            if (value == 'delete') _deleteUser(user);
                          },
                          itemBuilder: (context) => [
                            if (canEdit)
                              const PopupMenuItem(
                                  value: 'edit', child: Text('Edit')),
                            if (canDelete)
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Hapus')),
                            if (!canEdit && !canDelete)
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
