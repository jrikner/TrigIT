// SPDX-License-Identifier: GPL-3.0-or-later

/// Undo and redo for a value edited as a whole, such as a Set.
///
/// Every edit records the value as it was before. Edits that follow each
/// other within `coalescing` seconds count as one step, so typing a name is
/// undone in one go rather than a letter at a time. Pure: callers pass the time.
public struct EditHistory<Value: Equatable & Sendable>: Sendable {
    public let limit: Int
    public let coalescing: Double

    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private var lastEdit: Double?

    public init(limit: Int = 200, coalescing: Double = 1.0) {
        self.limit = limit
        self.coalescing = coalescing
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records an edit made at `time`; `before` is the value before it.
    public mutating func record(before: Value, at time: Double) {
        defer { lastEdit = time }
        redoStack.removeAll()
        if let lastEdit, time - lastEdit < coalescing, !undoStack.isEmpty { return }
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst() }
    }

    /// The value to go back to, given the value now; nil if there is nothing to undo.
    public mutating func undo(from current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastEdit = nil
        return previous
    }

    /// The value to go forward to, given the value now; nil if there is nothing to redo.
    public mutating func redo(from current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastEdit = nil
        return next
    }

    /// Forgets everything, as when another Set is opened.
    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastEdit = nil
    }
}
