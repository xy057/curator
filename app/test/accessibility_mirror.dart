// A stand-in for the desktop engine's accessibility tree, so tests can catch the updates it
// rejects. On macOS (and Windows) the engine copies the framework's semantics into a
// Chromium ui::AXTree (engine/src/flutter/shell/platform/common/accessibility_bridge.cc),
// which refuses a node that no parent lists ("… will not be in the tree and is not the new
// root") and a listed child that wasn't sent ("Nodes left pending by the update"). It can't
// move a node either: the bridge takes it out of its old parent, which deletes its subtree,
// then adds it to the new one, which then needs every descendant again. After a refusal the
// engine's tree is out of step with the app's for good: `make run` logs "Failed to update
// ui::AXTree" on every later change, and VoiceOver sees a broken window.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Records every semantics update and replays it through [AccessibilityMirror].
/// Create it before the first `testWidgets`, then call `tester.ensureSemantics()`.
class AccessibilityMirrorBinding extends AutomatedTestWidgetsFlutterBinding {
  final mirror = AccessibilityMirror();

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(super.createSemanticsUpdateBuilder(), mirror);
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this._inner, this._mirror);
  final ui.SemanticsUpdateBuilder _inner;
  final AccessibilityMirror _mirror;
  final _nodes = <int, List<int>>{};

  @override
  ui.SemanticsUpdate build() {
    _mirror.commit(_nodes);
    return _inner.build();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      _nodes[args[#id] as int] = List.of(args[#childrenInTraversalOrder] as Int32List);
      return Function.apply(_inner.updateNode, const [], args);
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(_inner.updateCustomAction, const [], invocation.namedArguments);
    }
    return super.noSuchMethod(invocation);
  }
}

/// The engine's tree (node id → children, in traversal order), updated the way the
/// bridge updates it, with the errors ui::AXTree would log.
class AccessibilityMirror {
  final _children = <int, List<int>>{};
  final _parent = <int, int>{};

  /// Every node as last sent: what the tree would be if nothing had been rejected.
  final _sent = <int, List<int>>{};

  /// What the engine would have logged since the last [takeErrors].
  final errors = <String>[];

  List<String> takeErrors() {
    final taken = List.of(errors);
    errors.clear();
    return taken;
  }

  /// AccessibilityBridge::CommitUpdates.
  void commit(Map<int, List<int>> pending) {
    _sent.addAll(pending);
    // Update 1: take every moved node out of its old parent.
    final removals = <int, List<int>>{};
    pending.forEach((id, children) {
      for (final child in children) {
        final parent = _parent[child];
        if (!_children.containsKey(child) || parent == null || parent == id) continue;
        (removals[parent] ??= List.of(_children[parent]!)).remove(child);
      }
    });
    if (removals.isNotEmpty && !_unserialize(removals.entries.toList(), root: null)) return;
    // Update 2: everything sent, parents before children.
    final order = <MapEntry<int, List<int>>>[];
    final left = Map.of(pending);
    void subtree(int id) {
      final children = left.remove(id)!;
      order.add(MapEntry(id, children));
      for (final child in children) {
        if (left.containsKey(child)) subtree(child);
      }
    }

    final lists = <List<MapEntry<int, List<int>>>>[];
    while (left.isNotEmpty) {
      order.clear();
      subtree(left.keys.first);
      lists.add(List.of(order));
    }
    final nodes = [for (final list in lists.reversed) ...list];
    _unserialize(nodes, root: _children.isEmpty && nodes.isNotEmpty ? nodes.first.key : null);
  }

  /// ui::AXTree::Unserialize, reduced to the tree's shape.
  bool _unserialize(List<MapEntry<int, List<int>>> nodes, {required int? root}) {
    final destroyed = <int>{};
    final toCreate = <int>{};
    final created = <int>{};
    final known = <int, List<int>>{};

    void destroy(int id) {
      if (!destroyed.add(id)) return;
      for (final child in known[id] ?? _children[id] ?? const <int>[]) {
        destroy(child);
      }
    }

    bool exists(int id) => (_children.containsKey(id) && !destroyed.contains(id)) || toCreate.contains(id);

    String? error;
    for (final MapEntry(key: id, value: children) in nodes) {
      if (!exists(id)) {
        if (id != root) {
          error = '$id will not be in the tree and is not the new root';
          break;
        }
        toCreate.add(id);
      }
      final isNew = toCreate.contains(id) && !created.contains(id);
      final old = isNew ? const <int>[] : (known[id] ?? _children[id] ?? const <int>[]);
      for (final child in children) {
        if (old.contains(child)) continue;
        if (exists(child)) {
          error = 'Node $child is not marked for destruction, would be reparented to $id';
          break;
        }
        toCreate.add(child);
        destroyed.remove(child);
      }
      if (error != null) break;
      for (final child in old) {
        if (!children.contains(child)) destroy(child);
      }
      known[id] = children;
      created.add(id);
    }
    final pending = toCreate.difference(created);
    if (error == null && pending.isNotEmpty) {
      error = 'Nodes left pending by the update: ${(pending.toList()..sort()).join(' ')}';
    }
    if (error != null) {
      errors.add(error);
      _resync();
      return false;
    }
    known.forEach((id, children) => _children[id] = children);
    _rebuild(root ?? _rootId);
    return true;
  }

  int? get _rootId {
    for (final id in _children.keys) {
      if (!_parent.containsKey(id)) return id;
    }
    return null;
  }

  /// Keeps what hangs from [root] (what a successful update leaves) and records parents.
  void _rebuild(int? root) {
    final keep = <int, List<int>>{};
    _parent.clear();
    void visit(int id) {
      final children = _children[id] ?? const <int>[];
      keep[id] = children;
      for (final child in children) {
        _parent[child] = id;
        visit(child);
      }
    }

    if (root != null) visit(root);
    _children
      ..clear()
      ..addAll(keep);
  }

  /// After an error the engine's tree is damaged. Start again from what was sent, so each
  /// later error is one of its own rather than an echo of this one.
  void _resync() {
    final root = _rootId ?? 0;
    _children
      ..clear()
      ..addAll(_sent);
    _rebuild(root);
  }
}

/// Fails with the engine's errors, if the updates since the last check had any.
void expectAccessibilityTreeIntact(AccessibilityMirror mirror, String after) {
  expect(mirror.takeErrors(), isEmpty, reason: 'ui::AXTree errors after $after');
}

