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
    render json: brex_account_flow.preload_payload
  end

  def select_accounts
    @accountable_type = params[:accountable_type] || "Depository"
    @return_to = safe_return_to_path
    result = brex_account_flow.select_accounts_result(accountable_type: @accountable_type)

    return handle_brex_selection_result(result, empty_path: new_account_path, api_return_path: @return_to) unless result.success?

    @brex_item = result.brex_item
    @available_accounts = result.available_accounts

    render layout: false
  end

  def link_accounts
    result = brex_account_flow.link_new_accounts_result(
      account_ids: params[:account_ids] || [],
      accountable_type: params[:accountable_type] || "Depository"
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
  end

  def select_existing_account
    return redirect_to accounts_path, alert: t(".no_account_specified") if params[:account_id].blank?

    @account = Current.family.accounts.find(params[:account_id])
    result = brex_account_flow.select_existing_account_result(account: @account)

    return handle_brex_selection_result(result, empty_path: accounts_path, api_return_path: accounts_path) unless result.success?

    @brex_item = result.brex_item
    @available_accounts = result.available_accounts
    @return_to = safe_return_to_path

    render layout: false
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id]) if params[:account_id].present?
    result = brex_account_flow.link_existing_account_result(
      account: account,
      brex_account_id: params[:brex_account_id]
    )

    redirect_with_navigation(result, return_to: safe_return_to_path)
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
    if BrexItem::AccountFlow.update_item_with_cache_expiration(@brex_item, family: Current.family, attributes: brex_item_params)
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
    @api_error = flow.import_accounts_error_message
    @brex_accounts = flow.unlinked_brex_accounts
    @account_type_options = flow.account_type_options
    @subtype_options = flow.subtype_options
  end

  def complete_account_setup
    flow = brex_account_flow_for_item
    result = flow.complete_setup_result(
      account_types: params[:account_types] || {},
      account_subtypes: params[:account_subtypes] || {}
    )

    unless result.success?
      redirect_to accounts_path, alert: result.message, status: :see_other
      return
    end

    flash[:notice] = result.message

    if turbo_frame_request?
      render_accounts_update_after_setup
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    def brex_account_flow
      @brex_account_flow ||= BrexItem::AccountFlow.new(family: Current.family, brex_item_id: params[:brex_item_id])
    end

    def brex_account_flow_for_item
      BrexItem::AccountFlow.new(family: Current.family, brex_item: @brex_item)
    end

    def render_provider_panel_success(message)
      return redirect_to accounts_path, notice: message, status: :see_other unless turbo_frame_request?

      flash.now[:notice] = message
      @brex_items = Current.family.brex_items.active.ordered.includes(:syncs, :brex_accounts)
      render_brex_provider_panel(locals: { brex_items: @brex_items }, include_flash: true)
    end

    def render_provider_panel_error
      @error_message = @brex_item.errors.full_messages.join(", ")
      return redirect_to settings_providers_path, alert: @error_message, status: :see_other unless turbo_frame_request?

      render_brex_provider_panel(locals: { error_message: @error_message }, status: :unprocessable_entity)
    end

    def render_brex_provider_panel(locals:, status: :ok, include_flash: false)
      streams = [
        turbo_stream.replace(
          "brex-providers-panel",
          partial: "settings/providers/brex_panel",
          locals: locals
        )
      ]
      streams += flash_notification_stream_items if include_flash
      render turbo_stream: streams, status: status
    end

    def render_accounts_update_after_setup
      @manual_accounts = Account.uncached { Current.family.accounts.visible_manual.order(:name).to_a }
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
      render partial: "brex_items/api_error", locals: { error_message: error_message, return_path: return_path }, layout: false
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

    def handle_brex_selection_result(result, empty_path:, api_return_path:)
      case result.status
      when :empty, :account_already_linked
        redirect_to empty_path, alert: result.message
      when :no_api_token, :select_connection
        redirect_to settings_providers_path, alert: result.message
      when :setup_required
        if turbo_frame_request?
          render partial: "brex_items/setup_required", layout: false
        else
          redirect_to settings_providers_path, alert: result.message
        end
      when :api_error, :unexpected_error
        render_api_error_partial(result.message, api_return_path)
      else
        redirect_to settings_providers_path, alert: result.message
      end
    end

    def redirect_with_navigation(result, return_to:)
      redirect_to navigation_path_for(result.target, return_to: return_to), result.flash_type => result.message
    end

    def navigation_path_for(target, return_to:)
      {
        new_account: new_account_path,
        settings_providers: settings_providers_path,
        return_to_or_accounts: return_to || accounts_path
      }.fetch(target, accounts_path)
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
