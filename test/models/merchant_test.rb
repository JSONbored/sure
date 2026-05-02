require "test_helper"

class MerchantTest < ActiveSupport::TestCase
  test "extract_domain normalizes website URLs" do
    assert_equal "example.com", Merchant.extract_domain("https://www.Example.com/path")
  end

  test "extract_domain returns nil for malformed URLs" do
    assert_nil Merchant.extract_domain("https://bad host")
  end
end
