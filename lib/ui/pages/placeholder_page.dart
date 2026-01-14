import 'package:shadcn_flutter/shadcn_flutter.dart';

class PlaceholderPage extends StatelessWidget {
  final String title;
  final String hint;

  const PlaceholderPage({super.key, required this.title, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title).h2(),
          const SizedBox(height: 12),
          Text(hint).muted(),
        ],
      ),
    );
  }
}
