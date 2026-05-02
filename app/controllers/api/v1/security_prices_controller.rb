# frozen_string_literal: true

class Api::V1::SecurityPricesController < Api::V1::BaseController
  include Pagy::Backend

  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_security_price, only: :show

  def index
    security_prices_query = apply_filters(security_prices_scope).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @security_prices = pagy(
      security_prices_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  private

    def set_security_price
      raise ActiveRecord::RecordNotFound, "Security price not found" unless valid_uuid?(params[:id])

      @security_price = security_prices_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def security_prices_scope
      Security::Price
        .where(security_id: scoped_security_ids)
        .includes(:security)
    end

    def scoped_security_ids
      Security
        .where(id: holding_security_ids)
        .or(Security.where(id: trade_security_ids))
        .select(:id)
    end

    def holding_security_ids
      Holding.where(account_id: accessible_account_ids).select(:security_id)
    end

    def trade_security_ids
      Trade.joins(:entry).where(entries: { account_id: accessible_account_ids }).select(:security_id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.visible.accessible_by(current_resource_owner).select(:id)
    end

    def apply_filters(query)
      if params[:security_id].present?
        raise InvalidFilterError, "security_id must be a valid UUID" unless valid_uuid?(params[:security_id])

        query = query.where(security_id: params[:security_id])
      end

      query = query.where(currency: params[:currency].to_s.upcase) if params[:currency].present?
      query = query.where("security_prices.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("security_prices.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query = query.where(provisional: ActiveModel::Type::Boolean.new.cast(params[:provisional])) if params[:provisional].present?
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

    def render_validation_error(message)
      render json: {
        error: "validation_failed",
        message: message,
        errors: [ message ]
      }, status: :unprocessable_entity
    end
end
