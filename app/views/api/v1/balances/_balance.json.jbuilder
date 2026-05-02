# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

json.id balance.id
json.date balance.date
json.currency balance.currency
json.flows_factor balance.flows_factor

json.balance balance.balance_money.format
json.balance_cents money_to_minor_units.call(balance.balance_money)
json.cash_balance balance.cash_balance_money&.format
json.cash_balance_cents money_to_minor_units.call(balance.cash_balance_money)

json.start_cash_balance balance.start_cash_balance_money.format
json.start_cash_balance_cents money_to_minor_units.call(balance.start_cash_balance_money)
json.start_non_cash_balance balance.start_non_cash_balance_money.format
json.start_non_cash_balance_cents money_to_minor_units.call(balance.start_non_cash_balance_money)
json.start_balance balance.start_balance_money.format
json.start_balance_cents money_to_minor_units.call(balance.start_balance_money)

json.cash_inflows balance.cash_inflows_money.format
json.cash_inflows_cents money_to_minor_units.call(balance.cash_inflows_money)
json.cash_outflows balance.cash_outflows_money.format
json.cash_outflows_cents money_to_minor_units.call(balance.cash_outflows_money)
json.non_cash_inflows balance.non_cash_inflows_money.format
json.non_cash_inflows_cents money_to_minor_units.call(balance.non_cash_inflows_money)
json.non_cash_outflows balance.non_cash_outflows_money.format
json.non_cash_outflows_cents money_to_minor_units.call(balance.non_cash_outflows_money)
json.net_market_flows balance.net_market_flows_money.format
json.net_market_flows_cents money_to_minor_units.call(balance.net_market_flows_money)
json.cash_adjustments balance.cash_adjustments_money.format
json.cash_adjustments_cents money_to_minor_units.call(balance.cash_adjustments_money)
json.non_cash_adjustments balance.non_cash_adjustments_money.format
json.non_cash_adjustments_cents money_to_minor_units.call(balance.non_cash_adjustments_money)

json.end_cash_balance balance.end_cash_balance_money.format
json.end_cash_balance_cents money_to_minor_units.call(balance.end_cash_balance_money)
json.end_non_cash_balance balance.end_non_cash_balance_money.format
json.end_non_cash_balance_cents money_to_minor_units.call(balance.end_non_cash_balance_money)
json.end_balance balance.end_balance_money.format
json.end_balance_cents money_to_minor_units.call(balance.end_balance_money)

json.account do
  json.id balance.account.id
  json.name balance.account.name
  json.account_type balance.account.accountable_type.underscore
end

json.created_at balance.created_at.iso8601
json.updated_at balance.updated_at.iso8601
