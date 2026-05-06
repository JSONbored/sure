require "test_helper"

class MerchantTest < ActiveSupport::TestCase
  test "extract_domain normalizes website URLs" do
    assert_equal "example.com", Merchant.extract_domain("https://www.Example.com/path")
  end

  test "extract_domain returns nil for malformed URLs" do
    assert_nil Merchant.extract_domain("https://bad host")
  end

  test "extract_domain salvages host from malformed URL paths" do
    assert_equal "example.com", Merchant.extract_domain("https://www.Example.com/%")
  end

  test "brandfetch_logo_url_for encodes domain path segment" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    Setting.stubs(:brand_fetch_logo_size).returns(128)
    # Defensive encoding: extract_domain rejects slashes, but callers should
    # still encode unexpected domain values.
    Merchant.stubs(:extract_domain).returns("example.com/path")

    logo_url = Merchant.brandfetch_logo_url_for("https://example.com/path")

    assert_includes logo_url, "cdn.brandfetch.io/example.com%2Fpath/icon"
  end
end
