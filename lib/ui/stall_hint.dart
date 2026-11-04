import 'dart:io';

import 'package:flutter/material.dart';

/// How long a job can sit at the start before saying why it might be waiting.
const stallHintAfter = Duration(seconds: 10);

String stallHintText({required bool macOS}) => macOS
    ? 'Waiting to start. If macOS is asking to let Quran Clipper use a folder, choose Allow.'
    : 'Still starting. This can take a moment with a long file.';

/// Explains a job that hasn't got going yet. macOS holds a file open until its
/// privacy prompt is answered, which otherwise looks like a freeze at 0%.
class StallHint extends StatelessWidget {
  const StallHint({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              stallHintText(macOS: Platform.isMacOS),
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
