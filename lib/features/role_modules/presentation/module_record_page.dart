import 'package:flutter/material.dart';
import '../../../core/ui/app_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/module_form_config.dart';
import '../models/module_record.dart';
import '../repositories/module_record_repository.dart';

class ModuleRecordPage extends StatefulWidget {
  final String title;
  final String moduleKey;
  final String description;
  final String defaultAssignedRole;
  final bool allowCreate;
  final List<String> statusOptions;

  const ModuleRecordPage({
    super.key,
    required this.title,
    required this.moduleKey,
    required this.description,
    required this.defaultAssignedRole,
    this.allowCreate = true,
    this.statusOptions = const [
      'open',
      'progress',
      'waiting_verification',
      'approved',
      'rejected',
      'done',
    ],
  });

  @override
  State<ModuleRecordPage> createState() => _ModuleRecordPageState();
}

class _ModuleRecordPageState extends State<ModuleRecordPage> {
  final _repository = ModuleRecordRepository();

  bool _isLoading = true;
  String? _errorMessage;
  List<ModuleRecord> _records = [];

  ModuleFormConfig get _config => ModuleFormConfig.fromKey(widget.moduleKey);

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final records = await _repository.getRecords(
        moduleKey: widget.moduleKey,
      );

      if (!mounted) return;

      setState(() {
        _records = records;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openCreateForm() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ModuleRecordFormPage(
          title: widget.title,
          description: widget.description,
          moduleKey: widget.moduleKey,
          defaultAssignedRole: _config.defaultAssignedRole,
          statusOptions: _config.statusOptions,
        ),
      ),
    );

    if (result == true) {
      _loadRecords();
    }
  }

  Future<void> _openUpdateDialog(ModuleRecord record) async {
    String selectedStatus = _config.statusOptions.contains(record.status)
        ? record.status
        : _config.statusOptions.first;

    final noteController = TextEditingController();
    final proofController = TextEditingController(text: record.proofUrl ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(record.title),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      value: selectedStatus,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: _config.statusOptions.map((status) {
                        return DropdownMenuItem<String>(
                          value: status,
                          child: Text(status),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value == null) return;

                        setDialogState(() {
                          selectedStatus = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Catatan Update',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_config.showProof) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: proofController,
                        decoration: InputDecoration(
                          labelText: _config.proofLabel,
                          hintText: _config.proofHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => AppUi.safePop(context, false),
                  child: const Text('Batal'),
                ),
                FilledButton(
                  onPressed: () => AppUi.safePop(context, true),
                  child: const Text('Update'),
                ),
              ],
            );
          },
        );
      },
    );

    final noteText = noteController.text.trim();
    final proofText = proofController.text.trim();

    Future<void>.delayed(const Duration(milliseconds: 700), () {
      noteController.dispose();
      proofController.dispose();
    });

    if (result != true) return;

    try {
      await _repository.updateStatus(
        recordId: record.recordId,
        status: selectedStatus,
        note: noteText.isEmpty ? null : noteText,
        proofUrl: proofText.isEmpty ? null : proofText,
      );

      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Data berhasil diupdate')),
      );

      _loadRecords();
    } on PostgrestException catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal update: $error')),
      );
    }
  }

  String _formatDate(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');

    return '${two(value.day)}/${two(value.month)}/${value.year} ${two(value.hour)}:${two(value.minute)}';
  }

  String _formatNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }

    return value.toStringAsFixed(2);
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          NiceCard(
            child: Text(
              widget.description,
              style: TextStyle(
                color:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.72),
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_records.isEmpty)
            const NiceCard(
              child: Text('Belum ada data.'),
            )
          else
            ..._records.map((record) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NiceCard(
                  padding: EdgeInsets.zero,
                  onTap: () => _openUpdateDialog(record),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity(0.12),
                      foregroundColor: Theme.of(context).colorScheme.primary,
                      child: const Icon(Icons.folder_copy_outlined),
                    ),
                    title: Text(
                      record.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      'Status: ${record.status}\n'
                      'Assign: ${record.assignedRole ?? '-'}\n'
                      '${_config.amountLabel}: ${_formatNumber(record.amount)}\n'
                      'Pembuat: ${record.createdByName ?? '-'} | ${record.createdByEmail ?? '-'}\n'
                      'Bukti: ${record.proofUrl ?? '-'}\n'
                      'Tanggal: ${_formatDate(record.createdAt)}\n\n'
                      '${record.description ?? '-'}',
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(0.68),
                        height: 1.35,
                      ),
                    ),
                    isThreeLine: false,
                    trailing: const Icon(Icons.chevron_right),
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
        title: Text(widget.title),
      ),
      floatingActionButton: widget.allowCreate
          ? FloatingActionButton.extended(
              onPressed: _openCreateForm,
              icon: const Icon(Icons.add),
              label: const Text('Tambah'),
            )
          : null,
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }
}

