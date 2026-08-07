-- Univec SDK exists test

local sdk = require("univec_sdk")

describe("UnivecSDK", function()
  it("should create test SDK", function()
    local testsdk = sdk.test(nil, nil)
    assert.is_not_nil(testsdk)
  end)
end)
