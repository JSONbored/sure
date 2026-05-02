# frozen_string_literal: true

class Api::V1::BudgetsController < Api::V1::BaseController
  include Pagy::Backend

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  private_constant :UUID_PATTERN

  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_budget, only: :show

  def index
    budgets_query = apply_filters(current_resource_owner.family.budgets.includes(budget_categories: :category))
      .order(start_date: :desc)
    @per_page = safe_per_page_param

    @pagy, @budgets = pagy(
      budgets_query,
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

    def set_budget
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @budget = current_resource_owner.family.budgets.includes(budget_categories: :category).find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def apply_filters(query)
      query = query.where("budgets.start_date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("budgets.end_date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end

    def parse_date_param(key)
      Date.iso8601(params[key].to_s)
    rescue ArgumentError
      raise InvalidFilterError, "#{key} must be an ISO 8601 date"
    end

    def valid_uuid?(value)
      value.to_s.match?(UUID_PATTERN)
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
