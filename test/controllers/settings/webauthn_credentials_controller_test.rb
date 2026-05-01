require "test_helper"
require "webauthn/fake_client"

class Settings::WebauthnCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.webauthn_credentials.destroy_all
    sign_in @user
    @user.setup_mfa!
    @user.enable_mfa!
    @client = WebAuthn::FakeClient.new("http://www.example.com")
  end

  test "options require enabled MFA" do
    @user.disable_mfa!

    post options_settings_webauthn_credentials_path, as: :json

    assert_redirected_to settings_security_path
  end

  test "creates a credential from a verified registration challenge" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    assert_difference -> { @user.webauthn_credentials.count }, 1 do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "MacBook Touch ID" },
        credential: credential
      }, as: :json
    end

    assert_response :success
    assert_equal settings_security_path, JSON.parse(response.body).fetch("redirect_url")

    stored_credential = @user.webauthn_credentials.reload.last
    assert_equal "MacBook Touch ID", stored_credential.nickname
    assert_equal credential.fetch("id"), stored_credential.credential_id
    assert_includes stored_credential.transports, "internal"
    assert @user.reload.webauthn_id.present?
  end

  test "rejects a credential when registration challenge has already been used" do
    options = registration_options
    credential = @client.create(challenge: options.fetch("challenge"), rp_id: "www.example.com")

    post settings_webauthn_credentials_path, params: {
      webauthn_credential: { nickname: "MacBook Touch ID" },
      credential: credential
    }, as: :json
    assert_response :success

    assert_no_difference -> { @user.webauthn_credentials.count } do
      post settings_webauthn_credentials_path, params: {
        webauthn_credential: { nickname: "Replay" },
        credential: credential
      }, as: :json
    end

    assert_response :unprocessable_entity
  end

  test "destroys a credential owned by the current user" do
    credential = @user.webauthn_credentials.create!(
      nickname: "YubiKey",
      credential_id: "credential-to-delete",
      public_key: "public-key"
    )

    assert_difference -> { @user.webauthn_credentials.count }, -1 do
      delete settings_webauthn_credential_path(credential)
    end

    assert_redirected_to settings_security_path
  end

  private
    def registration_options
      post options_settings_webauthn_credentials_path, as: :json
      assert_response :success
      JSON.parse(response.body)
    end
end
