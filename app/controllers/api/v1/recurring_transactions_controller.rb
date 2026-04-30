# frozen_string_literal: true

class Api::V1::RecurringTransactionsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create update destroy]
  before_action :set_recurring_transaction, only: %i[show update destroy]

  def index
    recurring_transactions_query = current_resource_owner.family.recurring_transactions
      .accessible_by(current_resource_owner)
      .includes(:account, :merchant)
      .order(status: :asc, next_expected_date: :asc)

    recurring_transactions_query = apply_filters(recurring_transactions_query)

    @pagy, @recurring_transactions = pagy(
      recurring_transactions_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )
    @per_page = safe_per_page_param

    render :index
  rescue => e
    Rails.logger.error "RecurringTransactionsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "RecurringTransactionsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def create
    @recurring_transaction = current_resource_owner.family.recurring_transactions.new(
      recurring_transaction_attributes(default_manual: true)
    )

    if @recurring_transaction.save
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Recurring transaction could not be created",
        errors: @recurring_transaction.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound => e
    render json: {
      error: "not_found",
      message: e.message
    }, status: :not_found
  rescue => e
    Rails.logger.error "RecurringTransactionsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def update
    if @recurring_transaction.update(recurring_transaction_attributes)
      render :show
    else
      render json: {
        error: "validation_failed",
        message: "Recurring transaction could not be updated",
        errors: @recurring_transaction.errors.full_messages
      }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound => e
    render json: {
      error: "not_found",
      message: e.message
    }, status: :not_found
  rescue => e
    Rails.logger.error "RecurringTransactionsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def destroy
    @recurring_transaction.destroy!

    render json: { message: "Recurring transaction deleted successfully" }, status: :ok
  rescue => e
    Rails.logger.error "RecurringTransactionsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private
    def set_recurring_transaction
      @recurring_transaction = current_resource_owner.family.recurring_transactions
        .accessible_by(current_resource_owner)
        .includes(:account, :merchant)
        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Recurring transaction not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def apply_filters(query)
      query = query.where(status: params[:status]) if params[:status].present?
      query = query.where(account_id: params[:account_id]) if params[:account_id].present?
      query
    end

    def recurring_transaction_attributes(default_manual: false)
      attrs = recurring_transaction_params.to_h.symbolize_keys
      attrs[:manual] = true if default_manual && !attrs.key?(:manual)
      input = params.require(:recurring_transaction)

      attrs[:account] = writable_account(input[:account_id]) if input.key?(:account_id)
      attrs[:merchant] = family_merchant(input[:merchant_id]) if input.key?(:merchant_id)

      attrs
    end

    def writable_account(account_id)
      return nil if account_id.blank?

      current_resource_owner.family.accounts.writable_by(current_resource_owner).find(account_id)
    end

    def family_merchant(merchant_id)
      return nil if merchant_id.blank?

      current_resource_owner.family.merchants.find(merchant_id)
    end

    def recurring_transaction_params
      params.require(:recurring_transaction).permit(
        :name,
        :amount,
        :currency,
        :expected_day_of_month,
        :last_occurrence_date,
        :next_expected_date,
        :status,
        :occurrence_count,
        :manual,
        :expected_amount_min,
        :expected_amount_max,
        :expected_amount_avg
      )
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).include?(per_page) ? per_page : 25
    end
end
