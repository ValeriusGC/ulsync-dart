/// Subset parser for Server-Sent Events on the live sync feed.
///
/// Pure function over lines — no socket, no JSON parsing of envelope data.
/// Heartbeats (`:` comments) are first-class items so step 13 can tell live
/// silence from a dead connection. `id` and `retry` fields are skipped:
/// resume uses the pull cursor (`since` / `next_cursor`), not Last-Event-ID.
library;

/// One item from a parsed live feed: either an event or a heartbeat.
sealed class LiveFeedItem {
  const LiveFeedItem();
}

/// A completed SSE event with [name] and [data].
///
/// When the wire omits `event:`, [name] is the empty string (not `message`).
final class LiveFeedEvent extends LiveFeedItem {
  /// Creates an event with [name] and [data].
  const LiveFeedEvent({required this.name, required this.data});

  /// Event type from the `event:` field, or empty when omitted.
  final String name;

  /// Payload: one `data:` line, or several joined with `\n`.
  final String data;
}

/// A comment line (`:` prefix), including server heartbeats such as `: ping`.
final class LiveFeedHeartbeat extends LiveFeedItem {
  /// Creates a heartbeat marker with no stored comment text.
  const LiveFeedHeartbeat();
}

/// Parses [lines] into [LiveFeedItem]s for the ulsync live subset.
///
/// Implements only `event:`, `data:`, comment lines, and blank-line event
/// boundaries. Incomplete events at end-of-stream are dropped (buffer is not
/// flushed after the last line).
List<LiveFeedItem> parseLiveFeedLines(Iterable<String> lines) {
  final items = <LiveFeedItem>[];

  var eventName = '';
  final dataLines = <String>[];

  void emitEventIfAny() {
    if (eventName.isEmpty && dataLines.isEmpty) {
      return;
    }
    items.add(LiveFeedEvent(name: eventName, data: dataLines.join('\n')));
    eventName = '';
    dataLines.clear();
  }

  for (final rawLine in lines) {
    final line = rawLine.trimRight();

    // Comment / heartbeat — not part of the current event.
    if (line.isNotEmpty && line.startsWith(':')) {
      items.add(const LiveFeedHeartbeat());
      continue;
    }

    // Blank line terminates the current event.
    if (line.trim().isEmpty) {
      emitEventIfAny();
      continue;
    }

    final colon = line.indexOf(':');
    if (colon == -1) {
      // Unknown line shape — skip per subset rules.
      continue;
    }

    final field = line.substring(0, colon);
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) {
      value = value.substring(1);
    }

    switch (field) {
      case 'event':
        eventName = value;
      case 'data':
        dataLines.add(value);
      case 'id':
      case 'retry':
      // Resume is cursor-based, not Last-Event-ID — fields intentionally
      // ignored.
      default:
        break;
    }
  }

  // Do not flush a trailing partial event.
  return items;
}
