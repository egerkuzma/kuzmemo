import Foundation
import Network
import KuzmemoCore

/// A tiny HTTP/1.1 server on a Unix-domain socket (mode 0600), used for automated end-to-end checks:
/// `curl --unix-socket .../control.sock http://x/state`. Only started for the dev bundle or KUZMEMO_CONTROL=1.
nonisolated final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let socketPath: String
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.kuzmemo.control")

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        let url = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: url)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        let path = socketPath
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: chmod(path, 0o600)
            case let .failed(error): NSLog("Kuzmemo control listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that connects and says nothing, or stops half-way, must not hold the connection for ever: reading the
        // request has twenty seconds (the answer may take as long as it needs, the timer is gone by then).
        let reading = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { connection.cancel() }
        }
        receive(connection, buffer: Data(), reading: reading)
    }

    private func receive(_ connection: NWConnection, buffer: Data, reading: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case let .complete(request):
                reading.cancel()
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            case .needMore:
                if isComplete || error != nil { reading.cancel(); connection.cancel() } else { self.receive(connection, buffer: buffer, reading: reading) }
            case .invalid:
                reading.cancel()
                self.send(.error("bad request", status: 400), on: connection)
            case .tooLarge:
                reading.cancel()
                self.send(.error("request too large", status: 413), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
