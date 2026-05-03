# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  InvalidFilterError = Class.new(StandardError)

  before_action :ensure_read_scope
  before_action :set_transfer, only: :show

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
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

    def set_transfer
      @transfer = transfers_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
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
