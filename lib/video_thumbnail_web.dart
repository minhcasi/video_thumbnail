import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:get_thumbnail_video/src/image_format.dart';
import 'package:get_thumbnail_video/src/video_thumbnail_platform.dart';
import 'package:web/web.dart';

// An error code value to error name Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorName = <int, String>{
  1: 'MEDIA_ERR_ABORTED',
  2: 'MEDIA_ERR_NETWORK',
  3: 'MEDIA_ERR_DECODE',
  4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

// An error code value to description Map.
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/code
const Map<int, String> _kErrorValueToErrorDescription = <int, String>{
  1: 'The user canceled the fetching of the video.',
  2: 'A network error occurred while fetching the video, despite having previously been available.',
  3: 'An error occurred while trying to decode the video, despite having previously been determined to be usable.',
  4: 'The video has been found to be unsuitable (missing or in a format not supported by your browser).',
};

// The default error message, when the error is an empty string
// See: https://developer.mozilla.org/en-US/docs/Web/API/MediaError/message
const String _kDefaultErrorMessage =
    'No further diagnostic information can be determined or provided.';

/// A web implementation of the VideoThumbnailPlatform of the VideoThumbnail plugin.
///
/// Migrated from `dart:html` → `package:web` + `dart:js_interop` for
/// WebAssembly (`dart2wasm`) compatibility. The behavior is unchanged — all
/// thumbnail generation happens via a hidden `<video>` + `<canvas>` as before.
class VideoThumbnailWeb extends VideoThumbnailPlatform {
  VideoThumbnailWeb();

  static void registerWith(Registrar registrar) {
    VideoThumbnailPlatform.instance = VideoThumbnailWeb();
  }

  @override
  Future<XFile> thumbnailFile({
    required String video,
    required Map<String, String>? headers,
    required String? thumbnailPath,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    required int timeMs,
    required int quality,
  }) async {
    final blob = await _createThumbnail(
      videoSrc: video,
      headers: headers,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );

    return XFile(URL.createObjectURL(blob), mimeType: blob.type);
  }

  @override
  Future<Uint8List> thumbnailData({
    required String video,
    required Map<String, String>? headers,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    required int timeMs,
    required int quality,
  }) async {
    final blob = await _createThumbnail(
      videoSrc: video,
      headers: headers,
      imageFormat: imageFormat,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      timeMs: timeMs,
      quality: quality,
    );
    final path = URL.createObjectURL(blob);
    final file = XFile(path, mimeType: blob.type);
    final bytes = await file.readAsBytes();
    URL.revokeObjectURL(path);

    return bytes;
  }

  Future<Blob> _createThumbnail({
    required String videoSrc,
    required Map<String, String>? headers,
    required ImageFormat imageFormat,
    required int maxHeight,
    required int maxWidth,
    required int timeMs,
    required int quality,
  }) async {
    final completer = Completer<Blob>();

    final video = document.createElement('video') as HTMLVideoElement;
    final timeSec = math.max(timeMs / 1000, 0).toDouble();
    final fetchVideo = headers != null && headers.isNotEmpty;

    video.addEventListener(
        'loadedmetadata',
        ((Event _) {
          video.currentTime = timeSec;
          if (fetchVideo) {
            URL.revokeObjectURL(video.src);
          }
        }).toJS);

    video.addEventListener(
        'seeked',
        ((Event _) {
          if (completer.isCompleted) return;
          final canvas = document.createElement('canvas') as HTMLCanvasElement;
          final ctx =
              canvas.getContext('2d') as CanvasRenderingContext2D;

          int effWidth = maxWidth;
          int effHeight = maxHeight;
          if (effWidth == 0 && effHeight == 0) {
            canvas.width = video.videoWidth;
            canvas.height = video.videoHeight;
            ctx.drawImage(video, 0, 0);
          } else {
            final aspectRatio = video.videoWidth / video.videoHeight;
            if (effWidth == 0) {
              effWidth = (effHeight * aspectRatio).round();
            } else if (effHeight == 0) {
              effHeight = (effWidth / aspectRatio).round();
            }

            final inputAspectRatio = effWidth / effHeight;
            if (aspectRatio > inputAspectRatio) {
              effHeight = (effWidth / aspectRatio).round();
            } else {
              effWidth = (effHeight * aspectRatio).round();
            }

            canvas.width = effWidth;
            canvas.height = effHeight;
            // drawImage with 5 args: image, dx, dy, dw, dh → scales.
            ctx.drawImage(video, 0, 0, effWidth, effHeight);
          }

          try {
            // HTMLCanvasElement.toBlob(callback, type, quality) — async via
            // callback. We wrap it in a Completer for the outer promise.
            canvas.toBlob(
                ((Blob? b) {
                  if (b != null) {
                    completer.complete(b);
                  } else {
                    completer.completeError(PlatformException(
                      code: 'CANVAS_EXPORT_ERROR',
                      message: 'canvas.toBlob returned null',
                    ));
                  }
                }).toJS,
                _imageFormatToCanvasFormat(imageFormat),
                (quality / 100).toJS);
          } catch (e, s) {
            completer.completeError(
              PlatformException(
                code: 'CANVAS_EXPORT_ERROR',
                details: e,
                stacktrace: s.toString(),
              ),
              s,
            );
          }
        }).toJS);

    video.addEventListener(
        'error',
        ((Event _) {
          if (completer.isCompleted) return;
          final error = video.error;
          if (error == null) {
            completer.completeError(const PlatformException(
              code: 'MEDIA_ERR_UNKNOWN',
              message: _kDefaultErrorMessage,
            ));
            return;
          }
          completer.completeError(
            PlatformException(
              code: _kErrorValueToErrorName[error.code] ?? 'MEDIA_ERR_UNKNOWN',
              message: error.message.isNotEmpty
                  ? error.message
                  : _kDefaultErrorMessage,
              details: _kErrorValueToErrorDescription[error.code],
            ),
          );
        }).toJS);

    if (fetchVideo) {
      try {
        final blob = await _fetchVideoByHeaders(
          videoSrc: videoSrc,
          headers: headers,
        );

        video.src = URL.createObjectURL(blob);
      } catch (e, s) {
        completer.completeError(e, s);
      }
    } else {
      video.crossOrigin = 'Anonymous';
      video.src = videoSrc;
    }

    return completer.future;
  }

  /// Fetches the video bytes with custom headers. Sets responseType to 'blob'
  /// so the browser keeps bytes in cache / off the main heap.
  Future<Blob> _fetchVideoByHeaders({
    required String videoSrc,
    required Map<String, String> headers,
  }) async {
    final completer = Completer<Blob>();

    final xhr = XMLHttpRequest()..open('GET', videoSrc, true);
    xhr.responseType = 'blob';
    headers.forEach((k, v) => xhr.setRequestHeader(k, v));

    xhr.addEventListener(
        'load',
        ((Event _) {
          completer.complete(xhr.response as Blob);
        }).toJS);

    xhr.addEventListener(
        'error',
        ((Event _) {
          completer.completeError(
            PlatformException(
              code: 'VIDEO_FETCH_ERROR',
              message: 'Status: ${xhr.statusText}',
            ),
          );
        }).toJS);

    xhr.send();
    return completer.future;
  }

  String _imageFormatToCanvasFormat(ImageFormat imageFormat) {
    switch (imageFormat) {
      case ImageFormat.JPEG:
        return 'image/jpeg';
      case ImageFormat.PNG:
        return 'image/png';
      case ImageFormat.WEBP:
        return 'image/webp';
    }
  }
}
