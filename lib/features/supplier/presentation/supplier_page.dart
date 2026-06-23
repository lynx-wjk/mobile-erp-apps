import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/ui/app_ui.dart';
import '../models/supplier.dart';

class SupplierPage extends StatefulWidget {
  const SupplierPage({super.key});

  @override
  State<SupplierPage> createState() => _SupplierPageState();
}

class _SupplierPageState extends State<SupplierPage> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  bool _isSuperAdmin = false;
  String? _errorMessage;
  List<Supplier> _items = [];
  List<Supplier> _filtered = [];

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
      final currentUserId = _client.auth.currentUser?.id;
      if (currentUserId != null) {
        final profile = await _client
            .from('users')
            .select('role_id')
            .eq('user_id', currentUserId)
            .maybeSingle();
        _isSuperAdmin = profile?['role_id']?.toString() == 'super_admin';
      }

      final data = await _client
          .from('suppliers')
          .select(
              'supplier_id, nama_supplier, nama, kontak, phone, alamat, catatan, status')
          .order('created_at', ascending: false);

      final items = (data as List)
          .map((item) => Supplier.fromMap(Map<String, dynamic>.from(item)))
          .toList();

      if (!mounted) return;

      setState(() {
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
      return item.namaSupplier.toLowerCase().contains(keyword) ||
          item.kontak.toLowerCase().contains(keyword) ||
          item.alamat.toLowerCase().contains(keyword);
    }).toList();

    if (notify) {
      setState(() => _filtered = result);
    } else {
      _filtered = result;
    }
  }

  Future<void> _openForm([Supplier? supplier]) async {
    final nameController =
        TextEditingController(text: supplier?.namaSupplier ?? '');
    final contactController =
        TextEditingController(text: supplier?.kontak ?? '');
    final addressController =
        TextEditingController(text: supplier?.alamat ?? '');
    final noteController = TextEditingController(text: supplier?.catatan ?? '');
    String status = supplier?.status == 'inactive' ? 'inactive' : 'active';
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
            Future<void> submit() async {
              final name = nameController.text.trim();

              if (name.isEmpty) {
                AppUi.safeSnack(sheetContext, 'Nama supplier wajib diisi');
                return;
              }

              var success = false;
              try {
                setSheetState(() => saving = true);

                final payload = {
                  if (supplier != null && supplier.supplierId.isNotEmpty)
                    'supplier_id': supplier.supplierId,
                  'nama_supplier': name,
                  'nama': name,
                  'kontak': contactController.text.trim(),
                  'phone': contactController.text.trim(),
                  'alamat': addressController.text.trim(),
                  'catatan': noteController.text.trim(),
                  'status': status,
                  'updated_at': DateTime.now().toIso8601String(),
                  if (supplier == null)
                    'created_at': DateTime.now().toIso8601String(),
                };

                await _client.from('suppliers').upsert(payload);

                success = true;
                AppUi.safePop(sheetContext, true);
              } on PostgrestException catch (error) {
                AppUi.safeSnack(sheetContext, error.message);
              } catch (error) {
                AppUi.safeSnack(sheetContext, 'Gagal simpan supplier: $error');
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
                    supplier == null ? 'Tambah Supplier' : 'Edit Supplier',
                    style:
                        Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nama Supplier',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: contactController,
                    decoration: const InputDecoration(
                      labelText: 'Kontak / Nomor HP',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: addressController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Alamat',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Catatan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: status,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'active', child: Text('Active')),
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
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label: Text(saving ? 'Menyimpan...' : 'Simpan'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      nameController.dispose();
      contactController.dispose();
      addressController.dispose();
      noteController.dispose();
    });

    if (result == true) await _loadData();
  }

  Future<void> _delete(Supplier supplier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Hapus Supplier?'),
          content: Text(
              'Supplier "${supplier.namaSupplier}" akan dihapus permanen. Pastikan data ini tidak lagi dipakai transaksi.'),
          actions: [
            TextButton(
              onPressed: () => AppUi.safePop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => AppUi.safePop(context, true),
              child: const Text('Hapus'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    try {
      await _client.rpc('delete_record_for_super_admin', params: {
        'p_table_name': 'suppliers',
        'p_record_id': supplier.supplierId,
      });

      AppUi.showSnack('Supplier berhasil dihapus.');
      _loadData();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
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
            icon: Icons.local_shipping_outlined,
            title: 'Supplier',
            subtitle:
                'Kelola supplier untuk referensi pembelian. Pembelian tetap bisa memakai supplier manual bila belum terdaftar.',
            stats: [
              StatPill(label: 'Total', value: _items.length.toString()),
              StatPill(
                label: 'Active',
                value:
                    _items.where((e) => e.status == 'active').length.toString(),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SearchBox(
            controller: _searchController,
            onChanged: _applyFilter,
            hint: 'Cari supplier',
          ),
          const SizedBox(height: 14),
          if (_filtered.isEmpty)
            const EmptyState(
              title: 'Supplier kosong',
              subtitle: 'Tambahkan supplier, atau input manual di pembelian.',
            )
          else
            ..._filtered.map((item) {
              final color = AppUi.statusColor(item.status);

              return NiceCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: CircleAvatar(
                    backgroundColor: color.withOpacity(0.13),
                    child: Icon(Icons.storefront_outlined, color: color),
                  ),
                  title: Text(
                    item.namaSupplier,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${item.kontak.isEmpty ? '-' : item.kontak}\n'
                    '${item.alamat.isEmpty ? '-' : item.alamat}\n'
                    'Status: ${item.status}',
                  ),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') _openForm(item);
                      if (value == 'delete') _delete(item);
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (_isSuperAdmin)
                        const PopupMenuItem(
                            value: 'delete', child: Text('Hapus')),
                    ],
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
        title: const Text('Supplier'),
        actions: [
          IconButton(onPressed: _loadData, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Supplier'),
      ),
      body: _body(),
    );
  }
}
