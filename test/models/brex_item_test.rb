require "test_helper"

class BrexItemTest < ActiveSupport::TestCase
  def setup
    @brex_item = brex_items(:one)
  end

  test "fixture is valid" do
    assert @brex_item.valid?
  end

  test "belongs to family" do
    assert_equal families(:dylan_family), @brex_item.family
  end

  test "credentials_configured returns true when token present" do
    assert @brex_item.credentials_configured?
  end

  test "credentials_configured returns false when token blank" do
    @brex_item.token = nil
    assert_not @brex_item.credentials_configured?
  end

  test "credentials_configured returns false when token is whitespace" do
    @brex_item.token = "   "
    assert_not @brex_item.credentials_configured?
  end

  test "effective_base_url returns custom url when set" do
    assert_equal "https://staging.example.test", @brex_item.effective_base_url
  end

  test "effective_base_url returns default when base_url blank" do
    @brex_item.base_url = nil
    assert_equal "https://api.brex.com", @brex_item.effective_base_url
  end

  test "brex_provider returns Provider::Brex instance" do
    provider = @brex_item.brex_provider
    assert_instance_of Provider::Brex, provider
    assert_equal @brex_item.token, provider.token
  end

  test "brex_provider returns nil when credentials not configured" do
    @brex_item.token = nil
    assert_nil @brex_item.brex_provider
  end

  test "family credential check ignores blank and scheduled for deletion items" do
    family = families(:empty)
    blank_item = BrexItem.create!(
      family: family,
      name: "Blank Brex",
      token: "temporary_token",
      base_url: "https://staging.example.test"
    )
    blank_item.update_column(:token, "")

    whitespace_item = BrexItem.create!(
      family: family,
      name: "Whitespace Brex",
      token: "temporary_token",
      base_url: "https://staging.example.test"
    )
    whitespace_item.update_column(:token, "   ")

    deleted_item = BrexItem.create!(
      family: family,
      name: "Deleted Brex",
      token: "deleted_token",
      base_url: "https://staging.example.test",
      scheduled_for_deletion: true
    )

    refute family.has_brex_credentials?

    whitespace_item.update_column(:token, "configured_token")
    assert family.has_brex_credentials?

    whitespace_item.update_column(:token, "   ")
    deleted_item.update!(scheduled_for_deletion: false)
    assert family.has_brex_credentials?
  end

  test "syncer returns BrexItem::Syncer instance" do
    syncer = @brex_item.send(:syncer)
    assert_instance_of BrexItem::Syncer, syncer
  end
end
