# frozen_string_literal: true

require "test_helper"

class Api::V1::ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @mercury_item = mercury_items(:one)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @write_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@write_key.id}")
  end

  test "lists provider connection health for current family" do
    failed_sync = @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "secret token failed"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    mercury_connection = json_response["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_not_nil mercury_connection
    assert_equal "mercury", mercury_connection["provider"]
    assert_equal "MercuryItem", mercury_connection["type"]
    assert_equal @mercury_item.name, mercury_connection["name"]
    assert_equal @mercury_item.status, mercury_connection["status"]
    assert_equal true, mercury_connection["credentials_configured"]
    assert_equal @mercury_item.mercury_accounts.count, mercury_connection["accounts"]["total_count"]
    assert_equal failed_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal "Sync failed", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "does not expose provider secrets or raw sync errors" do
    @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "raw provider token secret"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    refute_includes response.body, @mercury_item.token
    refute_includes response.body, "raw provider token secret"
  end

  test "excludes another family's provider connections" do
    other_item = snaptrade_items(:pending_registration_item)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    ids = JSON.parse(response.body)["data"].map { |connection| connection["id"] }
    assert_not_includes ids, other_item.id
  end

  test "read_write key can list provider connection health" do
    get api_v1_provider_connections_url, headers: api_headers(@write_key)
    assert_response :success
  end

  test "requires authentication" do
    get api_v1_provider_connections_url
    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
