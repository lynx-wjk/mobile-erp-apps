import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_ui.dart';

class AiChatAssistantSheet extends StatefulWidget {
  final String? initialPrompt;
  final String title;
  final String subtitle;
  final String? tenantId;

  const AiChatAssistantSheet({
    super.key,
    this.initialPrompt,
    this.title = '🤖 Antigravity AI Chat Assistant',
    this.subtitle = 'Tanyakan data store, omzet real, stok SKU, atau strategi marketing',
    this.tenantId,
  });

  static Future<void> show(
    BuildContext context, {
    String? initialPrompt,
    String title = '🤖 Antigravity AI Chat Assistant',
    String subtitle = 'Tanyakan data store, omzet real, stok SKU, atau strategi marketing',
    String? tenantId,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AiChatAssistantSheet(
        initialPrompt: initialPrompt,
        title: title,
        subtitle: subtitle,
        tenantId: tenantId,
      ),
    );
  }

  @override
  State<AiChatAssistantSheet> createState() => _AiChatAssistantSheetState();
}

class _AiChatAssistantSheetState extends State<AiChatAssistantSheet> {
  final SupabaseClient _client = Supabase.instance.client;
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<Map<String, String>> _messages = [];
  bool _isSending = false;

  final List<String> _suggestedPrompts = [
    '💡 Berapa total omzet Shopee vs TikTok?',
    '📦 Berapa SKU yang unmapped dan perlu pemetaan?',
    '📈 Buatkan strategi promosi bundling untuk naikkan AOV',
    '🛡️ Bagaimana status kesehatan server VPS, CPU, dan RAM?',
  ];

  @override
  void initState() {
    super.initState();
    _messages.add({
      'role': 'assistant',
      'content':
          'Halo! Saya **Antigravity AI Assistant**. Saya terhubung langsung ke database live toko Anda.\n\nAnda dapat menanyakan data omzet real, perbandingan Shopee vs TikTok, stok unmapped SKU, atau strategi penjualan!'
    });

    if (widget.initialPrompt != null && widget.initialPrompt!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sendMessage(widget.initialPrompt!);
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    final query = text.trim();
    if (query.isEmpty || _isSending) return;

    _inputCtrl.clear();
    setState(() {
      _messages.add({'role': 'user', 'content': query});
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final response = await _client.functions.invoke(
        'ai-insights-engine',
        body: <String, dynamic>{
          'action': 'chat',
          'prompt': query,
          'tenant_id': widget.tenantId,
          'messages': _messages,
        },
      );

      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};

      if (response.status == 200 && data['ok'] == true) {
        final reply = data['reply']?.toString() ?? 'Tanggapan AI tidak tersedia.';
        if (mounted) {
          setState(() {
            _messages.add({'role': 'assistant', 'content': reply});
          });
        }
      } else {
        final err = data['error'] ?? 'Gagal memuat AI Chat';
        if (mounted) {
          setState(() {
            _messages.add({'role': 'assistant', 'content': '⚠️ Error: $err'});
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add({'role': 'assistant', 'content': '⚠️ Koneksi AI terputus: $e'});
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        widget.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Chat Messages Stream
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_isSending ? 1 : 0),
              itemBuilder: (context, idx) {
                if (idx == _messages.length && _isSending) {
                  return _buildTypingIndicator(theme);
                }
                final msg = _messages[idx];
                final isUser = msg['role'] == 'user';
                return _buildMessageBubble(theme, msg['content'] ?? '', isUser);
              },
            ),
          ),

          // Suggested Quick Prompts (if chat is fresh)
          if (_messages.length <= 2 && !_isSending)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: _suggestedPrompts.map((p) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(p, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                      backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                      onPressed: () => _sendMessage(p.replaceAll(RegExp(r'^[^\w]+'), '').trim()),
                    ),
                  );
                }).toList(),
              ),
            ),

          // Input Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (val) => _sendMessage(val),
                    decoration: InputDecoration(
                      hintText: 'Tanyakan data toko atau strategi...',
                      hintStyle: const TextStyle(fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  onPressed: _isSending
                      ? null
                      : () => _sendMessage(_inputCtrl.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ThemeData theme, String text, bool isUser) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isUser
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildTypingIndicator(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Antigravity AI sedang menganalisa data live...',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.7),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
