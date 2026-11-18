/// An opaque colour, 0xFFrrggbb, from "#rrggbb" (either case), as the project's files and a
/// DAW write one; null for anything else.
int? argbOfHex(Object? value) => switch (value) {
      final String s when RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(s) => 0xFF000000 | int.parse(s.substring(1), radix: 16),
      _ => null,
    };
