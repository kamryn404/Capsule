abstract class CompressionSettings {}

class VideoSettings extends CompressionSettings {
  final String outputFormat; // 'av1', 'vp9', 'h264', 'h265'
  final double bitrate;
  final double resolution; // 1.0, 0.5, 0.25

  VideoSettings({
    this.outputFormat = 'h265',
    this.bitrate = 5000,
    this.resolution = 1.0,
  });

  VideoSettings copyWith({
    String? outputFormat,
    double? bitrate,
    double? resolution,
  }) {
    return VideoSettings(
      outputFormat: outputFormat ?? this.outputFormat,
      bitrate: bitrate ?? this.bitrate,
      resolution: resolution ?? this.resolution,
    );
  }
}

class ImageSettings extends CompressionSettings {
  final String outputFormat; // 'jpg', 'png', 'webp', 'avif'
  final double quality;
  final double resolution;

  ImageSettings({
    this.outputFormat = 'jpg',
    this.quality = 80,
    this.resolution = 1.0,
  });

  ImageSettings copyWith({
    String? outputFormat,
    double? quality,
    double? resolution,
  }) {
    return ImageSettings(
      outputFormat: outputFormat ?? this.outputFormat,
      quality: quality ?? this.quality,
      resolution: resolution ?? this.resolution,
    );
  }
}

class AudioSettings extends CompressionSettings {
  final String outputFormat; // 'mp3', 'ogg', 'opus'
  final double bitrate;

  AudioSettings({
    this.outputFormat = 'mp3',
    this.bitrate = 128,
  });

  AudioSettings copyWith({
    String? outputFormat,
    double? bitrate,
  }) {
    return AudioSettings(
      outputFormat: outputFormat ?? this.outputFormat,
      bitrate: bitrate ?? this.bitrate,
    );
  }
}