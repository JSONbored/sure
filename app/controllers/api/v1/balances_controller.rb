# frozen_string_literal: true

class Api::V1::BalancesController < Api::V1::BaseController
  include Pagy::Backend

  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_balance, only: :show

  def index
    balances_query = apply_filters(balances_scope).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @balances = pagy(
      balances_query,
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

    def set_balance
      @balance = balances_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def balances_scope
      Balance
        .joins(:account)
        .where(accounts: { id: accessible_account_ids })
        .includes(:account)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def apply_filters(query)
      if params[:account_id].present?
        raise InvalidFilterError, "account_id must be a valid UUID" unless valid_uuid?(params[:account_id])

        query = query.where(account_id: params[:account_id])
      end

      query = query.where(currency: params[:currency].to_s.upcase) if params[:currency].present?
      query = query.where("balances.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("balances.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
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
