import Darwin
import Foundation

let showSettingsNotification = Notification.Name("io.github.mahad871.microphonechoice.showSettings")

final class SingleInstance {
    private var descriptors: [Int32] = []
    let acquired: Bool

    /// Releases before 2.0 were named Microphone Choice and lock that folder. Holding both
    /// locks keeps an old copy and a renamed copy from monitoring at the same time.
    static var defaultDirectories: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["Choice", "Microphone Choice"].map { support.appendingPathComponent($0, isDirectory: true) }
    }

    convenience init(directory: URL) { self.init(directories: [directory]) }

    init(directories: [URL] = SingleInstance.defaultDirectories) {
        var acquiredAll = true
        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                acquiredAll = false
                break
            }
            let descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { acquiredAll = false; break }
            descriptors.append(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { acquiredAll = false; break }
        }
        acquired = acquiredAll
    }

    deinit {
        for descriptor in descriptors { close(descriptor) }
    }
}
