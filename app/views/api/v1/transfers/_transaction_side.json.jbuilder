# frozen_string_literal: true

entry = transaction.entry
money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

json.id transaction.id
json.entry_id entry.id
json.date entry.date
json.amount entry.amount_money.format
json.amount_cents money_to_minor_units.call(entry.amount_money)
json.currency entry.currency
json.name entry.name
json.kind transaction.kind

json.account do
  json.id entry.account.id
  json.name entry.account.name
  json.account_type entry.account.accountable_type.underscore
end
