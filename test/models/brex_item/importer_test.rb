# frozen_string_literal: true

require "test_helper"

class BrexItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @brex_item = brex_items(:one)
    @account = @family.accounts.create!(
      name: "Operating Cash",
      balance: 0,
      currency: "USD",
      accountable: Depository.new(subtype: "checking")
    )
    @brex_account = @brex_item.brex_accounts.create!(
      account_id: "cash_1",
      account_kind: "cash",
      name: "Operating Cash",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: @account, provider: @brex_account)
  end

  test "imports account discovery and fetches transactions only for linked accounts" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload, card_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(
      transactions: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Wire fee",
          posted_at_date: "2026-01-02"
        }
      ]
    )
    provider.expects(:get_primary_card_transactions).never

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:accounts_created]
    assert_equal [ "cash_tx_1" ], @brex_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_equal "card", @brex_item.brex_accounts.find_by!(account_id: BrexAccount.card_account_id).account_kind
  end

  test "marks item as requiring update on authorization errors" do
    provider = mock("brex_provider")
    provider.expects(:get_accounts).raises(
      Provider::Brex::BrexError.new("Access forbidden", :access_forbidden, http_status: 403, trace_id: "trace_123")
    )

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import

    refute result[:success]
    assert @brex_item.reload.requires_update?
  end

  private

    def cash_account_payload
      {
        id: "cash_1",
        name: "Operating Cash",
        account_kind: "cash",
        status: "ACTIVE",
        current_balance: { amount: 120_000, currency: "USD" },
        available_balance: { amount: 110_000, currency: "USD" },
        account_number: "123456789012",
        routing_number: "021000021"
      }
    end

    def card_account_payload
      {
        id: BrexAccount.card_account_id,
        name: "Brex Card",
        account_kind: "card",
        status: "ACTIVE",
        current_balance: { amount: 1_234, currency: "USD" },
        available_balance: { amount: 100_000, currency: "USD" },
        account_limit: { amount: 150_000, currency: "USD" },
        raw_card_accounts: [
          {
            id: "card_account_1",
            card_metadata: {
              pan: "4111111111111111"
            }
          }
        ]
      }
    end
end
