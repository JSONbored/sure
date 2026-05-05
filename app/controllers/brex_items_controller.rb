class BrexItemsController < ApplicationController
  before_action :set_brex_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :preload_accounts, :select_accounts, :link_accounts, :select_existing_account, :link_existing_account, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @brex_items = Current.family.brex_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  # Preload Brex accounts in background (async, non-blocking)
  def preload_accounts
    begin
      account_flow = brex_item_account_flow_context
      brex_item = account_flow[:brex_item]
      unless brex_item
        render json: brex_item_selection_error_payload(account_flow[:credentialed_items])
        return
      end

      unless brex_item.credentials_configured?
        render json: { success: false, error: "no_credentials", has_accounts: false }
        return
      end

      cache_key = brex_accounts_cache_key(brex_item)

      # Check if already cached
      cached_accounts = Rails.cache.read(cache_key)

      if cached_accounts.present?
        render json: { success: true, has_accounts: cached_accounts.any?, cached: true }
        return
      end

      brex_provider = brex_item.brex_provider

      unless brex_provider.present?
        render json: { success: false, error: "no_api_token", has_accounts: false }
        return
      end

      accounts_data = brex_provider.get_accounts
      available_accounts = accounts_data[:accounts] || []

      # Cache the accounts for 5 minutes
      Rails.cache.write(cache_key, available_accounts, expires_in: 5.minutes)

      render json: { success: true, has_accounts: available_accounts.any?, cached: false }
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex preload error: #{e.message}")
      # API error (bad token, network issue, etc) - keep button visible, show error when clicked
      render json: { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
    rescue StandardError => e
      Rails.logger.error("Unexpected error preloading Brex accounts: #{e.class}: #{e.message}")
      # Unexpected error - keep button visible, show error when clicked
      render json: { success: false, error: "unexpected_error", error_message: e.message, has_accounts: nil }
    end
  end

  # Fetch available accounts from Brex API and show selection UI
  def select_accounts
    begin
      account_flow = brex_item_account_flow_context
      @brex_item = account_flow[:brex_item]
      unless @brex_item
        render_brex_item_selection_failure(credentialed_items: account_flow[:credentialed_items])
        return
      end

      cache_key = brex_accounts_cache_key(@brex_item)

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        brex_provider = @brex_item.brex_provider

        unless brex_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_token",
                                                        default: "Brex API token not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = brex_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      linked_account_ids = @brex_item.brex_accounts.joins(:account_provider).pluck(:account_id)
      @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }

      @accountable_type = params[:accountable_type] || "Depository"
      @available_accounts = filtered_available_accounts(@available_accounts, @accountable_type)
      @return_to = safe_return_to_path

      if @available_accounts.empty?
        redirect_to new_account_path, alert: t(".no_accounts_found")
        return
      end

      render layout: false
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex API error in select_accounts: #{e.message}")
      @error_message = e.message
      @return_path = safe_return_to_path
      render partial: "brex_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
      @error_message = t(".unexpected_error")
      @return_path = safe_return_to_path
      render partial: "brex_items/api_error",
             locals: { error_message: @error_message, return_path: @return_path },
             layout: false
    end
  end

  # Create accounts from selected Brex accounts
  def link_accounts
    selected_account_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"
    return_to = safe_return_to_path

    if selected_account_ids.empty?
      redirect_to new_account_path, alert: t(".no_accounts_selected")
      return
    end

    account_flow = brex_item_account_flow_context
    brex_item = account_flow[:brex_item]

    unless brex_item
      redirect_to settings_providers_path, alert: t(".select_connection", default: "Choose a Brex connection before linking accounts.")
      return
    end

    # Fetch account details from API
    brex_provider = brex_item.brex_provider
    unless brex_provider.present?
      redirect_to new_account_path, alert: t(".no_api_token")
      return
    end

    accounts_data = brex_provider.get_accounts

    created_accounts = []
    already_linked_accounts = []
    invalid_accounts = []

    selected_account_ids.each do |account_id|
      # Find the account data from API response
      account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == account_id.to_s }
      next unless account_data

      account_name = brex_account_name(account_data)

      # Validate account name is not blank (required by Account model)
      if account_name.blank?
        invalid_accounts << account_id
        Rails.logger.warn "BrexItemsController - Skipping account #{account_id} with blank name"
        next
      end

      # Create or find brex_account
      brex_account = brex_item.brex_accounts.find_or_initialize_by(
        account_id: account_id.to_s
      )
      brex_account.upsert_brex_snapshot!(account_data)
      brex_account.save!

      # Check if this brex_account is already linked
      if brex_account.account_provider.present?
        already_linked_accounts << account_name
        next
      end

      # Create the internal Account with proper balance initialization
      account = Account.create_and_sync(
        {
          family: Current.family,
          name: account_name,
          balance: 0, # Initial balance will be set during sync
          currency: brex_account_currency(account_data),
          accountable_type: accountable_type,
          accountable_attributes: default_accountable_attributes(accountable_type)
        },
        skip_initial_sync: true
      )

      # Link account to brex_account via account_providers join table
      AccountProvider.create!(
        account: account,
        provider: brex_account
      )

      created_accounts << account
    end

    # Trigger sync to fetch transactions if any accounts were created
    brex_item.sync_later if created_accounts.any?

    # Build appropriate flash message
    if invalid_accounts.any? && created_accounts.empty? && already_linked_accounts.empty?
      # All selected accounts were invalid (blank names)
      redirect_to new_account_path, alert: t(".invalid_account_names", count: invalid_accounts.count)
    elsif invalid_accounts.any? && (created_accounts.any? || already_linked_accounts.any?)
      # Some accounts were created/already linked, but some had invalid names
      redirect_to return_to || accounts_path,
                  alert: t(".partial_invalid",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           invalid_count: invalid_accounts.count)
    elsif created_accounts.any? && already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".partial_success",
                           created_count: created_accounts.count,
                           already_linked_count: already_linked_accounts.count,
                           already_linked_names: already_linked_accounts.join(", "))
    elsif created_accounts.any?
      redirect_to return_to || accounts_path,
                  notice: t(".success", count: created_accounts.count)
    elsif already_linked_accounts.any?
      redirect_to return_to || accounts_path,
                  alert: t(".all_already_linked",
                          count: already_linked_accounts.count,
                          names: already_linked_accounts.join(", "))
    else
      redirect_to new_account_path, alert: t(".link_failed")
    end
  rescue Provider::Brex::BrexError => e
    redirect_to new_account_path, alert: t(".api_error", message: e.message)
  end

  # Fetch available Brex accounts to link with an existing account
  def select_existing_account
    account_id = params[:account_id]

    unless account_id.present?
      redirect_to accounts_path, alert: t(".no_account_specified")
      return
    end

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    account_flow = brex_item_account_flow_context
    @brex_item = account_flow[:brex_item]
    unless @brex_item
      render_brex_item_selection_failure(credentialed_items: account_flow[:credentialed_items])
      return
    end

    begin
      cache_key = brex_accounts_cache_key(@brex_item)

      # Try to get cached accounts first
      @available_accounts = Rails.cache.read(cache_key)

      # If not cached, fetch from API
      if @available_accounts.nil?
        brex_provider = @brex_item.brex_provider

        unless brex_provider.present?
          redirect_to settings_providers_path, alert: t(".no_api_token",
                                                        default: "Brex API token not found. Please configure it in Provider Settings.")
          return
        end

        accounts_data = brex_provider.get_accounts

        @available_accounts = accounts_data[:accounts] || []

        # Cache the accounts for 5 minutes
        Rails.cache.write(cache_key, @available_accounts, expires_in: 5.minutes)
      end

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".no_accounts_found")
        return
      end

      linked_account_ids = @brex_item.brex_accounts.joins(:account_provider).pluck(:account_id)
      @available_accounts = @available_accounts.reject { |acc| linked_account_ids.include?(acc[:id].to_s) }
      @available_accounts = filtered_available_accounts(@available_accounts, @account.accountable_type)

      if @available_accounts.empty?
        redirect_to accounts_path, alert: t(".all_accounts_already_linked")
        return
      end

      @return_to = safe_return_to_path

      render layout: false
    rescue Provider::Brex::BrexError => e
      Rails.logger.error("Brex API error in select_existing_account: #{e.message}")
      @error_message = e.message
      render partial: "brex_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    rescue StandardError => e
      Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
      @error_message = t(".unexpected_error")
      render partial: "brex_items/api_error",
             locals: { error_message: @error_message, return_path: accounts_path },
             layout: false
    end
  end

  # Link a selected Brex account to an existing account
  def link_existing_account
    account_id = params[:account_id]
    brex_account_id = params[:brex_account_id]
    return_to = safe_return_to_path

    unless account_id.present? && brex_account_id.present?
      redirect_to accounts_path, alert: t(".missing_parameters")
      return
    end

    account_flow = brex_item_account_flow_context
    brex_item = account_flow[:brex_item]

    @account = Current.family.accounts.find(account_id)

    # Check if account is already linked
    if @account.account_providers.exists?
      redirect_to accounts_path, alert: t(".account_already_linked")
      return
    end

    unless brex_item
      redirect_to settings_providers_path, alert: t(".select_connection", default: "Choose a Brex connection before linking accounts.")
      return
    end

    # Fetch account details from API
    brex_provider = brex_item.brex_provider
    unless brex_provider.present?
      redirect_to accounts_path, alert: t(".no_api_token")
      return
    end

    accounts_data = brex_provider.get_accounts

    # Find the selected Brex account data
    account_data = accounts_data[:accounts].find { |acc| acc[:id].to_s == brex_account_id.to_s }
    unless account_data
      redirect_to accounts_path, alert: t(".brex_account_not_found")
      return
    end

    account_name = brex_account_name(account_data)

    # Validate account name is not blank (required by Account model)
    if account_name.blank?
      redirect_to accounts_path, alert: t(".invalid_account_name")
      return
    end

    # Create or find brex_account
    brex_account = brex_item.brex_accounts.find_or_initialize_by(
      account_id: brex_account_id.to_s
    )
    brex_account.upsert_brex_snapshot!(account_data)
    brex_account.save!

    # Check if this brex_account is already linked to another account
    if brex_account.account_provider.present?
      redirect_to accounts_path, alert: t(".brex_account_already_linked")
      return
    end

    # Link account to brex_account via account_providers join table
    AccountProvider.create!(
      account: @account,
      provider: brex_account
    )

    # Trigger sync to fetch transactions
    brex_item.sync_later

    redirect_to return_to || accounts_path,
                notice: t(".success", account_name: @account.name)
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
      # Trigger initial sync to fetch accounts
      @brex_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
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
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @brex_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "brex-providers-panel",
          partial: "settings/providers/brex_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
  end

  def update
    permitted_params = brex_item_params
    expire_accounts_cache = brex_accounts_cache_sensitive_update?(permitted_params)

    if @brex_item.update(permitted_params)
      Rails.cache.delete(brex_accounts_cache_key(@brex_item)) if expire_accounts_cache

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
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
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @brex_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "brex-providers-panel",
          partial: "settings/providers/brex_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @brex_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("Brex unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @brex_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    unless @brex_item.syncing?
      @brex_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show unlinked Brex accounts for setup
  def setup_accounts
    # First, ensure we have the latest accounts from the API
    @api_error = fetch_brex_accounts_from_api

    # Get Brex accounts that are not linked (no AccountProvider)
    @brex_accounts = @brex_item.brex_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    # Get supported account types from the adapter
    supported_types = Provider::BrexAdapter.supported_account_types

    # Map of account type keys to their internal values
    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    # Build account type options using i18n, filtering to supported types
    all_account_type_options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)
      [ t(".account_types.#{key}"), type ]
    end

    # Add "Skip" option at the beginning
    @account_type_options = [ [ t(".account_types.skip"), "skip" ] ] + all_account_type_options

    # Helper to translate subtype options
    translate_subtypes = ->(type_key, subtypes_hash) {
      subtypes_hash.map { |k, v| [ t(".subtypes.#{type_key}.#{k}", default: v[:long] || k.humanize), k ] }
    }

    # Subtype options for each account type (only include supported types)
    all_subtype_options = {
      "Depository" => {
        label: t(".subtype_labels.depository"),
        options: translate_subtypes.call("depository", Depository::SUBTYPES)
      },
      "CreditCard" => {
        label: t(".subtype_labels.credit_card"),
        options: [],
        message: t(".subtype_messages.credit_card")
      },
      "Investment" => {
        label: t(".subtype_labels.investment"),
        options: translate_subtypes.call("investment", Investment::SUBTYPES)
      },
      "Loan" => {
        label: t(".subtype_labels.loan"),
        options: translate_subtypes.call("loan", Loan::SUBTYPES)
      },
      "OtherAsset" => {
        label: t(".subtype_labels.other_asset").presence,
        options: [],
        message: t(".subtype_messages.other_asset")
      }
    }

    @subtype_options = all_subtype_options.slice(*supported_types)
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    # Valid account types for this provider
    valid_types = Provider::BrexAdapter.supported_account_types

    created_accounts = []
    skipped_count = 0

    begin
      ActiveRecord::Base.transaction do
        account_types.each do |brex_account_id, selected_type|
          # Skip accounts marked as "skip"
          if selected_type == "skip" || selected_type.blank?
            skipped_count += 1
            next
          end

          # Validate account type is supported
          unless valid_types.include?(selected_type)
            Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Brex account #{brex_account_id}")
            next
          end

          # Find account - scoped to this item to prevent cross-item manipulation
          brex_account = @brex_item.brex_accounts.find_by(id: brex_account_id)
          unless brex_account
            Rails.logger.warn("Brex account #{brex_account_id} not found for item #{@brex_item.id}")
            next
          end

          # Skip if already linked (race condition protection)
          if brex_account.account_provider.present?
            Rails.logger.info("Brex account #{brex_account_id} already linked, skipping")
            next
          end

          selected_subtype = account_subtypes[brex_account_id]
          selected_type = default_account_type_for_brex_account(brex_account) if selected_type == "skip" || selected_type.blank?

          # Default subtype for CreditCard since it only has one option
          selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?
          selected_subtype = "checking" if selected_type == "Depository" && selected_subtype.blank?

          # Create account with user-selected type and subtype (raises on failure)
          # Skip initial sync - provider sync will handle balance creation with correct currency
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: brex_account.name,
              balance: brex_account.current_balance || 0,
              currency: brex_account.currency.presence || Current.family.currency,
              accountable_type: selected_type,
              accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
            },
            skip_initial_sync: true
          )

          # Link account to brex_account via account_providers join table (raises on failure)
          AccountProvider.create!(
            account: account,
            provider: brex_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("Brex account setup failed: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: e.message)
      redirect_to accounts_path, status: :see_other
      return
    rescue StandardError => e
      Rails.logger.error("Brex account setup failed unexpectedly: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))
      flash[:alert] = t(".creation_failed", error: t(".unexpected_error"))
      redirect_to accounts_path, status: :see_other
      return
    end

    # Trigger a sync to process transactions
    @brex_item.sync_later if created_accounts.any?

    # Set appropriate flash message
    if created_accounts.any?
      flash[:notice] = t(".success", count: created_accounts.count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped")
    else
      flash[:notice] = t(".no_accounts")
    end

    if turbo_frame_request?
      # Recompute data needed by Accounts#index partials
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
    else
      redirect_to accounts_path, status: :see_other
    end
  end

  private

    # Fetch Brex accounts from the API and store them locally
    # Returns nil on success, or an error message string on failure
    def fetch_brex_accounts_from_api
      # Skip if we already have accounts cached
      return nil unless @brex_item.brex_accounts.empty?

      # Validate API token is configured
      unless @brex_item.credentials_configured?
        return t("brex_items.setup_accounts.no_api_token")
      end

      # Use the specific brex_item's provider (scoped to this family's item)
      brex_provider = @brex_item.brex_provider
      unless brex_provider.present?
        return t("brex_items.setup_accounts.no_api_token")
      end

      begin
        accounts_data = brex_provider.get_accounts
        available_accounts = accounts_data[:accounts] || []

        if available_accounts.empty?
          Rails.logger.info("Brex API returned no accounts for item #{@brex_item.id}")
          return nil
        end

        available_accounts.each do |account_data|
          account_name = brex_account_name(account_data)
          next if account_name.blank?

          brex_account = @brex_item.brex_accounts.find_or_initialize_by(
            account_id: account_data[:id].to_s
          )
          brex_account.upsert_brex_snapshot!(account_data)
          brex_account.save!
        end

        nil # Success
      rescue Provider::Brex::BrexError => e
        Rails.logger.error("Brex API error: #{e.message}")
        t("brex_items.setup_accounts.api_error", message: e.message)
      rescue StandardError => e
        Rails.logger.error("Unexpected error fetching Brex accounts: #{e.class}: #{e.message}")
        t("brex_items.setup_accounts.api_error", message: e.message)
      end
    end

    def filtered_available_accounts(accounts, accountable_type)
      accounts.select do |account|
        case accountable_type
        when "CreditCard"
          brex_account_kind(account) == "card"
        when "Depository"
          brex_account_kind(account) == "cash"
        else
          Provider::BrexAdapter.supported_account_types.include?(accountable_type)
        end
      end
    end

    def brex_account_name(account_data)
      data = account_data.with_indifferent_access
      return data[:name].presence || "Brex Card" if brex_account_kind(data) == "card"

      data[:name].presence || data[:display_name].presence || "Brex Cash #{data[:id]}"
    end

    def brex_account_kind(account_data)
      return account_data.account_kind if account_data.respond_to?(:account_kind)

      data = account_data.with_indifferent_access
      kind = data[:account_kind].presence || data[:kind].presence || "cash"
      kind.to_s == "credit_card" ? "card" : kind.to_s
    end

    def brex_account_currency(account_data)
      data = account_data.with_indifferent_access
      BrexAccount.currency_code_from_money(data[:current_balance] || data[:available_balance] || data[:account_limit])
    end

    def default_account_type_for_brex_account(brex_account)
      brex_account_kind(brex_account) == "card" ? "CreditCard" : "Depository"
    end

    def default_accountable_attributes(accountable_type)
      case accountable_type
      when "CreditCard"
        { subtype: "credit_card" }
      when "Depository"
        { subtype: "checking" }
      else
        {}
      end
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

    def brex_items_with_credentials
      Current.family.brex_items.active.ordered.select(&:credentials_configured?)
    end

    def brex_item_account_flow_context
      credentialed_items = brex_items_with_credentials
      brex_item = nil

      if params[:brex_item_id].present?
        brex_item = credentialed_items.find { |item| item.id.to_s == params[:brex_item_id].to_s }
      elsif credentialed_items.one?
        brex_item = credentialed_items.first
      end

      {
        brex_item: brex_item,
        credentialed_items: credentialed_items
      }
    end

    def brex_accounts_cache_key(brex_item)
      "brex_accounts_#{Current.family.id}_#{brex_item.id}"
    end

    def brex_accounts_cache_sensitive_update?(permitted_params)
      permitted_params.key?(:token) || permitted_params.key?(:base_url)
    end

    def brex_item_selection_error_payload(credentialed_items)
      if brex_item_selection_required?(credentialed_items)
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

    def render_brex_item_selection_failure(credentialed_items:)
      if brex_item_selection_required?(credentialed_items)
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

    def brex_item_selection_required?(credentialed_items)
      credentialed_items.count > 1 && params[:brex_item_id].blank?
    end

    # Sanitize return_to parameter to prevent XSS attacks
    # Only allow internal paths, reject external URLs and javascript: URIs
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s

      # Parse the URL to check if it's external
      begin
        uri = URI.parse(return_to)

        # Reject absolute URLs with schemes (http:, https:, javascript:, etc.)
        # Only allow relative paths
        return nil if uri.scheme.present?

        # Ensure the path starts with / (is a relative path)
        return nil unless return_to.start_with?("/")

        return_to
      rescue URI::InvalidURIError
        # If the URI is invalid, reject it
        nil
      end
    end
end
