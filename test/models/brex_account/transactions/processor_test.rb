# frozen_string_literal: true

require "test_helper"

class BrexAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @brex_item = brex_items(:one)
    @brex_account = @brex_item.brex_accounts.create!(
      account_id: "cash_unlinked",
      account_kind: "cash",
      name: "Unlinked Cash",
      currency: "USD",
      raw_transactions_payload: [
        {
          id: "tx_skipped",
          amount: { amount: 1_00, currency: "USD" },
          description: "Skipped transaction",
          posted_at_date: "2026-01-02"
        }
      ]
    )
  end

  test "counts intentionally skipped transactions separately from failures" do
    result = BrexAccount::Transactions::Processor.new(@brex_account).process

    assert result[:success]
    assert_equal 1, result[:total]
    assert_equal 0, result[:imported]
    assert_equal 1, result[:skipped]
    assert_equal 0, result[:failed]
    assert_equal "No linked account", result[:skipped_transactions].first[:reason]
    assert_empty result[:errors]
  end
end
