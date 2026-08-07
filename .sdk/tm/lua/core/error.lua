-- Univec SDK error

local UnivecError = {}
UnivecError.__index = UnivecError


function UnivecError.new(code, msg, ctx)
  local self = setmetatable({}, UnivecError)
  self.is_sdk_error = true
  self.sdk = "Univec"
  self.code = code or ""
  self.msg = msg or ""
  self.ctx = ctx
  self.result = nil
  self.spec = nil
  return self
end


function UnivecError:error()
  return self.msg
end


function UnivecError:__tostring()
  return self.msg
end


return UnivecError
