// UnivecError - the SDK error type. Carries the pipeline error code, the
// originating context and cleaned result/spec snapshots.

import Foundation

public final class UnivecError: Error, CustomStringConvertible {
  public let isUnivecError = true
  public let sdk = "Univec"
  public let code: String
  public let message: String
  public var ctx: Context?
  public var resultVal: Value = .noval
  public var specVal: Value = .noval

  public init(_ code: String, _ message: String, _ ctx: Context?) {
    self.code = code
    self.message = message
    self.ctx = ctx
  }

  public var description: String { message }
}
