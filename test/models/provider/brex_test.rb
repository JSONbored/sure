require "test_helper"

class Provider::BrexTest < ActiveSupport::TestCase
  def setup
    @provider = Provider::Brex.new("test_token", base_url: "https://staging.example.test")
  end

  test "initializes with token and default base_url" do
    provider = Provider::Brex.new("my_token")
    assert_equal "my_token", provider.token
    assert_equal "https://api.brex.com", provider.base_url
  end

  test "initializes with custom base_url" do
    assert_equal "test_token", @provider.token
    assert_equal "https://staging.example.test", @provider.base_url
  end

  test "initializes with stripped token and removes trailing base url slash" do
    provider = Provider::Brex.new(" test_token \n", base_url: "https://api.brex.com/")

    assert_equal "test_token", provider.token
    assert_equal "https://api.brex.com", provider.base_url
  end

  test "BrexError includes error_type" do
    error = Provider::Brex::BrexError.new("Test error", :unauthorized)
    assert_equal "Test error", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "BrexError defaults error_type to unknown" do
    error = Provider::Brex::BrexError.new("Test error")
    assert_equal :unknown, error.error_type
  end

  test "fetches cash accounts from the v2 endpoint with bearer auth" do
    response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "cash_1", name: "Operating" } ] }.to_json,
      headers: {}
    )

    Provider::Brex.expects(:get)
      .with(
        "https://api.brex.com/v2/accounts/cash?limit=1000",
        headers: {
          "Authorization" => "Bearer test_token",
          "Content-Type" => "application/json",
          "Accept" => "application/json"
        }
      )
      .returns(response)

    accounts = Provider::Brex.new(" test_token ").get_cash_accounts

    assert_equal 1, accounts.length
    assert_equal "cash_1", accounts.first[:id]
    assert_equal "cash", accounts.first[:account_kind]
  end

  test "aggregates card accounts into one provider account" do
    cash_response = OpenStruct.new(
      code: 200,
      body: { items: [] }.to_json,
      headers: {}
    )
    card_response = OpenStruct.new(
      code: 200,
      body: {
        items: [
          {
            id: "card_account_1",
            status: "ACTIVE",
            current_balance: { amount: 12_345, currency: "USD" },
            available_balance: { amount: 100_000, currency: "USD" },
            account_limit: { amount: 250_000, currency: "USD" }
          }
        ]
      }.to_json,
      headers: {}
    )

    Provider::Brex.stubs(:get).returns(cash_response, card_response)

    accounts_data = Provider::Brex.new("test_token").get_accounts

    assert_equal [ "card_primary" ], accounts_data[:accounts].map { |account| account[:id] }
    assert_equal "card", accounts_data[:accounts].first[:account_kind]
    assert_equal 1, accounts_data[:accounts].first[:card_accounts_count]
  end

  test "guards repeated pagination cursors" do
    first_response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "tx_1" } ], next_cursor: "cursor_1" }.to_json,
      headers: {}
    )
    second_response = OpenStruct.new(
      code: 200,
      body: { items: [ { id: "tx_2" } ], next_cursor: "cursor_1" }.to_json,
      headers: {}
    )

    Provider::Brex.stubs(:get).returns(first_response, second_response)

    error = assert_raises Provider::Brex::BrexError do
      Provider::Brex.new("test_token").get_primary_card_transactions
    end

    assert_equal :pagination_error, error.error_type
  end

  test "maps rate limits and exposes trace id without leaking body" do
    response = OpenStruct.new(
      code: 429,
      body: { message: "secret raw provider body" }.to_json,
      headers: { "x-brex-trace-id" => "trace_123" }
    )

    Provider::Brex.stubs(:get).returns(response)

    error = assert_raises Provider::Brex::BrexError do
      Provider::Brex.new("test_token").get_cash_accounts
    end

    assert_equal :rate_limited, error.error_type
    assert_equal 429, error.http_status
    assert_equal "trace_123", error.trace_id
    refute_includes error.message, "secret raw provider body"
  end
end
