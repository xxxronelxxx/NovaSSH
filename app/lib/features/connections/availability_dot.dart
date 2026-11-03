import 'package:flutter/material.dart';

import '../../design/tokens.dart';

class AvailabilityDot extends StatefulWidget {
  const AvailabilityDot({super.key, required this.available, this.size = 13});

  /// null = still checking.
  final bool? available;
  final double size;

  @override
  State<AvailabilityDot> createState() => _AvailabilityDotState();
}

class _AvailabilityDotState extends State<AvailabilityDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.available;
    final color = state == null
        ? T.faint
        : state
            ? const Color(0xFF2FD37A)
            : const Color(0xFFFF4D4F);

    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: state == null
            ? null
            : [
                BoxShadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: 6,
                  spreadRadius: 1.5,
                ),
              ],
      ),
    );

    if (state == null) return dot;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Stack(
          alignment: Alignment.center,
          children: [
            // Halo pulse.
            Container(
              width: widget.size + 10 * t,
              height: widget.size + 10 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.28 * (1 - t)),
              ),
            ),
            Transform.scale(scale: 0.94 + 0.06 * t, child: child),
          ],
        );
      },
      child: dot,
    );
  }
}
