import 'package:flutter/material.dart';

class MediaControls extends StatelessWidget {
  final double scrubPosition;
  final Duration duration;
  final String outputFormat;
  final double bitrate;
  final double maxBitrate;
  final bool isCompressing;
  final bool isPreviewing;
  final double progress;
  final String? originalSize;
  final String estimatedSize;
  final bool hasAv1Hardware;
  final ValueChanged<double> onScrubChanged;
  final ValueChanged<double> onScrubEnd;
  final ValueChanged<String?> onFormatChanged;
  final ValueChanged<double> onBitrateChanged;
  final ValueChanged<double> onBitrateEnd;
  final VoidCallback onClear;
  final VoidCallback onSave;
  final List<DropdownMenuItem<String>> formatItems;

  const MediaControls({
    super.key,
    required this.scrubPosition,
    required this.duration,
    required this.outputFormat,
    required this.bitrate,
    required this.maxBitrate,
    required this.isCompressing,
    required this.isPreviewing,
    required this.progress,
    this.originalSize,
    required this.estimatedSize,
    required this.hasAv1Hardware,
    required this.onScrubChanged,
    required this.onScrubEnd,
    required this.onFormatChanged,
    required this.onBitrateChanged,
    required this.onBitrateEnd,
    required this.onClear,
    required this.onSave,
    required this.formatItems,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.black.withValues(alpha: 0.9),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 350,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // File Size Info
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Original', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text(originalSize ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Est. Compressed', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    Text(estimatedSize, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),

            // Scrubbing Slider
            Row(
              children: [
                const Text('Scrub: '),
                Expanded(
                  child: Slider(
                    value: scrubPosition,
                    onChanged: onScrubChanged,
                    onChangeEnd: onScrubEnd,
                  ),
                ),
                Text(_formatDuration(duration * scrubPosition)),
              ],
            ),
            const SizedBox(height: 16),

            // Format Selection
            Row(
              children: [
                const Text('Format: '),
                const Spacer(),
                DropdownButton<String>(
                  value: outputFormat,
                  isDense: true,
                  underline: Container(),
                  items: formatItems,
                  onChanged: onFormatChanged,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Bitrate Slider
            Row(
              children: [
                const Text('Bitrate: '),
                Expanded(
                  child: Slider(
                    value: bitrate,
                    min: 10,
                    max: maxBitrate,
                    divisions: 100,
                    label: '${bitrate.round()} kbps',
                    onChanged: onBitrateChanged,
                    onChangeEnd: onBitrateEnd,
                  ),
                ),
                Text('${bitrate.round()} k'),
              ],
            ),
            const SizedBox(height: 16),

            // Actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onClear,
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !isCompressing ? onSave : null,
                    icon: isCompressing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.save),
                    label: Text(isCompressing ? 'Saving...' : 'Save'),
                  ),
                ),
              ],
            ),
            if (isPreviewing)
              const Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: LinearProgressIndicator(),
              ),
            if (isCompressing)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 4),
                    Text('${(progress * 100).round()}%'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds';
  }
}