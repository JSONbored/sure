# frozen_string_literal: true

json.id account.id
json.name account.name
json.balance account.balance_money.format
json.cash_balance account.cash_balance_money.format
json.currency account.currency
json.classification account.classification
json.account_type account.accountable_type&.underscore
json.subtype account.subtype
json.status account.status
json.institution_name account.institution_name
json.institution_domain account.institution_domain
json.created_at account.created_at.iso8601
json.updated_at account.updated_at.iso8601
