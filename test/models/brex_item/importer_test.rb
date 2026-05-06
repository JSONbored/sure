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

  test "counts only newly stored transactions as imported" do
    @brex_account.update!(
      raw_transactions_payload: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Existing wire fee",
          posted_at_date: "2026-01-02"
        }
      ]
    )

    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: anything).returns(
      transactions: [
        {
          id: "cash_tx_1",
          amount: { amount: 12_34, currency: "USD" },
          description: "Existing wire fee",
          posted_at_date: "2026-01-02"
        },
        {
          id: "cash_tx_2",
          amount: { amount: 56_78, currency: "USD" },
          description: "New wire fee",
          posted_at_date: "2026-01-03"
        }
      ]
    )

    result = BrexItem::Importer.new(@brex_item, brex_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:transactions_imported]
    assert_equal [ "cash_tx_1", "cash_tx_2" ], @brex_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "uses explicit sync start date for cash and card transaction fetches" do
    card_account = @family.accounts.create!(
      name: "Brex Card",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.new
    )
    brex_card_account = @brex_item.brex_accounts.create!(
      account_id: BrexAccount.card_account_id,
      account_kind: "card",
      name: "Brex Card",
      currency: "USD",
      current_balance: 0
    )
    AccountProvider.create!(account: card_account, provider: brex_card_account)

    sync_start_date = Date.new(2026, 2, 1)
    provider = mock("brex_provider")
    provider.expects(:get_accounts).returns(accounts: [ cash_account_payload, card_account_payload ])
    provider.expects(:get_cash_transactions).with("cash_1", start_date: sync_start_date).returns(transactions: [])
    provider.expects(:get_primary_card_transactions).with(start_date: sync_start_date).returns(transactions: [])

    result = BrexItem::Importer.new(
      @brex_item,
      brex_provider: provider,
      sync_start_date: sync_start_date
    ).import

    assert result[:success]
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
        account_number: "account-last4-9012",
        routing_number: "routing-last4-0021"
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
              pan: "test-pan-placeholder"
            }
          }
        ]
      }
    end
end
