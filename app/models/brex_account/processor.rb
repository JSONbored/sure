# frozen_string_literal: true

class BrexAccount::Processor
  include CurrencyNormalizable

  attr_reader :brex_account

  def initialize(brex_account)
    @brex_account = brex_account
  end

  def process
    unless brex_account.current_account.present?
      Rails.logger.info "BrexAccount::Processor - No linked account for brex_account #{brex_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "BrexAccount::Processor - Failed to process account #{brex_account.id}: #{e.message}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = brex_account.current_account
      balance = brex_account.current_balance || 0
      currency = parse_currency(brex_account.currency) || "USD"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )

      if account.accountable_type == "CreditCard" && brex_account.available_balance.present?
        account.accountable.update!(available_credit: brex_account.available_balance)
      end
    end

    def process_transactions
      BrexAccount::Transactions::Processor.new(brex_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          brex_account_id: brex_account.id,
          context: context
        )
      end
    end
end
