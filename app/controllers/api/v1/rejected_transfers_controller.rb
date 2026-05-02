# frozen_string_literal: true

class Api::V1::RejectedTransfersController < Api::V1::BaseController
  include Pagy::Backend

  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_rejected_transfer, only: :show

  def index
    rejected_transfers_query = apply_filters(rejected_transfers_scope).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @rejected_transfers = pagy(
      rejected_transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue InvalidFilterError => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity
  end

  def show
    render :show
  end

  private

    def set_rejected_transfer
      @rejected_transfer = rejected_transfers_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def rejected_transfers_scope
      RejectedTransfer
        .where(
          inflow_transaction_id: accessible_transaction_ids,
          outflow_transaction_id: accessible_transaction_ids
        )
        .includes(
          inflow_transaction: { entry: :account },
          outflow_transaction: { entry: :account }
        )
    end

    def accessible_transaction_ids
      @accessible_transaction_ids ||= Transaction
        .joins(:entry)
        .where(entries: { account_id: accessible_account_ids })
        .select(:id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def apply_filters(query)
      if params[:account_id].present?
        raise InvalidFilterError, "account_id must be a valid UUID" unless valid_uuid?(params[:account_id])

        account_transaction_ids = accessible_transaction_ids_for_account(params[:account_id])
        query = query
          .where(inflow_transaction_id: account_transaction_ids)
          .or(query.where(outflow_transaction_id: account_transaction_ids))
      end

      if params[:start_date].present? || params[:end_date].present?
        date_transaction_ids = transfer_date_transaction_ids
        query = query
          .where(inflow_transaction_id: date_transaction_ids)
          .or(query.where(outflow_transaction_id: date_transaction_ids))
      end

      query
    end

    def accessible_transaction_ids_for_account(account_id)
      Transaction
        .joins(:entry)
        .where(entries: { account_id: account_id })
        .where(entries: { account_id: accessible_account_ids })
        .select(:id)
    end

    def transfer_date_transaction_ids
      query = Transaction
        .joins(:entry)
        .where(entries: { account_id: accessible_account_ids })

      query = query.where("entries.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("entries.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query.select(:id)
    end

    def parse_date_param(key)
      Date.iso8601(params[key].to_s)
    rescue ArgumentError
      raise InvalidFilterError, "#{key} must be an ISO 8601 date"
    end

    def valid_uuid?(value)
      value.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
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
