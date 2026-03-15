import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';

import 'services/audio_service.dart';
import 'services/gemini_service.dart';
import 'models/guide.dart';
import 'widgets/visualizer.dart';

void main() {
  runApp(const TravenzaApp());
}

class TravenzaApp extends StatelessWidget {
  const TravenzaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Travenza AI',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _gemini = GeminiService();
  final _audio = AudioService();
  
  List<Guide> _guides = [];
  Guide? _selectedGuide;
  bool _isConnected = false;
  bool _isLoading = false;
  final List<Map<String, String>> _messages = [];
  final TextEditingController _ipController = TextEditingController(text: "10.198.207.7:8080");
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _initApp() async {
    await Permission.microphone.request();
    await _audio.init();
    _loadGuides();
  }

  @override
  void dispose() {
    _gemini.disconnect();
    _audio.stop();
    _ipController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadGuides() async {
    try {
      _gemini.baseUrl = _ipController.text;
      final list = await _gemini.fetchGuides();
      if (mounted) {
        setState(() {
          _guides = list;
          if (list.isNotEmpty) _selectedGuide = list.first;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error connecting: $e")));
      }
    }
  }

  Future<void> _startSession() async {
    if (_selectedGuide == null) return;
    setState(() => _isLoading = true);

    try {
      await _gemini.connect(_selectedGuide!.id, _selectedGuide!.name, _selectedGuide!.voice, _selectedGuide!.description);
      
      _gemini.events.listen((event) {
        if (!mounted) return;
        
        if (event['type'] == 'audio') {
          _audio.playChunk(Uint8List.fromList(event['data'].cast<int>()));
        } else {
          final sc = event['serverContent'];
          if (sc != null) {
            String? text;
            String? sender;
            
            if (sc['inputTranscription'] != null) {
              text = sc['inputTranscription']['text'];
              sender = "User";
            } else if (sc['outputTranscription'] != null) {
              text = sc['outputTranscription']['text'];
              sender = "AI";
            } else if (sc['modelTurn'] != null) {
              // Handle alternative text format from Gemini
              final parts = sc['modelTurn']['parts'] as List?;
              if (parts != null && parts.isNotEmpty) {
                text = parts.map((p) => p['text'] ?? "").join("");
                sender = "AI";
              }
            } else if (sc['interrupted'] == true) {
              _audio.clearPlayback();
              setState(() {
                _messages.add({"sender": "System", "text": "AI Interrupted"});
                _scrollToBottom();
              });
            }
            
            if (text != null && text.trim().isNotEmpty) {
              setState(() {
                _messages.add({"sender": sender!, "text": text!});
                _scrollToBottom();
              });
            }
          }
        }
      });

      final micStream = await _audio.startRecording();
      micStream.listen((Uint8List data) {
        if (_isConnected) _gemini.sendAudio(data);
      });

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isLoading = false;
          _messages.add({"sender": "System", "text": "Connected to ${_selectedGuide!.name}"});
          _scrollToBottom();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Session Error: $e")));
      }
    }
  }

  void _stopSession() {
    _gemini.disconnect();
    _audio.stop();
    if (mounted) {
      setState(() {
        _isConnected = false;
        _messages.add({"sender": "System", "text": "Session ended"});
        _scrollToBottom();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('TRAVENZA AI', style: GoogleFonts.outfit(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (!_isConnected) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipController,
                      decoration: const InputDecoration(
                        labelText: "Server IP (e.g. 10.198.207.7:8080)",
                        border: OutlineInputBorder(),
                        hintText: "10.198.207.7:8080",
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _loadGuides,
                    icon: const Icon(Icons.refresh),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF66FCF1),
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (_guides.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text(
                      "Enter your laptop's IP and click refresh to load guides",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                )
              else
                DropdownButtonFormField<Guide>(
                  value: _selectedGuide,
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: "Choose Your Guide"),
                  items: _guides.map((g) => DropdownMenuItem(value: g, child: Text(g.name))).toList(),
                  onChanged: (g) => setState(() => _selectedGuide = g),
                ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isLoading || _selectedGuide == null) ? null : _startSession,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF66FCF1),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.all(16),
                    disabledBackgroundColor: Colors.white10,
                  ),
                  child: _isLoading ? const CircularProgressIndicator() : const Text("START GUIDED SESSION"),
                ),
              ),
            ]
 else ...[
              const Text("AI is listening...", style: TextStyle(color: Color(0xFF66FCF1), fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              GuitarStringVisualizer(volumeStream: _audio.volumeStream),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final m = _messages[i];
                    final String sender = m['sender'] ?? "System";
                    final String text = m['text'] ?? "";
                    
                    final bool isUser = sender == "User";
                    final bool isAI = sender == "AI";
                    
                    Color bubbleColor = Colors.white12;
                    Color textColor = Colors.white;
                    if (isUser) {
                      bubbleColor = const Color(0xFF66FCF1);
                      textColor = Colors.black;
                    } else if (isAI) {
                      bubbleColor = const Color(0xFF1F2833);
                      textColor = Colors.white;
                    }

                    if (sender == "System") {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      );
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Text(sender, style: TextStyle(color: isUser ? const Color(0xFF45A29E) : Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Align(
                            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: bubbleColor,
                                borderRadius: BorderRadius.circular(16).copyWith(
                                  bottomRight: isUser ? Radius.zero : null,
                                  bottomLeft: !isUser ? Radius.zero : null,
                                ),
                              ),
                              child: Text(text, style: TextStyle(color: textColor, fontWeight: isUser ? FontWeight.w600 : FontWeight.normal)),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _stopSession,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                child: const Text("STOP SESSION"),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
