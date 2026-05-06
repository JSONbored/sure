class BrexItems::AccountSetupsController < ApplicationController
  before_action :set_brex_item
  before_action :require_admin!

  def setup_accounts
    flow = brex_account_flow
    @api_error = flow.import_accounts_error_message
    @brex_accounts = flow.unlinked_brex_accounts
    @account_type_options = flow.account_type_options
    @subtype_options = flow.subtype_options

    render "brex_items/setup_accounts"
  end

  def complete_account_setup
    result = brex_account_flow.complete_setup_result(
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

    def set_brex_item
      @brex_item = Current.family.brex_items.find(params[:id])
    end

    def brex_account_flow
      @brex_account_flow ||= BrexItem::AccountFlow.new(family: Current.family, brex_item: @brex_item)
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
end
