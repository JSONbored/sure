# frozen_string_literal: true

class BrexItem::AccountFlow
  CACHE_TTL = 5.minutes

  class NoApiTokenError < StandardError; end
  class AccountNotFoundError < StandardError; end
  class InvalidAccountNameError < StandardError; end
  class AccountAlreadyLinkedError < StandardError; end

  NavigationResult = Data.define(:target, :flash_type, :message)

  SelectionResult = Data.define(:status, :brex_item, :available_accounts, :accountable_type, :message) do
    def success? = status == :success
    def setup_required? = status == :setup_required
    def provider_error? = status.in?([ :api_error, :unexpected_error ])
  end

  LinkAccountsResult = Data.define(:created_accounts, :already_linked_names, :invalid_account_ids) do
    def created_count = created_accounts.count
    def already_linked_count = already_linked_names.count
    def invalid_count = invalid_account_ids.count
  end

  SetupResult = Data.define(:created_accounts, :skipped_count) do
    def created_count = created_accounts.count
  end

  SetupCompletion = Data.define(:success, :message) do
    def success? = success
  end

  attr_reader :family, :brex_item_id, :brex_item, :credentialed_items

  def initialize(family:, brex_item_id: nil, brex_item: nil)
    @family = family
    @brex_item_id = brex_item_id
    @credentialed_items = family.brex_items.active.ordered.select(&:credentials_configured?)
    @brex_item = brex_item || resolve_brex_item
  end

  def self.cache_key(family, brex_item)
    "brex_accounts_#{family.id}_#{brex_item.id}"
  end

  def self.cache_sensitive_update?(permitted_params)
    permitted_params.key?(:token) || permitted_params.key?(:base_url)
  end

  def self.update_item_with_cache_expiration(brex_item, family:, attributes:)
    expire_accounts_cache = cache_sensitive_update?(attributes)
    updated = brex_item.update(attributes)

    Rails.cache.delete(cache_key(family, brex_item)) if updated && expire_accounts_cache

    updated
  end

  def selected?
    brex_item.present?
  end

  def selection_required?
    credentialed_items.count > 1 && brex_item_id.blank?
  end

  def preload_payload
    return selection_error_payload if !selected?
    return { success: false, error: "no_credentials", has_accounts: false } unless brex_item&.credentials_configured?

    cached_accounts = Rails.cache.read(cache_key)
    return { success: true, has_accounts: cached_accounts.any?, cached: true } if cached_accounts.present?

    available_accounts = fetch_accounts
    Rails.cache.write(cache_key, available_accounts, expires_in: CACHE_TTL)

    { success: true, has_accounts: available_accounts.any?, cached: false }
  rescue NoApiTokenError
    { success: false, error: "no_api_token", has_accounts: false }
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex preload error: #{e.message}")
    { success: false, error: "api_error", error_message: e.message, has_accounts: nil }
  rescue StandardError => e
    Rails.logger.error("Unexpected error preloading Brex accounts: #{e.class}: #{e.message}")
    { success: false, error: "unexpected_error", error_message: I18n.t("brex_items.errors.unexpected_error"), has_accounts: nil }
  end

  def select_accounts_result(accountable_type:)
    return selection_failure_result("brex_items.select_accounts") unless selected?

    accounts = filter_accounts(unlinked_available_accounts, accountable_type)
    if accounts.empty?
      return SelectionResult.new(
        status: :empty,
        brex_item: brex_item,
        available_accounts: [],
        accountable_type: accountable_type,
        message: I18n.t("brex_items.select_accounts.no_accounts_found")
      )
    end

    SelectionResult.new(
      status: :success,
      brex_item: brex_item,
      available_accounts: accounts,
      accountable_type: accountable_type,
      message: nil
    )
  rescue NoApiTokenError
    SelectionResult.new(
      status: :no_api_token,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: accountable_type,
      message: I18n.t("brex_items.select_accounts.no_api_token")
    )
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex API error in select_accounts: #{e.message}")
    SelectionResult.new(
      status: :api_error,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: accountable_type,
      message: e.message
    )
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_accounts: #{e.class}: #{e.message}")
    SelectionResult.new(
      status: :unexpected_error,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: accountable_type,
      message: I18n.t("brex_items.select_accounts.unexpected_error")
    )
  end

  def select_existing_account_result(account:)
    return linked_account_result if account.account_providers.exists?
    return selection_failure_result("brex_items.select_existing_account", accountable_type: account.accountable_type) unless selected?

    accounts = filter_accounts(unlinked_available_accounts, account.accountable_type)
    if accounts.empty?
      return SelectionResult.new(
        status: :empty,
        brex_item: brex_item,
        available_accounts: [],
        accountable_type: account.accountable_type,
        message: I18n.t("brex_items.select_existing_account.all_accounts_already_linked")
      )
    end

    SelectionResult.new(
      status: :success,
      brex_item: brex_item,
      available_accounts: accounts,
      accountable_type: account.accountable_type,
      message: nil
    )
  rescue NoApiTokenError
    SelectionResult.new(
      status: :no_api_token,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: account.accountable_type,
      message: I18n.t("brex_items.select_existing_account.no_api_token")
    )
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex API error in select_existing_account: #{e.message}")
    SelectionResult.new(
      status: :api_error,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: account.accountable_type,
      message: e.message
    )
  rescue StandardError => e
    Rails.logger.error("Unexpected error in select_existing_account: #{e.class}: #{e.message}")
    SelectionResult.new(
      status: :unexpected_error,
      brex_item: brex_item,
      available_accounts: [],
      accountable_type: account.accountable_type,
      message: I18n.t("brex_items.select_existing_account.unexpected_error")
    )
  end

  def link_new_accounts_result(account_ids:, accountable_type:)
    return navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.no_accounts_selected")) if account_ids.blank?
    return navigation(:settings_providers, :alert, I18n.t("brex_items.link_accounts.select_connection")) unless selected?

    link_navigation_result(link_new_accounts!(account_ids: account_ids, accountable_type: accountable_type))
  rescue NoApiTokenError
    navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.no_api_token"))
  rescue Provider::Brex::BrexError => e
    navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.api_error", message: e.message))
  end

  def link_existing_account_result(account:, brex_account_id:)
    return navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.missing_parameters")) if account.blank? || brex_account_id.blank?
    return navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.account_already_linked")) if account.account_providers.exists?
    return navigation(:settings_providers, :alert, I18n.t("brex_items.link_existing_account.select_connection")) unless selected?

    link_existing_account!(account: account, brex_account_id: brex_account_id)

    navigation(:return_to_or_accounts, :notice, I18n.t("brex_items.link_existing_account.success", account_name: account.name))
  rescue NoApiTokenError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.no_api_token"))
  rescue AccountNotFoundError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.brex_account_not_found"))
  rescue InvalidAccountNameError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.invalid_account_name"))
  rescue AccountAlreadyLinkedError
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.brex_account_already_linked"))
  rescue Provider::Brex::BrexError => e
    navigation(:accounts, :alert, I18n.t("brex_items.link_existing_account.api_error", message: e.message))
  end

  def link_new_accounts!(account_ids:, accountable_type:)
    created_accounts = []
    already_linked_names = []
    invalid_account_ids = []
    accounts_by_id = indexed_accounts

    account_ids.each do |account_id|
      account_data = accounts_by_id[account_id.to_s]
      next unless account_data

      account_name = BrexAccount.name_for(account_data)

      if account_name.blank?
        invalid_account_ids << account_id
        Rails.logger.warn "BrexItem::AccountFlow - Skipping account #{account_id} with blank name"
        next
      end

      brex_account = upsert_brex_account!(account_id, account_data)

      if brex_account.account_provider.present?
        already_linked_names << account_name
        next
      end

      account = Account.create_and_sync(
        {
          family: family,
          name: account_name,
          balance: 0,
          currency: BrexAccount.currency_for(account_data),
          accountable_type: accountable_type,
          accountable_attributes: BrexAccount.default_accountable_attributes(accountable_type)
        },
        skip_initial_sync: true
      )

      AccountProvider.create!(account: account, provider: brex_account)
      created_accounts << account
    end

    brex_item.sync_later if created_accounts.any?

    LinkAccountsResult.new(
      created_accounts: created_accounts,
      already_linked_names: already_linked_names,
      invalid_account_ids: invalid_account_ids
    )
  end

  def link_existing_account!(account:, brex_account_id:)
    account_data = indexed_accounts[brex_account_id.to_s]
    raise AccountNotFoundError unless account_data

    account_name = BrexAccount.name_for(account_data)
    raise InvalidAccountNameError if account_name.blank?

    brex_account = upsert_brex_account!(brex_account_id, account_data)
    raise AccountAlreadyLinkedError if brex_account.account_provider.present?

    AccountProvider.create!(account: account, provider: brex_account)
    brex_item.sync_later

    brex_account
  end

  def import_accounts_from_api_if_needed
    return nil unless brex_item.brex_accounts.empty?
    raise NoApiTokenError unless brex_item.credentials_configured?

    available_accounts = fetch_accounts
    return nil if available_accounts.empty?

    available_accounts.each do |account_data|
      account_name = BrexAccount.name_for(account_data)
      next if account_name.blank?

      upsert_brex_account!(account_data.with_indifferent_access[:id], account_data)
    end

    nil
  end

  def unlinked_brex_accounts
    brex_item.brex_accounts
             .left_joins(:account_provider)
             .where(account_providers: { id: nil })
  end

  def account_type_options
    supported_types = Provider::BrexAdapter.supported_account_types
    account_type_keys = {
      "depository" => "Depository",
      "credit_card" => "CreditCard",
      "investment" => "Investment",
      "loan" => "Loan",
      "other_asset" => "OtherAsset"
    }

    options = account_type_keys.filter_map do |key, type|
      next unless supported_types.include?(type)

      [ I18n.t("brex_items.setup_accounts.account_types.#{key}"), type ]
    end

    [ [ I18n.t("brex_items.setup_accounts.account_types.skip"), "skip" ] ] + options
  end

  def subtype_options
    supported_types = Provider::BrexAdapter.supported_account_types
    all_subtype_options = {
      "Depository" => {
        label: I18n.t("brex_items.setup_accounts.subtype_labels.depository"),
        options: translate_subtypes("depository", Depository::SUBTYPES)
      },
      "CreditCard" => {
        label: I18n.t("brex_items.setup_accounts.subtype_labels.credit_card"),
        options: [],
        message: I18n.t("brex_items.setup_accounts.subtype_messages.credit_card")
      },
      "Investment" => {
        label: I18n.t("brex_items.setup_accounts.subtype_labels.investment"),
        options: translate_subtypes("investment", Investment::SUBTYPES)
      },
      "Loan" => {
        label: I18n.t("brex_items.setup_accounts.subtype_labels.loan"),
        options: translate_subtypes("loan", Loan::SUBTYPES)
      },
      "OtherAsset" => {
        label: I18n.t("brex_items.setup_accounts.subtype_labels.other_asset").presence,
        options: [],
        message: I18n.t("brex_items.setup_accounts.subtype_messages.other_asset")
      }
    }

    all_subtype_options.slice(*supported_types)
  end

  def complete_setup!(account_types:, account_subtypes:)
    created_accounts = []
    skipped_count = 0
    valid_types = Provider::BrexAdapter.supported_account_types

    ActiveRecord::Base.transaction do
      account_types.each do |brex_account_id, selected_type|
        if selected_type == "skip" || selected_type.blank?
          skipped_count += 1
          next
        end

        unless valid_types.include?(selected_type)
          Rails.logger.warn("Invalid account type '#{selected_type}' submitted for Brex account #{brex_account_id}")
          next
        end

        brex_account = brex_item.brex_accounts.find_by(id: brex_account_id)
        unless brex_account
          Rails.logger.warn("Brex account #{brex_account_id} not found for item #{brex_item.id}")
          next
        end

        if brex_account.account_provider.present?
          Rails.logger.info("Brex account #{brex_account_id} already linked, skipping")
          next
        end

        selected_subtype = selected_subtype_for(
          selected_type: selected_type,
          submitted_subtype: account_subtypes[brex_account_id]
        )

        account = Account.create_and_sync(
          {
            family: family,
            name: brex_account.name,
            balance: brex_account.current_balance || 0,
            currency: brex_account.currency.presence || family.currency,
            accountable_type: selected_type,
            accountable_attributes: selected_subtype.present? ? { subtype: selected_subtype } : {}
          },
          skip_initial_sync: true
        )

        AccountProvider.create!(account: account, provider: brex_account)
        created_accounts << account
      end
    end

    brex_item.sync_later if created_accounts.any?

    SetupResult.new(created_accounts: created_accounts, skipped_count: skipped_count)
  end

  def import_accounts_error_message
    import_accounts_from_api_if_needed
  rescue NoApiTokenError
    I18n.t("brex_items.setup_accounts.no_api_token")
  rescue Provider::Brex::BrexError => e
    Rails.logger.error("Brex API error: #{e.message}")
    I18n.t("brex_items.setup_accounts.api_error", message: e.message)
  rescue StandardError => e
    Rails.logger.error("Unexpected error fetching Brex accounts: #{e.class}: #{e.message}")
    I18n.t("brex_items.setup_accounts.api_error", message: I18n.t("brex_items.errors.unexpected_error"))
  end

  def complete_setup_result(account_types:, account_subtypes:)
    result = complete_setup!(account_types: account_types, account_subtypes: account_subtypes)

    SetupCompletion.new(success: true, message: setup_notice(result))
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    Rails.logger.error("Brex account setup failed: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    SetupCompletion.new(
      success: false,
      message: I18n.t("brex_items.complete_account_setup.creation_failed", error: e.message)
    )
  rescue StandardError => e
    Rails.logger.error("Brex account setup failed unexpectedly: #{e.class} - #{e.message}")
    Rails.logger.error(Array(e.backtrace).first(10).join("\n"))
    SetupCompletion.new(
      success: false,
      message: I18n.t(
        "brex_items.complete_account_setup.creation_failed",
        error: I18n.t("brex_items.complete_account_setup.unexpected_error")
      )
    )
  end

  private

    def selection_error_payload
      return { success: false, error: "no_credentials", has_accounts: false } unless selection_required?

      {
        success: false,
        error: "select_connection",
        error_message: I18n.t("brex_items.select_accounts.select_connection"),
        has_accounts: nil
      }
    end

    def selection_failure_result(scope, accountable_type: nil)
      if selection_required?
        SelectionResult.new(
          status: :select_connection,
          brex_item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.select_connection")
        )
      else
        SelectionResult.new(
          status: :setup_required,
          brex_item: nil,
          available_accounts: [],
          accountable_type: accountable_type,
          message: I18n.t("#{scope}.no_credentials_configured")
        )
      end
    end

    def linked_account_result
      SelectionResult.new(
        status: :account_already_linked,
        brex_item: brex_item,
        available_accounts: [],
        accountable_type: nil,
        message: I18n.t("brex_items.select_existing_account.account_already_linked")
      )
    end

    def link_navigation_result(result)
      if result.invalid_count.positive? && result.created_count.zero? && result.already_linked_count.zero?
        navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.invalid_account_names", count: result.invalid_count))
      elsif result.invalid_count.positive? && (result.created_count.positive? || result.already_linked_count.positive?)
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "brex_items.link_accounts.partial_invalid",
            created_count: result.created_count,
            already_linked_count: result.already_linked_count,
            invalid_count: result.invalid_count
          )
        )
      elsif result.created_count.positive? && result.already_linked_count.positive?
        navigation(
          :return_to_or_accounts,
          :notice,
          I18n.t(
            "brex_items.link_accounts.partial_success",
            created_count: result.created_count,
            already_linked_count: result.already_linked_count,
            already_linked_names: result.already_linked_names.join(", ")
          )
        )
      elsif result.created_count.positive?
        navigation(:return_to_or_accounts, :notice, I18n.t("brex_items.link_accounts.success", count: result.created_count))
      elsif result.already_linked_count.positive?
        navigation(
          :return_to_or_accounts,
          :alert,
          I18n.t(
            "brex_items.link_accounts.all_already_linked",
            count: result.already_linked_count,
            names: result.already_linked_names.join(", ")
          )
        )
      else
        navigation(:new_account, :alert, I18n.t("brex_items.link_accounts.link_failed"))
      end
    end

    def navigation(target, flash_type, message)
      NavigationResult.new(target: target, flash_type: flash_type, message: message)
    end

    def setup_notice(result)
      if result.created_count.positive?
        I18n.t("brex_items.complete_account_setup.success", count: result.created_count)
      elsif result.skipped_count.positive?
        I18n.t("brex_items.complete_account_setup.all_skipped")
      else
        I18n.t("brex_items.complete_account_setup.no_accounts")
      end
    end

    def resolve_brex_item
      if brex_item_id.present?
        item = family.brex_items.active.find_by(id: brex_item_id)
        return item if item&.credentials_configured?

        return nil
      end

      credentialed_items.first if credentialed_items.one?
    end

    def cache_key
      self.class.cache_key(family, brex_item)
    end

    def fetch_accounts
      provider = brex_item&.brex_provider
      raise NoApiTokenError unless provider.present?

      accounts_data = provider.get_accounts
      accounts_data[:accounts] || []
    end

    def accounts
      cached_accounts = Rails.cache.read(cache_key)
      return cached_accounts unless cached_accounts.nil?

      available_accounts = fetch_accounts
      Rails.cache.write(cache_key, available_accounts, expires_in: CACHE_TTL)
      available_accounts
    end

    def unlinked_available_accounts
      linked_account_ids = brex_item.brex_accounts.joins(:account_provider).pluck(:account_id).map(&:to_s)
      accounts.reject { |account| linked_account_ids.include?(account.with_indifferent_access[:id].to_s) }
    end

    def filter_accounts(accounts, accountable_type)
      return [] unless Provider::BrexAdapter.supported_account_types.include?(accountable_type)

      accounts.select do |account|
        case accountable_type
        when "CreditCard"
          BrexAccount.kind_for(account) == "card"
        when "Depository"
          BrexAccount.kind_for(account) == "cash"
        else
          true
        end
      end
    end

    def indexed_accounts
      accounts.index_by { |account| account.with_indifferent_access[:id].to_s }
    end

    def upsert_brex_account!(account_id, account_data)
      brex_account = brex_item.brex_accounts.find_or_initialize_by(account_id: account_id.to_s)
      brex_account.upsert_brex_snapshot!(account_data)
      brex_account.save!
      brex_account
    end

    def translate_subtypes(type_key, subtypes_hash)
      subtypes_hash.map do |key, value|
        [
          I18n.t("brex_items.setup_accounts.subtypes.#{type_key}.#{key}", default: value[:long] || key.to_s.humanize),
          key
        ]
      end
    end

    def selected_subtype_for(selected_type:, submitted_subtype:)
      return "credit_card" if selected_type == "CreditCard" && submitted_subtype.blank?
      return "checking" if selected_type == "Depository" && submitted_subtype.blank?

      submitted_subtype
    end
end
