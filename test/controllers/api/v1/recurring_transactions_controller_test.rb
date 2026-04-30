# frozen_string_literal: true

require "test_helper"

class Api::V1::RecurringTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @merchant = @family.merchants.create!(name: "Streaming Service")

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @recurring_transaction = @family.recurring_transactions.create!(
      account: @account,
      merchant: @merchant,
      amount: 19.99,
      currency: "USD",
      expected_day_of_month: 15,
      last_occurrence_date: Date.new(2026, 4, 15),
      next_expected_date: Date.new(2026, 5, 15),
      status: "active",
      occurrence_count: 3,
      manual: true
    )
  end

  test "should list recurring transactions" do
    get api_v1_recurring_transactions_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("recurring_transactions")
    assert response_data.key?("pagination")
    assert_includes response_data["recurring_transactions"].map { |item| item["id"] }, @recurring_transaction.id
  end

  test "should require authentication when listing recurring transactions" do
    get api_v1_recurring_transactions_url

    assert_response :unauthorized
  end

  test "should show recurring transaction" do
    get api_v1_recurring_transaction_url(@recurring_transaction), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @recurring_transaction.id, response_data["id"]
    assert_equal @account.id, response_data["account"]["id"]
    assert_equal @merchant.id, response_data["merchant"]["id"]
  end

  test "should return not found for missing recurring transaction" do
    get api_v1_recurring_transaction_url(SecureRandom.uuid), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should require authentication when showing recurring transaction" do
    get api_v1_recurring_transaction_url(@recurring_transaction)

    assert_response :unauthorized
  end

  test "should create recurring transaction" do
    assert_difference("@family.recurring_transactions.count", 1) do
      post api_v1_recurring_transactions_url,
           params: valid_recurring_transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "Gym Membership", response_data["name"]
    assert_equal true, response_data["manual"]
  end

  test "should require authentication when creating recurring transaction" do
    post api_v1_recurring_transactions_url, params: valid_recurring_transaction_params

    assert_response :unauthorized
  end

  test "should reject create with read-only API key" do
    post api_v1_recurring_transactions_url,
         params: valid_recurring_transaction_params,
         headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should reject create without name or merchant" do
    params = valid_recurring_transaction_params.deep_dup
    params[:recurring_transaction].delete(:name)

    post api_v1_recurring_transactions_url,
         params: params,
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should reject create without required dates" do
    params = valid_recurring_transaction_params.deep_dup
    params[:recurring_transaction].delete(:last_occurrence_date)
    params[:recurring_transaction].delete(:next_expected_date)

    assert_no_difference("@family.recurring_transactions.count") do
      post api_v1_recurring_transactions_url,
           params: params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "Last occurrence date can't be blank"
    assert_includes response_data["errors"], "Next expected date can't be blank"
  end

  test "should return conflict when creating duplicate recurring transaction" do
    params = {
      recurring_transaction: {
        account_id: @account.id,
        merchant_id: @merchant.id,
        amount: @recurring_transaction.amount.to_s,
        currency: @recurring_transaction.currency,
        expected_day_of_month: 15,
        last_occurrence_date: "2026-04-15",
        next_expected_date: "2026-05-15"
      }
    }

    assert_no_difference("@family.recurring_transactions.count") do
      post api_v1_recurring_transactions_url,
           params: params,
           headers: api_headers(@api_key)
    end

    assert_response :conflict
    response_data = JSON.parse(response.body)
    assert_equal "conflict", response_data["error"]
    assert_equal "Recurring transaction already exists", response_data["message"]
  end

  test "should update recurring transaction" do
    patch api_v1_recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { status: "inactive", expected_day_of_month: 16 } },
          headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "inactive", response_data["status"]
    assert_equal 16, response_data["expected_day_of_month"]
  end

  test "should require authentication when updating recurring transaction" do
    patch api_v1_recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { status: "inactive" } }

    assert_response :unauthorized
  end

  test "should reject update with read-only API key" do
    patch api_v1_recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { status: "inactive" } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return not found when updating missing recurring transaction" do
    patch api_v1_recurring_transaction_url(SecureRandom.uuid),
          params: { recurring_transaction: { status: "inactive" } },
          headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should reject invalid recurring transaction update" do
    patch api_v1_recurring_transaction_url(@recurring_transaction),
          params: { recurring_transaction: { expected_day_of_month: 32 } },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should destroy recurring transaction" do
    assert_difference("@family.recurring_transactions.count", -1) do
      delete api_v1_recurring_transaction_url(@recurring_transaction), headers: api_headers(@api_key)
    end

    assert_response :ok
  end

  test "should require authentication when destroying recurring transaction" do
    delete api_v1_recurring_transaction_url(@recurring_transaction)

    assert_response :unauthorized
  end

  test "should reject destroy with read-only API key" do
    delete api_v1_recurring_transaction_url(@recurring_transaction), headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should return not found when destroying missing recurring transaction" do
    delete api_v1_recurring_transaction_url(SecureRandom.uuid), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should not create recurring transaction for another family account" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_account = Account.create!(
      family: other_family,
      name: "Other Checking",
      currency: "USD",
      classification: "asset",
      accountable: Depository.create!,
      balance: 0
    )

    post api_v1_recurring_transactions_url,
         params: {
           recurring_transaction: {
             account_id: other_account.id,
             name: "Gym Membership",
             amount: 49.99,
             currency: "USD",
             expected_day_of_month: 1,
             last_occurrence_date: "2026-04-01",
             next_expected_date: "2026-05-01"
           }
         },
         headers: api_headers(@api_key)

    assert_response :not_found
  end

  private

    def valid_recurring_transaction_params
      {
        recurring_transaction: {
          account_id: @account.id,
          name: "Gym Membership",
          amount: 49.99,
          currency: "USD",
          expected_day_of_month: 1,
          last_occurrence_date: "2026-04-01",
          next_expected_date: "2026-05-01",
          status: "active",
          occurrence_count: 1
        }
      }
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
