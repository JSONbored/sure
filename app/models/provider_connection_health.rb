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
        family.public_send(provider[:association]).includes(association_includes_for(family, provider)).ordered.map do |item|
          new(provider, item).to_h
        end
      end
    end

    private

      def association_includes_for(family, provider)
        relation = family.public_send(provider[:association])
        includes = [ :syncs, provider[:accounts] ]
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
      type: provider[:type],
      name: item.name,
      status: item.status,
      requires_update: item.respond_to?(:requires_update?) ? item.requires_update? : false,
      credentials_configured: credentials_configured?,
      scheduled_for_deletion: item.respond_to?(:scheduled_for_deletion?) ? item.scheduled_for_deletion? : false,
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
      return false unless item.respond_to?(:credentials_configured?)

      item.credentials_configured?
    end

    def pending_account_setup?
      return item.pending_account_setup? if item.respond_to?(:pending_account_setup?)

      false
    end

    def institution_payload
      {
        name: item.respond_to?(:institution_display_name) ? item.institution_display_name : item.name,
        domain: item.respond_to?(:institution_domain) ? item.institution_domain : nil,
        url: item.respond_to?(:institution_url) ? item.institution_url : nil
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
      latest_sync = item.syncs.max_by(&:created_at)

      {
        syncing: item.respond_to?(:syncing?) ? item.syncing? : false,
        status_summary: item.respond_to?(:sync_status_summary) ? item.sync_status_summary : nil,
        last_synced_at: item.respond_to?(:last_synced_at) ? item.last_synced_at : nil,
        latest: latest_sync_payload(latest_sync)
      }
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
        present: sync.error.present?,
        message: sync.stale? ? "Sync became stale before completion" : "Sync failed"
      }
    end
end
