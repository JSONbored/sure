# frozen_string_literal: true

class Api::V1::SecuritiesController < Api::V1::BaseController
  include Pagy::Backend

  InvalidFilterError = Class.new(StandardError)
  BOOLEAN_FILTERS = {
    "true" => true,
    "1" => true,
    "false" => false,
    "0" => false
  }.freeze

  before_action :ensure_read_scope
  before_action :set_security, only: :show

  def index
    securities_query = apply_filters(securities_scope).order(:ticker, :exchange_operating_mic, :name)
    @per_page = safe_per_page_param

    @pagy, @securities = pagy(
      securities_query,
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

    def set_security
      raise ActiveRecord::RecordNotFound, "Security not found" unless valid_uuid?(params[:id])

      @security = securities_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def securities_scope
      Security
        .where(id: holding_security_ids)
        .or(Security.where(id: trade_security_ids))
        .distinct
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
      query = query.where("securities.ticker ILIKE ?", params[:ticker].to_s.strip) if params[:ticker].present?
      query = query.where(exchange_operating_mic: params[:exchange_operating_mic].to_s.upcase) if params[:exchange_operating_mic].present?
      if params[:kind].present?
        raise InvalidFilterError, "kind must be one of: #{Security::KINDS.join(', ')}" unless Security::KINDS.include?(params[:kind])

        query = query.where(kind: params[:kind])
      end
      if params.key?(:offline)
        offline = parse_boolean_filter_param(:offline)
        query = query.where(offline: offline) unless offline.nil?
      end
      query
    end

    def parse_boolean_filter_param(key)
      normalized_value = params[key].to_s.strip.downcase

      raise InvalidFilterError, "#{key} must be true or false" if normalized_value.blank?
      return BOOLEAN_FILTERS.fetch(normalized_value) if BOOLEAN_FILTERS.key?(normalized_value)

      raise InvalidFilterError, "#{key} must be true or false"
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

      return 25 if per_page < 1

      [ per_page, 100 ].min
    end

    def render_validation_error(message)
      render json: {
        error: "validation_failed",
        message: message,
        errors: [ message ]
      }, status: :unprocessable_entity
    end
end
