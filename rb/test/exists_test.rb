# Univec SDK exists test

require "minitest/autorun"
require_relative "../Univec_sdk"

class ExistsTest < Minitest::Test
  def test_create_test_sdk
    testsdk = UnivecSDK.test(nil, nil)
    assert !testsdk.nil?
  end
end
