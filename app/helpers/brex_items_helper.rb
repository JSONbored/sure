# frozen_string_literal: true

module BrexItemsHelper
  BrexAccountDisplay = Struct.new(
    :id,
    :name,
    :kind,
    :currency,
    :status,
    :blank_name,
    keyword_init: true
  ) do
    alias_method :blank_name?, :blank_name
  end

  def brex_account_display(account)
    data = account.with_indifferent_access
    kind = normalized_brex_account_kind(data)
    name = brex_account_display_name(data, kind)

    BrexAccountDisplay.new(
      id: data[:id],
      name: name,
      kind: kind,
      currency: BrexAccount.currency_code_from_money(data[:current_balance] || data[:available_balance] || data[:account_limit]),
      status: data[:status],
      blank_name: name.blank?
    )
  end

  def brex_account_metadata(display)
    parts = [
      t("brex_items.account_metadata.provider"),
      display.currency,
      display.kind.to_s.titleize,
      display.status.presence&.to_s&.titleize
    ].compact

    parts.join(t("brex_items.account_metadata.separator"))
  end

  def default_brex_depository_subtype(account_name)
    normalized_name = account_name.to_s.downcase

    if normalized_name.match?(/\bchecking\b|\bchequing\b|\bck\b|demand\s+deposit/)
      "checking"
    elsif normalized_name.match?(/\bsavings\b|\bsv\b/)
      "savings"
    elsif normalized_name.match?(/money\s+market|\bmm\b/)
      "money_market"
    else
      "checking"
    end
  end

  private

    def normalized_brex_account_kind(data)
      kind = data[:account_kind].presence || data[:kind].presence || "cash"
      kind.to_s == "credit_card" ? "card" : kind.to_s
    end

    def brex_account_display_name(data, kind)
      return data[:name].presence || t("brex_items.default_card_name") if kind == "card"

      data[:name].presence || data[:display_name].presence || t("brex_items.default_cash_name", id: data[:id])
    end
end
