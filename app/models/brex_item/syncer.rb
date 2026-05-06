class BrexItem::Syncer
  include SyncStats::Collector

  SafeSyncError = Class.new(StandardError)

  attr_reader :brex_item

  def initialize(brex_item)
    @brex_item = brex_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Brex API
    update_status(sync, :importing_accounts)
    brex_item.import_latest_brex_data(sync_start_date: sync.window_start_date)

    # Phase 2: Collect setup statistics
    update_status(sync, :checking_account_configuration)

    linked_count = brex_item.brex_accounts.joins(:account_provider).count
    unlinked_count = brex_item.brex_accounts
                             .left_joins(:account_provider)
                             .where(account_providers: { id: nil })
                             .count
    total_count = linked_count + unlinked_count
    collect_brex_setup_stats(
      sync,
      total_count: total_count,
      linked_count: linked_count,
      unlinked_count: unlinked_count
    )

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_count.positive?
      brex_item.update!(pending_account_setup: true)
      update_status(sync, :accounts_need_setup, count: unlinked_count)
    else
      brex_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_count.positive?
      linked_accounts = brex_item.brex_accounts.joins(:account_provider)
      update_status(sync, :processing_transactions)
      mark_import_started(sync)
      Rails.logger.info "BrexItem::Syncer - Processing #{linked_count} linked accounts"
      brex_item.process_accounts
      Rails.logger.info "BrexItem::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      update_status(sync, :calculating_balances)
      brex_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts
                    .includes(account_provider: :account)
                    .filter_map { |ma| ma.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "brex")
    else
      Rails.logger.info "BrexItem::Syncer - No linked accounts to process"
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue => e
    safe_message = user_safe_error_message(e)
    Rails.logger.error "BrexItem::Syncer - sync failed for Brex item #{brex_item.id}: #{e.class} - #{e.message}"
    Rails.logger.error Array(e.backtrace).first(10).join("\n")
    Sentry.capture_exception(e) do |scope|
      scope.set_tags(brex_item_id: brex_item.id)
    end
    collect_health_stats(sync, errors: [ { message: safe_message, category: "sync_error" } ])
    raise SafeSyncError, safe_message
  end

  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, key, **options)
      return unless sync.respond_to?(:status_text)

      sync.update!(status_text: I18n.t("brex_items.syncer.#{key}", **options))
    end

    def collect_brex_setup_stats(sync, total_count:, linked_count:, unlinked_count:)
      return {} unless sync.respond_to?(:sync_stats)

      setup_stats = {
        "total_accounts" => total_count,
        "linked_accounts" => linked_count,
        "unlinked_accounts" => unlinked_count
      }

      merge_sync_stats(sync, setup_stats)
      setup_stats
    end

    def user_safe_error_message(error)
      if error.is_a?(Provider::Brex::BrexError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
        I18n.t("brex_items.syncer.credentials_invalid")
      else
        I18n.t("brex_items.syncer.failed")
      end
    end
end
