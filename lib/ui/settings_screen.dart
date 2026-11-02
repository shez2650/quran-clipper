import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/storage.dart';
import '../services/youtube_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final settings = SettingsStore.instance;
  final yt = YouTubeService.instance;
  late final _id = TextEditingController(text: settings.googleClientId);
  late final _secret = TextEditingController(text: settings.googleClientSecret);
  bool _busy = false;
  String? _message;

  Future<void> _importJson() async {
    final f = await FilePicker.pickFile(
      dialogTitle: 'Choose the client_secret….json file',
      type: FileType.any,
    );
    if (f == null) return;
    try {
      final text = await f.xFile.readAsString();
      final (id, secret) = YouTubeService.parseClientSecretJson(text);
      _id.text = id;
      _secret.text = secret;
      _saveClient();
    } catch (e) {
      setState(() => _message = 'Could not read that file: $e');
    }
  }

  void _saveClient() {
    final changed = _id.text.trim() != settings.googleClientId;
    settings.setGoogleClient(_id.text, _secret.text);
    if (changed) yt.signOut();
    setState(() => _message = 'Saved.');
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await yt.signIn();
      setState(() => _message = 'Signed in${yt.channelTitle != null ? ' as ${yt.channelTitle}' : ''}.');
    } catch (e) {
      setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text('Importing', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Download video with YouTube links'),
                subtitle: const Text('Off saves data and space. Audio is always downloaded.'),
                value: settings.downloadVideoByDefault,
                onChanged: (v) => setState(() => settings.downloadVideoByDefault = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Export defaults'),
                subtitle: const Text('Change them on the Export screen and press "Make these my defaults".'),
              ),
              const Divider(height: 32),
              Text('YouTube upload', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            yt.isSignedIn ? Icons.check_circle : Icons.info_outline,
                            color: yt.isSignedIn ? t.colorScheme.primary : t.colorScheme.outline,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              !yt.isConfigured
                                  ? 'Not set up yet: follow the steps below once.'
                                  : yt.isSignedIn
                                      ? 'Signed in${yt.channelTitle != null ? ' as ${yt.channelTitle}' : ''}'
                                      : 'Client added: sign in to finish.',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (yt.isConfigured && !yt.isSignedIn)
                            FilledButton.icon(
                              onPressed: _busy ? null : _signIn,
                              icon: const Icon(Icons.login),
                              label: const Text('Sign in with Google'),
                            ),
                          if (yt.isSignedIn)
                            OutlinedButton(
                              onPressed: () async {
                                await yt.signOut();
                                setState(() {});
                              },
                              child: const Text('Sign out'),
                            ),
                        ],
                      ),
                      if (_message != null) ...[const SizedBox(height: 8), SelectableText(_message!)],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: !yt.isConfigured,
                title: const Text('One-time Google setup (about 5 minutes)'),
                childrenPadding: const EdgeInsets.only(bottom: 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Step(1, 'Open Google Cloud Console and create a new project called "Quran Clipper".'),
                  _LinkButton('console.cloud.google.com/projectcreate', 'https://console.cloud.google.com/projectcreate'),
                  const _Step(2, 'Enable the "YouTube Data API v3" for that project.'),
                  _LinkButton('Enable YouTube Data API v3',
                      'https://console.cloud.google.com/apis/library/youtube.googleapis.com'),
                  const _Step(3, 'Open "Google Auth Platform" and press Get started. App name: Quran Clipper. '
                      'Support email: your Gmail. Audience: External. Contact email: your Gmail. Agree and Create.'),
                  _LinkButton('Google Auth Platform', 'https://console.cloud.google.com/auth/overview'),
                  const _Step(4, 'Go to Audience, then Test users, then Add users, and add your own Gmail address '
                      '(the one that owns your YouTube channel).'),
                  _LinkButton('Audience / test users', 'https://console.cloud.google.com/auth/audience'),
                  const _Step(5, 'Go to Clients, then Create client. Application type: Desktop app. Name: Quran Clipper. '
                      'Create, then Download JSON.'),
                  _LinkButton('Clients', 'https://console.cloud.google.com/auth/clients'),
                  const _Step(6, 'Come back here and import that JSON file (or paste the Client ID and secret below). '
                      'The same client works on your phone, Mac and Windows: do this on each device '
                      '(you can email yourself the JSON file).'),
                  const SizedBox(height: 8),
                  Text(
                    'Good to know: while the app stays in "Testing", Google may ask you to sign in again about once a week. '
                    'Uploads from unreviewed personal projects are always Private, which suits a private playlist.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _importJson,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import client_secret JSON file'),
              ),
              const SizedBox(height: 16),
              TextField(controller: _id, decoration: const InputDecoration(labelText: 'Client ID')),
              const SizedBox(height: 12),
              TextField(
                controller: _secret,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Client secret'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(onPressed: _saveClient, child: const Text('Save')),
              ),
              const Divider(height: 32),
              Text('Storage', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
              const SizedBox(height: 8),
              SelectableText('Projects and downloads: ${ProjectStore.instance.root.path}', style: t.textTheme.bodySmall),
              if (isDesktop) ...[
                const SizedBox(height: 4),
                FutureBuilder(
                  future: desktopExportDir(),
                  builder: (_, snap) =>
                      SelectableText('Exports: ${snap.data?.path ?? '…'}', style: t.textTheme.bodySmall),
                ),
              ] else
                Text('Exports: use Save or Share after exporting.', style: t.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(radius: 11, child: Text('$n', style: const TextStyle(fontSize: 12))),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _LinkButton extends StatelessWidget {
  const _LinkButton(this.label, this.url);
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 30),
        child: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(label),
        ),
      );
}