class ModuleRecordFormPage extends StatefulWidget {
  final String title;
  final String description;
  final String moduleKey;
  final String defaultAssignedRole;
  final List<String> statusOptions;

  const ModuleRecordFormPage({
    super.key,
    required this.title,
    required this.description,
    required this.moduleKey,
    required this.defaultAssignedRole,
    required this.statusOptions,
  });

  @override
  State<ModuleRecordFormPage> createState() => _ModuleRecordFormPageState();
}

class _ModuleRecordFormPageState extends State<ModuleRecordFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _repository = ModuleRecordRepository();

  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController(text: '0');
  final _proofController = TextEditingController();

  bool _isSaving = false;

  late String _assignedRole;
  late String _status;

  ModuleFormConfig get _config => ModuleFormConfig.fromKey(widget.moduleKey);

  final List<String> _roleOptions = const [
    'super_admin',
    'admin',
    'warehouse',
    'produksi',
    'finance',
    'host_live',
    'hr',
    'content_creator',
  ];

  @override
  void initState() {
    super.initState();

    _assignedRole = _roleOptions.contains(_config.defaultAssignedRole)
        ? _config.defaultAssignedRole
        : widget.defaultAssignedRole;

    if (!_roleOptions.contains(_assignedRole)) {
      _assignedRole = 'super_admin';
    }

    _status = _config.statusOptions.contains(_config.defaultStatus)
        ? _config.defaultStatus
        : _config.statusOptions.first;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _amountController.dispose();
    _proofController.dispose();
    super.dispose();
  }

  String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Wajib diisi';
    }

    return null;
  }

  double _parseAmount() {
    if (!_config.showAmount) return 0;

    return double.tryParse(
          _amountController.text.trim().replaceAll(',', '.'),
        ) ??
        0;
  }

  String _roleLabel(String roleId) {
    switch (roleId) {
      case 'super_admin':
        return 'Super Admin';
      case 'admin':
        return 'Admin';
      case 'warehouse':
        return 'Warehouse';
      case 'produksi':
        return 'Produksi';
      case 'finance':
        return 'Finance';
      case 'host_live':
        return 'Host Live';
      case 'hr':
        return 'HR';
      case 'content_creator':
        return 'Content Creator';
      default:
        return roleId;
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await _repository.createRecord(
        moduleKey: widget.moduleKey,
        title: _titleController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        amount: _parseAmount(),
        assignedRole: _config.showAssignedRole
            ? _assignedRole
            : _config.defaultAssignedRole,
        status: _status,
        proofUrl: _config.showProof && _proofController.text.trim().isNotEmpty
            ? _proofController.text.trim()
            : null,
      );

      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Data berhasil dibuat')),
      );

      AppUi.safePop(context, true);
    } on PostgrestException catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (error) {
      if (!mounted) return;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Gagal simpan: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;

    return Scaffold(
      appBar: AppBar(
        title: Text('Tambah ${widget.title}'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NiceCard(
              child: Text(
                widget.description,
                style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSurface.withOpacity(0.72),
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 12),
            NiceCard(
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _titleController,
                      validator: _required,
                      decoration: InputDecoration(
                        labelText: config.titleLabel,
                        hintText: config.titleHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _descriptionController,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: config.descriptionLabel,
                        hintText: config.descriptionHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (config.showAmount) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: config.amountLabel,
                          hintText: 'Isi angka, boleh 0 kalau tidak perlu',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (config.showAssignedRole) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _assignedRole,
                        decoration: const InputDecoration(
                          labelText: 'Assign ke Role',
                          border: OutlineInputBorder(),
                        ),
                        items: _roleOptions.map((role) {
                          return DropdownMenuItem<String>(
                            value: role,
                            child: Text(_roleLabel(role)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value == null) return;

                          setState(() {
                            _assignedRole = value;
                          });
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _status,
                      decoration: const InputDecoration(
                        labelText: 'Status Awal',
                        border: OutlineInputBorder(),
                      ),
                      items: config.statusOptions.map((status) {
                        return DropdownMenuItem<String>(
                          value: status,
                          child: Text(status),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value == null) return;

                        setState(() {
                          _status = value;
                        });
                      },
                    ),
                    if (config.showProof) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _proofController,
                        decoration: InputDecoration(
                          labelText: config.proofLabel,
                          hintText: config.proofHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_isSaving ? 'Menyimpan...' : 'Simpan'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
