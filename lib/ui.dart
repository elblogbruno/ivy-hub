import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Kotlin side: MainActivity.kt (speak, quiet, wake, brightness, ringStart/ringStop, filesDir).
const native = MethodChannel('ivy/native');

// Google Smart Display dark palette.
const bg = Color(0xFF121316);
const surface = Color(0xFF202124);
const surfaceHigh = Color(0xFF303134);
const onSurface = Color(0xFFE8EAED);
const muted = Color(0xFF9AA0A6);
const accent = Color(0xFF8AB4F8);
const lightOn = Color(0xFFFDD663);
const heatColor = Color(0xFFF29900);
const coolColor = Color(0xFF8AB4F8);
const danger = Color(0xFFEA4335);
const good = Color(0xFF81C995);

TextStyle gs(
  double size, {
  Color color = onSurface,
  FontWeight weight = FontWeight.w400,
  double? height,
}) => TextStyle(
  fontFamily: 'GoogleSans',
  fontSize: size,
  color: color,
  fontWeight: weight,
  height: height,
);

TextStyle gsd(double size, {Color color = onSurface, double? height}) =>
    TextStyle(
      fontFamily: 'GoogleSansDisplay',
      fontSize: size,
      color: color,
      height: height,
    );

String unavailableLabel(String? s) =>
    s == null || s == 'unavailable' ? 'Sin conexión' : 'Desconocido';

bool isOffline(String? s) => s == null || s == 'unavailable' || s == 'unknown';

/// Google-Home-style tile: icon bubble, name, state; animates colour on state change.
class Tile extends StatelessWidget {
  final IconData icon;
  final String name;
  final String state;
  final bool on;
  final bool offline;
  final Color onColor;
  final Widget? leading;
  final VoidCallback? onTap;
  final VoidCallback? onMore;
  const Tile({
    super.key,
    required this.icon,
    required this.name,
    required this.state,
    this.on = false,
    this.offline = false,
    this.onColor = lightOn,
    this.leading,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final fg = on ? const Color(0xFF202124) : onSurface;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: offline ? 0.45 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: on ? onColor : surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: offline ? null : onTap,
            onLongPress: offline ? null : onMore,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  leading ??
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on ? const Color(0x33FFFFFF) : surfaceHigh,
                        ),
                        child: Icon(icon, color: on ? fg : accent, size: 24),
                      ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: gs(18, color: fg, weight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          state,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: gs(15, color: on ? fg : muted),
                        ),
                      ],
                    ),
                  ),
                  if (onMore != null && !offline)
                    IconButton(
                      onPressed: onMore,
                      icon: Icon(Icons.chevron_right, color: on ? fg : muted),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dark rounded card used across pages.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(22),
    ),
    padding: padding,
    child: child,
  );
}

/// Google-style bottom sheet: dark, rounded top, drag handle.
Future<T?> showIvySheet<T>(BuildContext context, Widget child) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: surface,
      barrierColor: const Color(0x99000000),
      constraints: const BoxConstraints(maxWidth: 760),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 10, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: muted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );

/// Big rounded "fill" slider like Google Home's light control.
class FillSlider extends StatefulWidget {
  final double value; // 0..1
  final Color color;
  final String Function(double) label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final Gradient? track;
  const FillSlider({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    required this.onChangeEnd,
    this.color = lightOn,
    this.track,
  });
  @override
  State<FillSlider> createState() => _FillSliderState();
}

class _FillSliderState extends State<FillSlider> {
  double? _drag;

  double _at(BuildContext context, Offset local) {
    final w = (context.findRenderObject() as RenderBox).size.width;
    return (local.dx / w).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final v = _drag ?? widget.value;
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() => _drag = _at(context, d.localPosition));
        widget.onChanged(_drag!);
      },
      onHorizontalDragEnd: (_) {
        widget.onChangeEnd(_drag ?? v);
        setState(() => _drag = null);
      },
      onTapUp: (d) => widget.onChangeEnd(_at(context, d.localPosition)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: 64,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: surfaceHigh,
                  gradient: widget.track,
                ),
              ),
              if (widget.track == null)
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  child: ColoredBox(color: widget.color),
                )
              else
                Align(
                  alignment: Alignment(v * 2 - 1, 0),
                  child: Container(
                    width: 8,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.label(v),
                    style: gs(
                      20,
                      weight: FontWeight.w500,
                      color: widget.track == null && v > 0.15 ? bg : onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single-choice chips (select options, vacuum fan speeds…).
class OptionChips extends StatelessWidget {
  final List<String> options;
  final String? selected;
  final ValueChanged<String> onSelected;
  final String Function(String)? label;
  const OptionChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.label,
  });
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final o in options)
        ChoiceChip(
          label: Text(label?.call(o) ?? o, style: gs(15, color: o == selected ? bg : onSurface)),
          selected: o == selected,
          selectedColor: accent,
          backgroundColor: surfaceHigh,
          showCheckmark: false,
          side: BorderSide.none,
          shape: const StadiumBorder(),
          onSelected: (_) => onSelected(o),
        ),
    ],
  );
}
