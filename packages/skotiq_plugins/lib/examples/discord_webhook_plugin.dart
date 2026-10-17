// Discord Webhook plugin — adds a sequence node that posts a Discord
// message (with optional embed) to a webhook URL configured per-node.
//
// Why "per-node" rather than per-plugin credentials: Discord webhook URLs
// are the credential. Operators commonly route different sequence steps
// to different channels (e.g. "imaging-rig-1" vs "imaging-alerts"), so
// it is friendlier to let each node carry its own URL than to force a
// global webhook + a per-node channel id.
//
// Configuration parameters:
// * `webhookUrl` (String, required): the Discord webhook URL.
// * `username` (String, optional): override the webhook display name.
// * `content` (String, optional): message body (omit if using an embed only).
// * `embedTitle` (String, optional): embed title.
// * `embedDescription` (String, optional): embed description.
// * `embedColor` (int, optional, default 0x3498db): RGB color for the
//   embed sidebar.
//
// At least one of `content`, `embedTitle`, `embedDescription` MUST be
// non-empty; otherwise the node validates as invalid.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../src/plugin_api.dart';

/// True only for Discord itself or one of its subdomains. A plain
/// `endsWith('discord.com')` check also accepts attacker-controlled hosts such
/// as `evil-discord.com`.
bool isDiscordWebhookHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'discord.com' ||
      normalized.endsWith('.discord.com') ||
      normalized == 'discordapp.com' ||
      normalized.endsWith('.discordapp.com');
}

class DiscordWebhookPlugin extends SequencePlugin {
  /// Optional HTTP client factory (test seam).
  final http.Client Function()? clientBuilder;

  DiscordWebhookPlugin({this.clientBuilder});

  /// Live plugin context. The Discord plugin does not persist any
  /// per-plugin state today (every credential lives on the node itself),
  /// but holding the context lets us log lifecycle transitions through
  /// the host-supplied logger so the user sees the plugin on the
  /// Settings > Plugins page.
  PluginContext? get context => _context;
  PluginContext? _context;

  @override
  String get id => 'com.skotiq.examples.discord_webhook';

  @override
  String get name => 'Discord Webhook';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Adds a sequence node that posts a Discord message via a webhook URL. '
      'Each node carries its own URL so the same sequence can route '
      'different steps to different channels.';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info(
      'Discord Webhook plugin loaded; nodes: ${nodeDefinitions.length}',
    );
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'discord.webhook',
      name: 'Discord Webhook',
      category: 'Notifications',
      description:
          'Send a Discord message via a configured webhook URL. '
          'Supports plain content and / or rich embeds.',
      createNode: (params) {
        final url = (params['webhookUrl'] as String? ?? '').trim();
        final username = (params['username'] as String?)?.trim();
        final content = (params['content'] as String?)?.trim();
        final embedTitle = (params['embedTitle'] as String?)?.trim();
        final embedDescription = (params['embedDescription'] as String?)
            ?.trim();
        final embedColor = (params['embedColor'] as num?)?.toInt() ?? 0x3498db;
        return _DiscordWebhookNode(
          webhookUrl: url,
          username: (username == null || username.isEmpty) ? null : username,
          content: (content == null || content.isEmpty) ? null : content,
          embedTitle: (embedTitle == null || embedTitle.isEmpty)
              ? null
              : embedTitle,
          embedDescription:
              (embedDescription == null || embedDescription.isEmpty)
              ? null
              : embedDescription,
          embedColor: embedColor,
          clientBuilder: clientBuilder ?? http.Client.new,
        );
      },
    ),
  ];
}

class _DiscordWebhookNode implements PluginSequenceNode {
  final String webhookUrl;
  final String? username;
  final String? content;
  final String? embedTitle;
  final String? embedDescription;
  final int embedColor;
  final http.Client Function() clientBuilder;

  _DiscordWebhookNode({
    required this.webhookUrl,
    required this.username,
    required this.content,
    required this.embedTitle,
    required this.embedDescription,
    required this.embedColor,
    required this.clientBuilder,
  });

  @override
  String? validate() {
    if (webhookUrl.isEmpty) return 'Discord webhook URL is required';
    final parsed = Uri.tryParse(webhookUrl);
    if (parsed == null || parsed.scheme != 'https') {
      return 'Discord webhook URL must be an https URL';
    }
    if (!isDiscordWebhookHost(parsed.host)) {
      return 'Webhook URL host must be discord.com or discordapp.com '
          '(got ${parsed.host})';
    }
    final hasContent = content != null && content!.isNotEmpty;
    final hasEmbed =
        (embedTitle != null && embedTitle!.isNotEmpty) ||
        (embedDescription != null && embedDescription!.isNotEmpty);
    if (!hasContent && !hasEmbed) {
      return 'Provide at least one of: content, embedTitle, embedDescription';
    }
    if (embedColor < 0 || embedColor > 0xFFFFFF) {
      return 'embedColor must be in 0x000000..0xFFFFFF';
    }
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    final payload = <String, dynamic>{};
    if (username != null) payload['username'] = username;
    if (content != null) payload['content'] = content;
    final hasEmbed =
        (embedTitle != null && embedTitle!.isNotEmpty) ||
        (embedDescription != null && embedDescription!.isNotEmpty);
    if (hasEmbed) {
      final embed = <String, dynamic>{
        'color': embedColor,
        if (embedTitle != null) 'title': embedTitle,
        if (embedDescription != null) 'description': embedDescription,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
      payload['embeds'] = [embed];
    }

    final client = clientBuilder();
    try {
      context.logger.info(
        'Posting Discord webhook (${hasEmbed ? "embed" : "content"})',
      );
      final response = await client.post(
        Uri.parse(webhookUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      // Discord responds 204 No Content on success.
      if (response.statusCode == 204 || response.statusCode == 200) {
        context.eventBus.emit('plugin.discord.sent', {
          'has_content': content != null,
          'has_embed': hasEmbed,
        });
        return true;
      }
      context.logger.error(
        'Discord webhook returned ${response.statusCode}: ${response.body}',
      );
      return false;
    } catch (e, stackTrace) {
      context.logger.error('Discord webhook POST threw', e, stackTrace);
      return false;
    } finally {
      client.close();
    }
  }
}
