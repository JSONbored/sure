require "uri"

require "test_helper"

class Provider::BrexAdapterTest < ActiveSupport::TestCase
  test "supports Depository accounts" do
    assert_includes Provider::BrexAdapter.supported_account_types, "Depository"
  end

  test "supports CreditCard accounts" do
    assert_includes Provider::BrexAdapter.supported_account_types, "CreditCard"
  end

  test "does not support Investment accounts" do
    assert_not_includes Provider::BrexAdapter.supported_account_types, "Investment"
  end

  test "returns fallback connection config when no credentials exist yet" do
    # Brex is a per-family provider - any family can connect
    family = families(:empty)
    configs = Provider::BrexAdapter.connection_configs(family: family)

    assert_equal 1, configs.length
    assert_equal "brex", configs.first[:key]
    assert_equal I18n.t("brex_items.provider_connection.default_name"), configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "returns one connection config per credentialed brex item" do
    family = families(:dylan_family)
    first_item = brex_items(:one)
    second_item = BrexItem.create!(
      family: family,
      name: "Business Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    configs = Provider::BrexAdapter.connection_configs(family: family)

    assert_equal 2, configs.length
    assert_equal [ "brex_#{second_item.id}", "brex_#{first_item.id}" ], configs.map { |config| config[:key] }
    assert_equal [
      I18n.t("brex_items.provider_connection.name", name: second_item.name),
      I18n.t("brex_items.provider_connection.name", name: first_item.name)
    ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Depository", "/accounts"))
    assert_equal "/brex_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "brex_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:depository).id))
    assert_equal "/brex_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "brex_item_id=#{second_item.id}"
  end

  test "connection configs ignore items with whitespace-only tokens" do
    family = families(:dylan_family)
    BrexItem.create!(
      family: family,
      name: "Blank Brex",
      token: "temporary_token",
      base_url: "https://api.brex.com"
    ).update_column(:token, "   ")

    configs = Provider::BrexAdapter.connection_configs(family: family)

    assert_equal [ "brex_#{brex_items(:one).id}" ], configs.map { |config| config[:key] }
  end

  test "build_provider returns nil when family is nil" do
    assert_nil Provider::BrexAdapter.build_provider(family: nil)
  end

  test "build_provider returns nil when family has no brex items" do
    family = families(:empty)
    assert_nil Provider::BrexAdapter.build_provider(family: family)
  end

  test "build_provider returns Brex provider when credentials configured" do
    family = families(:dylan_family)
    provider = Provider::BrexAdapter.build_provider(family: family)

    assert_instance_of Provider::Brex, provider
  end

  test "build_provider uses explicit brex item credentials" do
    family = families(:dylan_family)
    second_item = BrexItem.create!(
      family: family,
      name: "Business Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    provider = Provider::BrexAdapter.build_provider(family: family, brex_item_id: second_item.id)

    assert_instance_of Provider::Brex, provider
    assert_equal "second_brex_token", provider.token
    assert_equal "https://api.brex.com", provider.base_url
  end

  test "build_provider does not pick the first connection when multiple credentials exist" do
    family = families(:dylan_family)
    BrexItem.create!(
      family: family,
      name: "Business Brex",
      token: "second_brex_token",
      base_url: "https://api.brex.com"
    )

    assert_nil Provider::BrexAdapter.build_provider(family: family)
  end

  test "build_provider strips surrounding token whitespace" do
    family = families(:dylan_family)
    second_item = BrexItem.create!(
      family: family,
      name: "Business Brex",
      token: " second_brex_token \n",
      base_url: "https://api.brex.com"
    )

    provider = Provider::BrexAdapter.build_provider(family: family, brex_item_id: second_item.id)

    assert_equal "second_brex_token", provider.token
  end

  test "build_provider refuses brex items outside the family" do
    family = families(:dylan_family)
    other_item = BrexItem.create!(
      family: families(:empty),
      name: "Other Brex",
      token: "other_brex_token",
      base_url: "https://api.brex.com"
    )

    assert_nil Provider::BrexAdapter.build_provider(family: family, brex_item_id: other_item.id)
  end

  test "build_provider refuses explicit brex item without usable credentials" do
    family = families(:dylan_family)
    blank_item = BrexItem.create!(
      family: family,
      name: "Blank Brex",
      token: "temporary_token",
      base_url: "https://api.brex.com"
    )
    blank_item.update_column(:token, "   ")

    assert_nil Provider::BrexAdapter.build_provider(family: family, brex_item_id: blank_item.id)
  end
end
