class BrexItemsController < ApplicationController
  before_action :set_brex_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @brex_items = Current.family.brex_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def preload_accounts
    flow = brex_account_flow
    unless flow.selected?
      render json: brex_item_selection_error_payload(flow)
      return
    end

    render json: flow.preload_payload
  rescue BrexItem::AccountFlow::NoApiTokenError
    render json: { success: false, error: "no_api_token", has_accounts: false }
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex preload error: #{e.message}")
    render json: { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
  rescue StandardError => e
    Rails.logger.error("Unexpected error preloading Brex accounts: #{e.class}: #{e.message}")
    render json: { success: false, error: "unexpected_error", error_message: t("brex_items.errors.unexpected_error"), has_accounts: nil }
  end

  def select_accounts
    flow = brex_account_flow
    unless flow.selected?
      render_brex_item_selection_failure(flow)
      return
    end

    @brex_item = flow.brex_item
    @accountable_type = params[:accountable_type] || "Depository"
    @available_accounts = flow.available_accounts(accountable_type: @accountable_type)
    @return_to = safe_return_to_path

    if @available_accounts.empty?
      redirect_to new_account_path, alert: t(".no_accounts_found")
      return
    end

    render layout: false
  rescue BrexItem::AccountFlow::NoApiTokenError
    redirect_to settings_providers_path, alert: t(".no_api_token")
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex API error in select_accounts: #{e.message}")
    render_api_error_partial(e.message, safe_return_to_path)
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
    render_api_error_partial(t(".unexpected_error"), safe_return_to_path)
  end

  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    flow = brex_account_flow
    unless flow.selected?
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    result = flow.link_new_accounts!(
      account_ids: selected_account_ids,
      accountable_type: accountable_type
    )

    redirect_after_link_accounts(result, return_to: return_to)
  rescue BrexItem::AccountFlow::NoApiTokenError
    redirect_to new_account_path, alert: t(".no_api_token")
  rescue Provider::Brex::BrexError => e
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  def select_existing_account
    account_id = params[:account_id]

    unless account_id.present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(account_id)

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    flow = brex_account_flow
    unless flow.selected?
      render_brex_item_selection_failure(flow)
      return
    end

    @brex_item = flow.brex_item
    @available_accounts = flow.available_accounts_for_existing(account: @account)

    if @available_accounts.empty?
      redirect_to accounts_path, alert: t(".all_accounts_already_linked")
      return
    end

    @return_to = safe_return_to_path
    render layout: false
  rescue BrexItem::AccountFlow::NoApiTokenError
    redirect_to settings_providers_path, alert: t(".no_api_token")
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex API error in select_existing_account: #{e.message}")
    render_api_error_partial(e.message, accounts_path)
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
    render_api_error_partial(t(".unexpected_error"), accounts_path)
  end

  def link_existing_account
    account_id = params[:account_id]
    brex_account_id = params[:brex_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && brex_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    @account = Current.family.accounts.find(account_id)

    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    flow = brex_account_flow
    unless flow.selected?
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    flow.link_existing_account!(account: @account, brex_account_id: brex_account_id)

    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
  rescue BrexItem::AccountFlow::NoApiTokenError
    redirect_to accounts_path, alert: t(".no_api_token")
  rescue BrexItem::AccountFlow::AccountNotFoundError
    redirect_to accounts_path, alert: t(".brex_account_not_found")
  rescue BrexItem::AccountFlow::InvalidAccountNameError
    redirect_to accounts_path, alert: t(".invalid_account_name")
  rescue BrexItem::AccountFlow::AccountAlreadyLinkedError
    redirect_to accounts_path, alert: t(".brex_account_already_linked")
  rescue Provider::Brex::BrexError => e
    redirect_to accounts_path, alert: t(".api_error", message: e.message)
  end

  def new
    @brex_item = Current.family.brex_items.build
  end

  def create
    @brex_item = Current.family.brex_items.build(brex_item_params)
    @brex_item.name ||= "Brex Connection"

    if @brex_item.save
      @brex_item.sync_later
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def edit
  end

  def update
    permitted_params = brex_item_params
    expire_accounts_cache = BrexItem::AccountFlow.cache_sensitive_update?(permitted_params)

    if @brex_item.update(permitted_params)
      Rails.cache.delete(BrexItem::AccountFlow.cache_key(Current.family, @brex_item)) if expire_accounts_cache
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def destroy
    safely_unlink_brex_item
    @brex_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @brex_item.sync_later unless @brex_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    flow = brex_account_flow_for_item
    @api_error = import_accounts_for_setup(flow)
    @brex_accounts = flow.unlinked_brex_accounts
    @account_type_options = flow.account_type_options
    @subtype_options = flow.subtype_options
  end

  def complete_account_setup
    flow = brex_account_flow_for_item
    result = flow.complete_setup!(
      account_types: params[:account_types] || {},
      account_subtypes: params[:account_subtypes] || {}
    )

    flash[:notice] = account_setup_notice(result)

    if turbo_frame_request?
      render_accounts_update_after_setup
    else
      redirect_to accounts_path, status: :see_other
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error("Brex account setup failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    redirect_to accounts_path, alert: t(".creation_failed", error: e.message), status: :see_other
  rescue StandardError => e
    Rails.logger.error("Brex account setup failed unexpectedly: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    redirect_to accounts_path, alert: t(".creation_failed", error: t(".unexpected_error")), status: :see_other
  end

  private

    def brex_account_flow
      @brex_account_flow ||= BrexItem::AccountFlow.new(
        family: Current.family,
        brex_item_id: params[:brex_item_id]
      )
    end

    def brex_account_flow_for_item
      BrexItem::AccountFlow.new(family: Current.family, brex_item: @brex_item)
    end

    def render_provider_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @brex_items = Current.family.brex_items.active.ordered.includes(:syncs, :brex_accounts)
        render turbo_stream: [
          turbo_stream.replace(
            "brex-providers-panel",
            partial: "settings/providers/brex_panel",
            locals: { brex_items: @brex_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to accounts_path, notice: message, status: :see_other
      end
    end

    def render_provider_panel_error
      @error_message = @brex_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "brex-providers-panel",
          partial: "settings/providers/brex_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :see_other
      end
    end

    def redirect_after_link_accounts(result, return_to:)
      if result.invalid_count.positive? && result.created_count.zero? && result.already_linked_count.zero?
        redirect_to new_account_path, alert: t(".invalid_account_names", count: result.invalid_count)
      elsif result.invalid_count.positive? && (result.created_count.positive? || result.already_linked_count.positive?)
        redirect_to return_to || accounts_path,
                    alert: t(".partial_invalid",
                             created_count: result.created_count,
                             already_linked_count: result.already_linked_count,
                             invalid_count: result.invalid_count)
      elsif result.created_count.positive? && result.already_linked_count.positive?
        redirect_to return_to || accounts_path,
                    notice: t(".partial_success",
                              created_count: result.created_count,
                              already_linked_count: result.already_linked_count,
                              already_linked_names: result.already_linked_names.join(", "))
      elsif result.created_count.positive?
        redirect_to return_to || accounts_path,
                    notice: t(".success", count: result.created_count)
      elsif result.already_linked_count.positive?
        redirect_to return_to || accounts_path,
                    alert: t(".all_already_linked",
                             count: result.already_linked_count,
                             names: result.already_linked_names.join(", "))
      else
        redirect_to new_account_path, alert: t(".link_failed")
      end
    end

    def import_accounts_for_setup(flow)
      flow.import_accounts_from_api_if_needed
    rescue BrexItem::AccountFlow::NoApiTokenError
      t("brex_items.setup_accounts.no_api_token")
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex API error: #{e.message}")
      t("brex_items.setup_accounts.api_error", message: e.message)
    rescue StandardError => e
      Rails.logger.error("Unexpected error fetching Brex accounts: #{e.class}: #{e.message}")
      t("brex_items.setup_accounts.api_error", message: t("brex_items.errors.unexpected_error"))
    end

    def account_setup_notice(result)
      if result.created_count.positive?
        t(".success", count: result.created_count)
      elsif result.skipped_count.positive?
        t(".all_skipped")
      else
        t(".no_accounts")
      end
    end

    def render_accounts_update_after_setup
      @manual_accounts = Account.uncached {
        Current.family.accounts
          .visible_manual
          .order(:name)
          .to_a
      }
      @brex_items = Current.family.brex_items.ordered

      manual_accounts_stream = if @manual_accounts.any?
        turbo_stream.update(
          "manual-accounts",
          partial: "accounts/index/manual_accounts",
          locals: { accounts: @manual_accounts }
        )
      else
        turbo_stream.replace("manual-accounts", view_context.tag.div(id: "manual-accounts"))
      end

      render turbo_stream: [
        manual_accounts_stream,
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@brex_item),
          partial: "brex_items/brex_item",
          locals: { brex_item: @brex_item }
        )
      ] + Array(flash_notification_stream_items)
    end

    def render_api_error_partial(error_message, return_path)
      render partial: "brex_items/api_error",
             locals: { error_message: error_message, return_path: return_path },
             layout: false
    end

    def safely_unlink_brex_item
      @brex_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Brex unlink during destroy failed: #{e.class} - #{e.message}")
    end

    def set_brex_item
      @brex_item = Current.family.brex_items.find(params[:id])
    end

    def brex_item_params
      permitted = params.require(:brex_item).permit(:name, :sync_start_date, :token, :base_url)
      permitted.delete(:token) if @brex_item&.persisted? && permitted[:token].blank?
      permitted[:token] = permitted[:token].to_s.strip if permitted[:token].present?
      if permitted.key?(:base_url)
        permitted[:base_url] = permitted[:base_url].to_s.strip
        permitted[:base_url] = nil if permitted[:base_url].blank?
      end
      permitted
    end

    def brex_item_selection_error_payload(flow)
      if flow.selection_required?
        {
          success: false,
          error: "select_connection",
          error_message: t(".select_connection", default: "Choose a Brex connection before loading accounts."),
          has_accounts: nil
        }
      else
        { success: false, error: "no_credentials", has_accounts: false }
      end
    end

    def render_brex_item_selection_failure(flow)
      if flow.selection_required?
        redirect_to settings_providers_path,
                    alert: t(".select_connection", default: "Choose a Brex connection in Provider Settings.")
      elsif turbo_frame_request?
        render partial: "brex_items/setup_required", layout: false
      else
        redirect_to settings_providers_path,
                    alert: t(".no_credentials_configured",
                             default: "Please configure your Brex API token first in Provider Settings.")
      end
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s
      uri = URI.parse(return_to)

      return nil if uri.scheme.present? || uri.host.present?
      return nil if return_to.start_with?("//")
      return nil unless return_to.start_with?("/")

      return_to
    rescue URI::InvalidURIError
      nil
    end
end
