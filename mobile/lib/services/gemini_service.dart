import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/guide.dart';

class GeminiService {
  String baseUrl = "10.0.2.2:8080"; // Default for emulator
  WebSocketChannel? _channel;
  
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  Future<List<Guide>> fetchGuides() async {
    final response = await http.get(Uri.parse("http://$baseUrl/api/guides"));
    if (response.statusCode == 200) {
      final Map<String, dynamic> data = json.decode(response.body);
      return data.entries.map((e) => Guide.fromJson(e.key, e.value)).toList();
    }
    throw Exception("Failed to load guides");
  }

  Future<void> connect(String guideId, String guideName, String voiceName, String guideDesc) async {
    // 1. Auth
    final authRes = await http.post(
      Uri.parse("http://$baseUrl/api/auth"),
      headers: {"Content-Type": "application/json"},
      body: json.encode({"guide_id": guideId}),
    );
    
    if (authRes.statusCode != 200) throw Exception("Auth failed");
    final authData = json.decode(authRes.body);
    final token = authData['session_token'];

    // 2. WebSocket
    final wsUri = Uri.parse("ws://$baseUrl/ws?token=$token");
    _channel = WebSocketChannel.connect(wsUri);

    // 3. Handshake (Optimized for high-fidelity voice)
    final setup = {
      "setup": {
        "generation_config": {
          "speech_config": {
            "voice_config": {
              "prebuilt_voice_config": {"voice_name": voiceName}
            }
          },
          "temperature": 0.7,
        },
        "system_instruction": {
          "parts": [{
            "text": "You are $guideName, a traveler's best friend. Be helpful, concise, and extremely proactive. "
                    "You are using a high-fidelity voice interface on a mobile device. "
                    "Your background is: $guideDesc. "
                    "Keep your responses short (1-2 sentences) to maintain a natural conversation flow."
          }]
        },
        "proactivity": {"proactiveAudio": true},
        "input_audio_transcription": true,
        "output_audio_transcription": true
      }
    };
    _channel!.sink.add(json.encode(setup));

    // Listen for events
    _channel!.stream.listen((message) {
      if (message is String) {
        _eventController.add(json.decode(message));
      } else if (message is List<int>) {
         // Binary audio handled by view/audio_service
         _eventController.add({"type": "audio", "data": message});
      }
    }, onDone: () => disconnect());
  }

  void sendAudio(List<int> pcm16) {
    _channel?.sink.add(pcm16);
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }
}
