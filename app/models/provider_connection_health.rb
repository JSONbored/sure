# frozen_string_literal: true

class ProviderConnectionHealth
  PROVIDERS = [
    { key: "plaid", type: "PlaidItem", association: :plaid_items, accounts: :plaid_accounts },
    { key: "simplefin", type: "SimplefinItem", association: :simplefin_items, accounts: :simplefin_accounts },
    { key: "lunchflow", type: "LunchflowItem", association: :lunchflow_items, accounts: :lunchflow_accounts },
    { key: "enable_banking", type: "EnableBankingItem", association: :enable_banking_items, accounts: :enable_banking_accounts },
    { key: "coinbase", type: "CoinbaseItem", association: :coinbase_items, accounts: :coinbase_accounts },
    { key: "binance", type: "BinanceItem", association: :binance_items, accounts: :binance_accounts },
    { key: "coinstats", type: "CoinstatsItem", association: :coinstats_items, accounts: :coinstats_accounts },
    { key: "snaptrade", type: "SnaptradeItem", association: :snaptrade_items, accounts: :snaptrade_accounts, linked_accounts: :linked_accounts },
    { key: "mercury", type: "MercuryItem", association: :mercury_items, accounts: :mercury_accounts },
    { key: "sophtron", type: "SophtronItem", association: :sophtron_items, accounts: :sophtron_accounts },
    { key: "indexa_capital", type: "IndexaCapitalItem", association: :indexa_capital_items, accounts: :indexa_capital_accounts }
  ].freeze

  class << self
    def for_family(family)
      PROVIDERS.flat_map do |provider|
        relation = family.public_send(provider[:association])

        relation.includes(association_includes_for(relation, provider)).ordered.map do |item|
          new(provider, item).to_h
        end
      end
    end

    private

      def association_includes_for(relation, provider)
        includes = [ provider[:accounts] ]
        includes << provider[:linked_accounts] if provider[:linked_accounts]
        includes << :accounts if relation.klass.reflect_on_association(:accounts)
        includes
      end
  end

  def initialize(provider, item)
    @provider = provider
    @item = item
  end

  def to_h
    {
      id: item.id,
      provider: provider[:key],
      provider_type: provider[:type],
      name: item.name,
      status: item.status,
      requires_update: item_boolean(:requires_update?),
      credentials_configured: credentials_configured?,
      scheduled_for_deletion: item_boolean(:scheduled_for_deletion?),
      pending_account_setup: pending_account_setup?,
      institution: institution_payload,
      accounts: accounts_payload,
      sync: sync_payload,
      created_at: item.created_at,
      updated_at: item.updated_at
    }
  end

  private

    attr_reader :provider, :item

    def credentials_configured?
      item_boolean(:credentials_configured?)
    end

    def pending_account_setup?
      item_boolean(:pending_account_setup?)
    end

    def institution_payload
      {
        name: item_value(:institution_display_name, item.name),
        domain: item_value(:institution_domain),
        url: item_value(:institution_url)
      }
    end

    def accounts_payload
      total = provider_account_count
      linked = linked_account_count

      {
        total_count: total,
        linked_count: linked,
        unlinked_count: [ total - linked, 0 ].max
      }
    end

    def provider_account_count
      return 0 unless item.respond_to?(provider[:accounts])

      item.public_send(provider[:accounts]).size
    end

    def linked_account_count
      if provider[:linked_accounts] && item.respond_to?(provider[:linked_accounts])
        return item.public_send(provider[:linked_accounts]).size
      end

      return item.accounts.size if item.respond_to?(:accounts)

      0
    end

    def sync_payload
      {
        syncing: item_boolean(:syncing?),
        status_summary: item_value(:sync_status_summary),
        last_synced_at: item_value(:last_synced_at),
        latest: latest_sync_payload(latest_sync)
      }
    end

    def latest_sync
      @latest_sync ||= item.syncs.ordered.first
    end

    def latest_sync_payload(sync)
      return unless sync

      {
        id: sync.id,
        status: sync.status,
        created_at: sync.created_at,
        syncing_at: sync.syncing_at,
        completed_at: sync.completed_at,
        failed_at: sync.failed_at,
        error: sync_error_payload(sync)
      }
    end

    def sync_error_payload(sync)
      return unless sync.failed? || sync.stale?

      {
        present: true,
        message: sync.stale? ? "Sync became stale before completion" : "Sync failed"
      }
    end

    def item_boolean(method_name)
      item_value(method_name, false) == true
    end

    def item_value(method_name, default = nil)
      return default unless item.respond_to?(method_name)

      item.public_send(method_name)
    end
end
