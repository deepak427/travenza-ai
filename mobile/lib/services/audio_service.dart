import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:record/record.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class AudioService {
  final _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordSub;
  
  final _volController = StreamController<double>.broadcast();
  Stream<double> get volumeStream => _volController.stream;

  Future<void> init() async {
    print("Initializing FlutterPcmSound...");
    await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(4800); // 100ms
    await FlutterPcmSound.play();
    print("FlutterPcmSound active.");
  }

  Future<Stream<Uint8List>> startRecording() async {
    final stream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000, // 16000 * 16 * 1
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );

    _recordSub = stream.listen((data) {
       _volController.add(_calculateRMS(data));
    });

    return stream;
  }

  void playChunk(Uint8List pcm16) {
    final int16List = Int16List.view(pcm16.buffer);
    FlutterPcmSound.feed(PcmArrayInt16(bytes: int16List.buffer.asByteData()));
    // Also feed player volume to visualizer
    _volController.add(_calculateRMS(pcm16));
  }

  Future<void> clearPlayback() async {
    print("Interrupting: Clearing audio buffer");
    await FlutterPcmSound.stop();
    await FlutterPcmSound.play();
  }

  Future<void> stop() async {
    await _audioRecorder.stop();
    await _recordSub?.cancel();
    _recordSub = null;
    await FlutterPcmSound.stop();
  }

  double _calculateRMS(Uint8List samples) {
    if (samples.isEmpty) return 0.0;
    final data = Int16List.view(samples.buffer);
    double sum = 0;
    for (var sample in data) {
      sum += (sample * sample).toDouble();
    }
    double rms = math.sqrt(sum / data.length);
    
    // Normalize 0.0 to 1.0
    double normalized = rms / 32768.0;
    
    // Noise floor: ignore anything below 0.01 (modest background noise)
    const threshold = 0.01;
    if (normalized < threshold) return 0.0;
    
    // Scale up the remaining signal for better visualization
    return (normalized - threshold) / (1.0 - threshold);
  }
}
