require "test_helper"

class FamilyMerchantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "index" do
    get family_merchants_path
    assert_response :success
  end

  test "new" do
    get new_family_merchant_path
    assert_response :success
  end

  test "should create merchant" do
    assert_difference("FamilyMerchant.count") do
      post family_merchants_url, params: { family_merchant: { name: "new merchant", color: "#000000" } }
    end

    assert_redirected_to family_merchants_path
  end

  test "should update merchant" do
    patch family_merchant_url(@merchant), params: { family_merchant: { name: "new name", color: "#000000" } }
    assert_redirected_to family_merchants_path
  end

  test "should destroy merchant" do
    assert_difference("FamilyMerchant.count", -1) do
      delete family_merchant_url(@merchant)
    end

    assert_redirected_to family_merchants_path
  end

  test "enhance enqueues job and redirects" do
    assert_enqueued_with(job: EnhanceProviderMerchantsJob) do
      post enhance_family_merchants_path
    end

    assert_redirected_to family_merchants_path
  end

  test "should merge selected merchants into a new family merchant" do
    source = merchants(:amazon)

    assert_difference("FamilyMerchant.count", 0) do
      post perform_merge_family_merchants_path, params: {
        new_target_name: "Streaming",
        new_target_color: "#000000",
        source_ids: [ source.id ]
      }
    end

    target = FamilyMerchant.find_by!(family: @user.family, name: "Streaming")
    assert_redirected_to family_merchants_path
    assert_equal target, transactions(:one).reload.merchant
    assert_not FamilyMerchant.exists?(source.id)
  end

  test "bulk website update scopes merchants to current family and refreshes logos" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client")
    Setting.stubs(:brand_fetch_logo_size).returns(128)

    provider_merchant = ProviderMerchant.create!(
      name: "Provider Merchant",
      source: "plaid",
      provider_merchant_id: "provider-merchant"
    )
    transactions(:one).update!(merchant: provider_merchant)

    other_family_merchant = FamilyMerchant.create!(
      family: families(:empty),
      name: "Other Family Merchant",
      color: "#000000"
    )

    post bulk_update_websites_family_merchants_path, params: {
      website_url: "https://www.example.com/path",
      merchant_ids: [ provider_merchant.id, other_family_merchant.id ]
    }

    assert_redirected_to family_merchants_path
    assert_equal "example.com", provider_merchant.reload.website_url
    assert_includes provider_merchant.logo_url, "cdn.brandfetch.io/example.com"
    assert_nil other_family_merchant.reload.website_url
  end
end
