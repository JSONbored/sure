# frozen_string_literal: true

class Api::V1::SyncsController < Api::V1::BaseController
  include Pagy::Backend

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  private_constant :UUID_PATTERN

  SYNCABLE_ASSOCIATIONS = {
    "Account" => :accounts,
    "PlaidItem" => :plaid_items,
    "SimplefinItem" => :simplefin_items,
    "LunchflowItem" => :lunchflow_items,
    "EnableBankingItem" => :enable_banking_items,
    "CoinbaseItem" => :coinbase_items,
    "BinanceItem" => :binance_items,
    "CoinstatsItem" => :coinstats_items,
    "SnaptradeItem" => :snaptrade_items,
    "MercuryItem" => :mercury_items,
    "SophtronItem" => :sophtron_items,
    "IndexaCapitalItem" => :indexa_capital_items
  }.freeze

  before_action :ensure_read_scope
  before_action :set_sync, only: [ :show ]

  helper_method :sync_error_payload

  def index
    @per_page = safe_per_page_param
    @pagy, @syncs = pagy(
      family_syncs_query.preload(:syncable, :children).ordered,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def latest
    @sync = family_syncs_query.preload(:syncable, :children).ordered.first
    render :show
  end

  def show
    render :show
  end

  private

    def set_sync
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @sync = family_syncs_query.preload(:syncable, :children).find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def family_syncs_query
      family = current_resource_owner.family
      query = Sync.where(syncable_type: "Family", syncable_id: family.id)

      SYNCABLE_ASSOCIATIONS.each do |syncable_type, association_name|
        ids = syncable_ids_for(family, syncable_type, association_name)
        query = query.or(Sync.where(syncable_type: syncable_type, syncable_id: ids))
      end

      query
    end

    def syncable_ids_for(family, syncable_type, association_name)
      return current_resource_owner.accessible_accounts.select(:id) if syncable_type == "Account"

      family.public_send(association_name).select(:id)
    end

    def valid_uuid?(value)
      value.to_s.match?(UUID_PATTERN)
    end

    def sync_error_payload(sync)
      return unless sync.failed? || sync.stale?

      {
        present: sync.error.present?,
        message: sync.stale? ? "Sync became stale before completion" : "Sync failed"
      }
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i

      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
