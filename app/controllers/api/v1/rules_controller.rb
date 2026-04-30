# frozen_string_literal: true

class Api::V1::RulesController < Api::V1::BaseController
  include Pagy::Backend

  BOOLEAN_FILTERS = {
    "true" => true,
    "1" => true,
    "false" => false,
    "0" => false
  }.freeze

  before_action -> { authorize_scope!(:read) }
  before_action :set_rule, only: :show

  def index
    rules_query = current_resource_owner.family.rules
      .includes(:actions, conditions: :sub_conditions)
      .order(:created_at, :id)

    rules_query = rules_query.where(resource_type: params[:resource_type]) if params[:resource_type].present?
    if params[:active].present?
      active = parse_boolean_filter(params[:active])
      return if performed?

      rules_query = rules_query.where(active: active)
    end

    @pagy, @rules = pagy(
      rules_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index
  end

  def show
    render :show
  end

  private

    def set_rule
      @rule = current_resource_owner.family.rules
        .includes(:actions, conditions: :sub_conditions)
        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Rule not found" }, status: :not_found
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).include?(per_page) ? per_page : 25
    end

    def parse_boolean_filter(value)
      normalized = value.to_s.downcase
      return BOOLEAN_FILTERS[normalized] if BOOLEAN_FILTERS.key?(normalized)

      render json: {
        error: "validation_failed",
        message: "active must be one of: true, false, 1, 0"
      }, status: :unprocessable_entity
      nil
    end
end
