class BrexItem::Syncer
  include SyncStats::Collector

  attr_reader :brex_item

  def initialize(brex_item)
    @brex_item = brex_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Brex API
    sync.update!(status_text: "Importing accounts from Brex...") if sync.respond_to?(:status_text)
    brex_item.import_latest_brex_data

    # Phase 2: Collect setup statistics using shared concern
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: brex_item.brex_accounts)

    # Check for unlinked accounts
    linked_accounts = brex_item.brex_accounts.joins(:account_provider)
    unlinked_accounts = brex_item.brex_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      brex_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      brex_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      Rails.logger.info "BrexItem::Syncer - Processing #{linked_accounts.count} linked accounts"
      brex_item.process_accounts
      Rails.logger.info "BrexItem::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      brex_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts.includes(:account_provider).filter_map { |ma| ma.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "brex")
    else
      Rails.logger.info "BrexItem::Syncer - No linked accounts to process"
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end
end
