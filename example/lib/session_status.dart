/// Session strip model for the self-hosted to-do example.
library;

import 'package:flutter/material.dart';

/// What this installation shows about its store after pairing.
///
/// Self-hosted clients show the **host** this device is bound to and whether
/// the live feed is up. The bearer stays in memory for the sync client;
/// putting it in the chrome would teach operators to screenshot secrets.
///
/// [SessionStatus.offline] is only the Work-offline control: the user asked
/// this window not to talk. [SessionStatus.reconnecting] is a connection loss
/// while that control is off: the library reopens the feed. Collapsing them
/// would make a killed server look like an intentional pause.
enum SessionStatus {
  /// After Sign in until the first connection-restored event on the live feed.
  connecting,

  /// Live feed subscribed and the server answered recently.
  live,

  /// Work offline is on for this window only.
  offline,

  /// Live feed lost while Work offline is off; the library is retrying.
  reconnecting,

  /// [UlsyncClient.syncOnce] or the live stream failed while not offline.
  unreachable,
}

/// Banner text and indicator color for [SessionStatus].
extension SessionStatusPresentation on SessionStatus {
  /// One-line status under the app bar. [host] is [displayHost], never a token.
  String bannerLine({required String host}) {
    return switch (this) {
      SessionStatus.connecting => 'Connecting · $host',
      SessionStatus.live => 'Live · $host',
      SessionStatus.offline => 'Offline · saved on this device',
      SessionStatus.reconnecting => 'Reconnecting · $host',
      SessionStatus.unreachable => "Can't reach server · $host",
    };
  }

  /// Semantic dot color for the strip, taken from the active [ColorScheme].
  Color indicatorColor(ColorScheme scheme) {
    return switch (this) {
      SessionStatus.connecting => scheme.tertiary,
      SessionStatus.live => scheme.primary,
      SessionStatus.offline => scheme.outline,
      SessionStatus.reconnecting => scheme.tertiary,
      SessionStatus.unreachable => scheme.error,
    };
  }
}
