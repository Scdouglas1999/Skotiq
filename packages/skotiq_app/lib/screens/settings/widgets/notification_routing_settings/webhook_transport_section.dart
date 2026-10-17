part of '../notification_routing_settings.dart';

class _WebhookTransportSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _WebhookTransportSection({required this.isMobile});

  @override
  ConsumerState<_WebhookTransportSection> createState() =>
      _WebhookTransportSectionState();
}

class _WebhookTransportSectionState
    extends ConsumerState<_WebhookTransportSection> {
  final _url = TextEditingController();
  final _body = TextEditingController();
  final _headers = TextEditingController();
  bool _initialized = false;

  @override
  void dispose() {
    _url.dispose();
    _body.dispose();
    _headers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(webhookTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        _initialized = false;
        return _transportErrorSection(
          title: 'Generic webhook',
          error: e,
          onRetry: () => ref.invalidate(webhookTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _url.text = cfg.url;
          _body.text = cfg.bodyTemplate ?? '';
          _headers.text =
              cfg.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final url = _url.text.trim();
          final urlError = _validateUrlField(url);
          if (urlError != null) return _PrepResult.fail(urlError);
          final parsedHeaders = _parseHeaderLines(_headers.text);
          if (parsedHeaders.error != null) {
            return _PrepResult.fail(parsedHeaders.error);
          }
          final templateError = _validateWebhookBodyTemplate(_body.text);
          if (templateError != null) return _PrepResult.fail(templateError);
          final cfg2 = WebhookTransportConfig(
            url: url,
            headers: parsedHeaders.headers!,
            bodyTemplate: _body.text.trim().isEmpty ? null : _body.text,
          );
          await ref.read(webhookTransportConfigProvider.notifier).save(cfg2);
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'Generic webhook',
          children: [
            SettingRow(
              icon: LucideIcons.link,
              title: 'URL',
              subtitle: 'POST target (Home Assistant, n8n, etc.)',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _url,
                hint: 'https://example.com/webhook',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.fileText,
              title: 'Body template',
              subtitle: r'Variables: ${title} ${body} ${category} ${timestamp}',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _body,
                hint: '{"text":"\${title}"}',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.list,
              title: 'Headers',
              subtitle: 'One per line, format: Name: value',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _headers,
                hint: 'Authorization: Bearer …',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save webhook config',
              trailing: _SaveButton(
                successMessage: 'Webhook config saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test webhook',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.webhookGeneric,
                onBeforeSend: saveConfig,
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}

// Pushover (routing-aware)
