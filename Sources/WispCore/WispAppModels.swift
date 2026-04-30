import Foundation

public enum WispScratchpadStatus: String, Codable, Sendable, Equatable {
    case active
    case linked
    case archived
}

public enum WispSourceType: String, Codable, Sendable, Equatable {
    case manual
    case paste
    case imported
}

public enum WispTaskStatus: String, Codable, Sendable, Equatable {
    case open
    case inProgress = "in_progress"
    case blocked
    case done
}

public struct WispScratchpadItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var status: WispScratchpadStatus
    public var sourceType: WispSourceType
    public var linkedNoteIDs: [String]
    public var linkedTaskIDs: [String]

    public init(
        id: String,
        text: String,
        createdAt: Date,
        status: WispScratchpadStatus = .active,
        sourceType: WispSourceType = .manual,
        linkedNoteIDs: [String] = [],
        linkedTaskIDs: [String] = []
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.status = status
        self.sourceType = sourceType
        self.linkedNoteIDs = linkedNoteIDs
        self.linkedTaskIDs = linkedTaskIDs
    }
}

public struct WispWikiNote: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var path: String
    public var tags: [String]
    public var summary: String
    public var body: String
    public var sourceIDs: [String]

    public init(id: String, title: String, path: String, tags: [String] = [], summary: String, body: String, sourceIDs: [String] = []) {
        self.id = id
        self.title = title
        self.path = path
        self.tags = tags
        self.summary = summary
        self.body = body
        self.sourceIDs = sourceIDs
    }
}

public struct WispTask: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: WispTaskStatus
    public var dueDate: String?
    public var dueTime: String?
    public var place: String?
    public var sourceIDs: [String]
    public var relatedNoteIDs: [String]
    public var threadID: String?
    public var lastActivityAt: Date?

    public init(
        id: String,
        title: String,
        status: WispTaskStatus = .open,
        dueDate: String? = nil,
        dueTime: String? = nil,
        place: String? = nil,
        sourceIDs: [String] = [],
        relatedNoteIDs: [String] = [],
        threadID: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.place = place
        self.sourceIDs = sourceIDs
        self.relatedNoteIDs = relatedNoteIDs
        self.threadID = threadID
        self.lastActivityAt = lastActivityAt
    }
}

public enum WispThreadRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
}

public struct WispTaskThreadMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var role: WispThreadRole
    public var text: String
    public var citationsNoteIDs: [String]
    public var createdAt: Date

    public init(id: String = UUID().uuidString, role: WispThreadRole, text: String, citationsNoteIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.citationsNoteIDs = citationsNoteIDs
        self.createdAt = createdAt
    }
}

public struct WispTaskThread: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var taskID: String
    public var messages: [WispTaskThreadMessage]

    public init(id: String, taskID: String, messages: [WispTaskThreadMessage] = []) {
        self.id = id
        self.taskID = taskID
        self.messages = messages
    }
}

public struct WispAppSnapshot: Sendable, Equatable {
    public var scratchpadItems: [WispScratchpadItem]
    public var notes: [WispWikiNote]
    public var tasks: [WispTask]
    public var taskThreads: [WispTaskThread]

    public init(
        scratchpadItems: [WispScratchpadItem] = [],
        notes: [WispWikiNote] = [],
        tasks: [WispTask] = [],
        taskThreads: [WispTaskThread] = []
    ) {
        self.scratchpadItems = scratchpadItems
        self.notes = notes
        self.tasks = tasks
        self.taskThreads = taskThreads
    }
}

public actor WispAppFacade {
    private var snapshot: WispAppSnapshot

    public init(snapshot: WispAppSnapshot = WispAppSnapshot()) {
        self.snapshot = snapshot
    }

    @discardableResult
    public func captureScratchpadText(_ text: String, sourceType: WispSourceType = .manual, now: Date = Date()) throws -> WispScratchpadItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WispCoreError.emptyText("scratchpad text")
        }
        let item = WispScratchpadItem(
            id: "sp_" + UUID().uuidString.lowercased(),
            text: trimmed,
            createdAt: now,
            sourceType: sourceType
        )
        snapshot.scratchpadItems.append(item)
        return item
    }

    public func appendTask(_ task: WispTask) {
        snapshot.tasks.append(task)
        if let threadID = task.threadID, !snapshot.taskThreads.contains(where: { $0.id == threadID }) {
            snapshot.taskThreads.append(WispTaskThread(id: threadID, taskID: task.id))
        }
    }

    public func appendThreadMessage(taskID: String, message: WispTaskThreadMessage) throws {
        guard let index = snapshot.taskThreads.firstIndex(where: { $0.taskID == taskID }) else {
            throw WispCoreError.invalidPath("missing task thread for task \(taskID)")
        }
        snapshot.taskThreads[index].messages.append(message)
    }

    public func currentSnapshot() -> WispAppSnapshot {
        snapshot
    }
}
