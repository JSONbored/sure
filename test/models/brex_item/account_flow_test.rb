# frozen_string_literal: true

require "test_helper"

class BrexItem::AccountFlowTest < ActiveSupport::TestCase
  setup do
    SyncJob.stubs(:perform_later)
    @family = families(:dylan_family)
    @brex_item = brex_items(:one)
  end

  test "requires explicit item when multiple credentialed connections exist" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    flow = BrexItem::AccountFlow.new(family: @family)

    assert_not flow.selected?
    assert flow.selection_required?
  end

  test "preload payload returns explicit selection error when multiple connections exist" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    payload = BrexItem::AccountFlow.new(family: @family).preload_payload

    assert_equal false, payload[:success]
    assert_equal "select_connection", payload[:error]
    assert_nil payload[:has_accounts]
  end

  test "link result returns navigation instead of raising expected selection errors" do
    BrexItem.create!(
      family: @family,
      name: "Second Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    result = BrexItem::AccountFlow.new(family: @family).link_new_accounts_result(
      account_ids: [ "cash_import_1" ],
      accountable_type: "Depository"
    )

    assert_equal :settings_providers, result.target
    assert_equal :alert, result.flash_type
    assert_equal I18n.t("brex_items.link_accounts.select_connection"), result.message
  end

  test "imports provider accounts into the selected item" do
    brex_item = BrexItem.create!(
      family: @family,
      name: "Import Brex",
      token: "import_brex_token",
      base_url: "https://api.brex.com"
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(
      accounts: [
        {
          id: "cash_import_1",
          name: "Imported Cash",
          account_kind: "cash",
          current_balance: { amount: 12_345, currency: "USD" },
          account_number: "account-last4-3456"
        }
      ]
    )
    brex_item.expects(:brex_provider).returns(provider)

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: brex_item)

    assert_difference -> { brex_item.brex_accounts.count }, 1 do
      assert_nil flow.import_accounts_from_api_if_needed
    end

    brex_account = brex_item.brex_accounts.find_by!(account_id: "cash_import_1")
    assert_equal "Imported Cash", brex_account.name
    assert_equal "3456", brex_account.raw_payload["account_number_last4"]
    refute_includes brex_account.raw_payload.to_s, "account-last4-3456"
  end

  test "complete setup creates account links with default subtype" do
    brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_cash_1",
      account_kind: "cash",
      name: "Setup Cash",
      currency: "USD",
      current_balance: 100
    )

    flow = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item)

    assert_difference "AccountProvider.count", 1 do
      result = flow.complete_setup!(
        account_types: { brex_account.id => "Depository" },
        account_subtypes: {}
      )

      assert_equal 1, result.created_count
      assert_equal 0, result.skipped_count
    end

    account = brex_account.reload.account
    assert_equal "Setup Cash", account.name
    assert_equal "checking", account.accountable.subtype
  end

  test "complete setup result returns localized notice" do
    brex_account = @brex_item.brex_accounts.create!(
      account_id: "setup_result_cash_1",
      account_kind: "cash",
      name: "Setup Result Cash",
      currency: "USD",
      current_balance: 100
    )

    result = BrexItem::AccountFlow.new(family: @family, brex_item: @brex_item).complete_setup_result(
      account_types: { brex_account.id => "Depository" },
      account_subtypes: {}
    )

    assert result.success?
    assert_equal I18n.t("brex_items.complete_account_setup.success", count: 1), result.message
  end
end
