import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/time_format.dart';
import '../services/storage.dart';
import 'export_screen.dart';
import 'mark_screen.dart';

/// The screen a project opens on, depending on what it's being used for.
Widget screenFor(Project p) {
  if (p.reverbOnly) return ExportScreen(project: p);
  return p.segments.isEmpty ? ChooseScreen(project: p) : MarkScreen(project: p);
}

/// Asks what to do with a file or link that has just been opened.
class ChooseScreen extends StatelessWidget {
  const ChooseScreen({super.key, required this.project});
  final Project project;

  void _replaceWith(BuildContext context, Widget screen) =>
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _justReverb(BuildContext context) async {
    project.useWholeFile();
    await ProjectStore.instance.save(project);
    if (context.mounted) _replaceWith(context, ExportScreen(project: project));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final canReverb = project.canUseWholeFile;
    return Scaffold(
      appBar: AppBar(title: const Text('What would you like to do?')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(project.title, style: t.textTheme.titleLarge, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
                if (canReverb) ...[
                  const SizedBox(height: 4),
                  Text(
                    formatLength(project.duration),
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                _Option(
                  icon: Icons.content_cut,
                  title: 'Mark and clip',
                  description: 'Choose the parts you want, cut out the talking and join them. You can still add the reverb when you export.',
                  onTap: () => _replaceWith(context, MarkScreen(project: project)),
                ),
                const SizedBox(height: 12),
                _Option(
                  icon: Icons.spatial_audio_off,
                  title: 'Just add reverb',
                  description: canReverb
                      ? 'Put the whole file straight through the masjid reverb, with no cutting.'
                      : "This file's length couldn't be read, so it has to be marked by hand.",
                  onTap: canReverb ? () => _justReverb(context) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.description, required this.onTap});
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: onTap != null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: CircleAvatar(
          backgroundColor: c.primaryContainer,
          child: Icon(icon, color: c.onPrimaryContainer),
        ),
        title: Text(title),
        subtitle: Text(description),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
