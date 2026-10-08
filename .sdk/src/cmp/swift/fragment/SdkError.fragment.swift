// ProjectNameError - the SDK error type. Carries the pipeline error code, the
// originating context and cleaned result/spec snapshots.

import Foundation

public final class ProjectNameError: Error {
  public let isProjectNameError = true
  public let sdk = "ProjectName"

  // Clean rewrites the code and the message in place, since the error is
  // about to be thrown.
  public internal(set) var code: String
  public internal(set) var message: String

  // Reachable for a debugger, out of every printer and mirror: the context
  // holds the live spec and options, and an error is what gets logged.
  public var ctx: Context?

  // The HTTP status, -1 when there was no response.
  public var status: Int = -1

  public var resultVal: Value = .noval
  public var specVal: Value = .noval

  public init(_ code: String, _ message: String, _ ctx: Context?) {
    self.code = code
    self.message = message
    self.ctx = ctx
  }

  public var notFound: Bool { 404 == status }

  // What makeError attached is already cleaned; the context is not part of
  // the record.
  public func record() -> VMap {
    let out = VMap()
    out.entries["sdk"] = .string(sdk)
    out.entries["code"] = .string(code)
    out.entries["message"] = .string(message)
    out.entries["status"] = .int(Int64(status))
    out.entries["result"] = resultVal
    out.entries["spec"] = specVal
    return out
  }
}

// `description` is the message; every other default print - String(reflecting:),
// debugPrint, dump - is the record, so none of them walks into the context.
extension ProjectNameError: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { message }

  public var debugDescription: String {
    "ProjectNameError [" + code + "] " + message + " (status " + String(status) + ") spec="
      + jsonify(specVal, indent: 0)
  }

  public var customMirror: Mirror {
    Mirror(self, children: [
      "code": code,
      "message": message,
      "status": status,
      "result": jsonify(resultVal, indent: 0),
      "spec": jsonify(specVal, indent: 0),
    ])
  }
}
