# frozen_string_literal: true

require "test_helper"

class BrexItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    Rails.cache.clear
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = brex_items(:one)
    @second_item = BrexItem.create!(
      family: @family,
      name: "Business Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )
  end

  teardown do
    Rails.cache.clear
  end

  test "create adds a new brex connection without overwriting existing credentials" do
    existing_token = @existing_item.token

    assert_difference "BrexItem.count", 1 do
      post brex_items_url, params: {
        brex_item: {
          name: "Joint Brex",
          token: "joint_brex_token",
          base_url: "https://api.brex.com"
        }
      }
    end

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "joint_brex_token", @family.brex_items.find_by!(name: "Joint Brex").token
  end

  test "update changes only the selected brex connection" do
    existing_token = @existing_item.token

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "updated_second_token",
        base_url: "https://staging.example.test"
      }
    }

    assert_redirected_to accounts_path
    assert_equal existing_token, @existing_item.reload.token
    assert_equal "Renamed Business Brex", @second_item.reload.name
    assert_equal "updated_second_token", @second_item.token
    assert_equal "https://staging.example.test", @second_item.base_url
  end

  test "blank token update preserves the selected brex token" do
    original_token = @second_item.token

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "",
        base_url: "https://api.brex.com"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Brex", @second_item.reload.name
    assert_equal original_token, @second_item.token
  end

  test "update expires selected brex account cache when credentials change" do
    Rails.cache.expects(:delete).with(brex_cache_key(@existing_item)).never
    Rails.cache.expects(:delete).with(brex_cache_key(@second_item)).once

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex",
        token: "updated_second_token",
        base_url: "https://staging.example.test"
      }
    }

    assert_redirected_to accounts_path
  end

  test "update does not expire selected brex account cache for name-only changes" do
    Rails.cache.expects(:delete).never

    patch brex_item_url(@second_item), params: {
      brex_item: {
        name: "Renamed Business Brex"
      }
    }

    assert_redirected_to accounts_path
    assert_equal "Renamed Business Brex", @second_item.reload.name
  end

  test "preload accounts uses selected brex item cache key" do
    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get preload_accounts_brex_items_url, params: { brex_item_id: @second_item.id }, as: :json

    assert_response :success
    response = JSON.parse(@response.body)
    assert_equal true, response["success"]
    assert_equal true, response["has_accounts"]
  end

  test "select accounts requires an explicit connection when multiple brex items exist" do
    get select_accounts_brex_items_url, params: { accountable_type: "Depository" }

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Brex connection in Provider Settings.", flash[:alert]
  end

  test "select accounts renders the selected brex item id" do
    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_accounts_brex_items_url, params: {
      brex_item_id: @second_item.id,
      accountable_type: "Depository"
    }

    assert_response :success
    assert_includes @response.body, %(name="brex_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "select existing account renders the selected brex item id" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    Rails.cache.expects(:read).with(brex_cache_key(@second_item)).returns(nil)
    Rails.cache.expects(:write).with(brex_cache_key(@second_item), brex_accounts_payload, expires_in: 5.minutes)

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    get select_existing_account_brex_items_url, params: {
      brex_item_id: @second_item.id,
      account_id: account.id
    }

    assert_response :success
    assert_includes @response.body, %(name="brex_item_id")
    assert_includes @response.body, %(value="#{@second_item.id}")
  end

  test "link accounts uses selected brex item and allows duplicate upstream ids across items" do
    @existing_item.brex_accounts.create!(
      account_id: "shared_brex_account",
      name: "Shared Checking",
      currency: "USD",
      current_balance: 1000
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: brex_accounts_payload)
    Provider::Brex.expects(:new)
      .with(@second_item.token, base_url: @second_item.effective_base_url)
      .returns(provider)

    assert_difference -> { @second_item.brex_accounts.where(account_id: "shared_brex_account").count }, 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_brex_items_url, params: {
          brex_item_id: @second_item.id,
          account_ids: [ "shared_brex_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to accounts_path
    assert_equal 1, @existing_item.brex_accounts.where(account_id: "shared_brex_account").count
  end

  test "link accounts does not silently use the first connection when multiple items exist" do
    assert_no_difference "BrexAccount.count" do
      assert_no_difference "Account.count" do
        post link_accounts_brex_items_url, params: {
          account_ids: [ "shared_brex_account" ],
          accountable_type: "Depository"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Brex connection before linking accounts.", flash[:alert]
  end

  test "link existing account does not silently use the first connection when multiple items exist" do
    account = @family.accounts.create!(
      name: "Manual Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_no_difference "BrexAccount.count" do
      assert_no_difference "AccountProvider.count" do
        post link_existing_account_brex_items_url, params: {
          account_id: account.id,
          brex_account_id: "shared_brex_account"
        }
      end
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Brex connection before linking accounts.", flash[:alert]
  end

  test "sync only queues a sync for the selected brex item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_brex_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  private

    def brex_accounts_payload
      [
        {
          id: "shared_brex_account",
          name: "Shared Checking",
          account_kind: "cash",
          status: "active",
          current_balance: { amount: 100_000, currency: "USD" },
          available_balance: { amount: 95_000, currency: "USD" }
        }
      ]
    end

    def brex_cache_key(brex_item)
      "brex_accounts_#{@family.id}_#{brex_item.id}"
    end
end
