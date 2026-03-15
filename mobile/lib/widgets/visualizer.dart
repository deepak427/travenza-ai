import 'dart:math' as math;
import 'package:flutter/material.dart';

class GuitarStringVisualizer extends StatefulWidget {
  final Stream<double> volumeStream;
  const GuitarStringVisualizer({super.key, required this.volumeStream});

  @override
  State<GuitarStringVisualizer> createState() => _GuitarStringVisualizerState();
}

class _GuitarStringVisualizerState extends State<GuitarStringVisualizer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _currentVol = 0.0;
  final List<double> _points = List.generate(30, (_) => 0.0);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 100))..repeat();
    widget.volumeStream.listen((vol) {
      if (mounted) {
        setState(() {
          _currentVol = vol; // Now 0.0 to 1.0
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: const Size(double.infinity, 100),
          painter: CurvePainter(_currentVol, _points),
        );
      },
    );
  }
}

class CurvePainter extends CustomPainter {
  final double volume;
  final List<double> points;
  CurvePainter(this.volume, this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF66FCF1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2); // Subtle glow

    final shadowPaint = Paint()
      ..color = const Color(0xFF66FCF1).withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    final path = Path();
    final step = size.width / (points.length - 1);
    
    for (int i = 0; i < points.length; i++) {
       final window = math.sin((i / (points.length - 1)) * math.pi);
       final jitter = (math.Random().nextDouble() - 0.5) * volume * size.height * 2.5;
       points[i] = points[i] + (jitter * window - points[i]) * 0.2; // Smoother LERP

       final x = i * step;
       final y = (size.height / 2) + points[i];
       
       if (i == 0) {
         path.moveTo(x, y);
       } else {
         final prevX = (i - 1) * step;
         final prevY = (size.height / 2) + points[i-1];
         final cx = (prevX + x) / 2;
         final cy = (prevY + y) / 2;
         path.quadraticBezierTo(prevX, prevY, cx, cy);
       }
    }
    
    path.lineTo(size.width, size.height / 2);
    canvas.drawPath(path, shadowPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
