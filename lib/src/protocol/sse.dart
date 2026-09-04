/// Subset parser for Server-Sent Events on the live sync feed.
///
/// Incremental over lines — no socket, no JSON parsing of envelope data.
/// Heartbeats (`:` comments) are first-class items so the transport can tell
/// live silence from a dead connection. `id` and `retry` fields are skipped:
/// resume uses the pull cursor (`since` / `next_cursor`), not Last-Event-ID.
library;

/// One item from a parsed live feed: either an event or a heartbeat.
sealed class LiveFeedItem {
  /// Creates a feed item.
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

/// Incremental parser for the ulsync live SSE subset.
///
/// Call [addLine] with each line (no trailing newline). A completed event or
/// heartbeat is returned when it is ready. An incomplete event at end of
/// stream is never flushed: without a terminating blank line, [addLine]
/// yields nothing for that event.
final class LiveFeedParser {
  /// Event name accumulated since the last blank line.
  String _eventName = '';

  /// `data:` lines accumulated since the last blank line.
  final List<String> _dataLines = [];

  /// Consumes one SSE line and returns items that became complete.
  ///
  /// [rawLine] must not include the line terminator. A comment line emits a
  /// heartbeat immediately and does not close a pending event. A blank line
  /// closes a pending event. Unknown field names and `id` / `retry` are
  /// ignored: resume is cursor-based, not Last-Event-ID.
  List<LiveFeedItem> addLine(String rawLine) {
    final items = <LiveFeedItem>[];
    final line = rawLine.trimRight();

    // Comment / heartbeat — not part of the current event.
    if (line.isNotEmpty && line.startsWith(':')) {
      items.add(const LiveFeedHeartbeat());
      return items;
    }

    // Blank line terminates the current event.
    if (line.trim().isEmpty) {
      final event = _takeEventIfAny();
      if (event != null) {
        items.add(event);
      }
      return items;
    }

    final colon = line.indexOf(':');
    if (colon == -1) {
      // Unknown line shape — skip per subset rules.
      return items;
    }

    final field = line.substring(0, colon);
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) {
      value = value.substring(1);
    }

    switch (field) {
      case 'event':
        _eventName = value;
      case 'data':
        _dataLines.add(value);
      case 'id':
      case 'retry':
      // Resume is cursor-based, not Last-Event-ID — fields intentionally
      // ignored.
      default:
        break;
    }
    return items;
  }

  /// Builds a completed event from the current buffer, or `null` if empty.
  LiveFeedEvent? _takeEventIfAny() {
    if (_eventName.isEmpty && _dataLines.isEmpty) {
      return null;
    }
    final event = LiveFeedEvent(name: _eventName, data: _dataLines.join('\n'));
    _eventName = '';
    _dataLines.clear();
    return event;
  }
}

/// Parses [lines] into [LiveFeedItem]s for the ulsync live subset.
///
/// Implements only `event:`, `data:`, comment lines, and blank-line event
/// boundaries. Incomplete events at end-of-stream are dropped (buffer is not
/// flushed after the last line).
List<LiveFeedItem> parseLiveFeedLines(Iterable<String> lines) {
  final parser = LiveFeedParser();
  final items = <LiveFeedItem>[];
  for (final line in lines) {
    items.addAll(parser.addLine(line));
  }
  return items;
}
