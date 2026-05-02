class Settings::WebauthnCredentialsController < ApplicationController
  include WebauthnRelyingParty

  layout "settings"

  before_action :ensure_mfa_enabled

  def options
    Current.user.ensure_webauthn_id!

    options = webauthn_relying_party.options_for_registration(
      user: {
        id: Current.user.webauthn_id,
        name: Current.user.email,
        display_name: Current.user.display_name
      },
      exclude: Current.user.webauthn_credentials.pluck(:credential_id),
      authenticator_selection: { user_verification: "preferred" },
      attestation: "none"
    )

    session[:webauthn_registration_challenge] = options.challenge

    render json: options
  end

  def create
    challenge = session.delete(:webauthn_registration_challenge)

    unless challenge.present?
      return render json: { error: t("webauthn_credentials.failure") }, status: :unprocessable_entity
    end

    credential = webauthn_relying_party.verify_registration(
      webauthn_credential_payload,
      challenge,
      user_presence: true
    )

    Current.user.webauthn_credentials.create!(
      nickname: webauthn_credential_name,
      credential_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      transports: webauthn_credential_transports
    )

    render json: { redirect_url: settings_security_path }
  rescue WebAuthn::Error, RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActionController::BadRequest, ActionController::ParameterMissing
    render json: { error: t("webauthn_credentials.failure") }, status: :unprocessable_entity
  end

  def destroy
    Current.user.webauthn_credentials.find(params[:id]).destroy!
    redirect_to settings_security_path, notice: t("webauthn_credentials.success")
  end

  private
    def ensure_mfa_enabled
      return if Current.user.otp_required?

      respond_to do |format|
        format.html { redirect_to settings_security_path, alert: t("webauthn_credentials.mfa_required") }
        format.json { render json: { error: t("webauthn_credentials.mfa_required") }, status: :forbidden }
      end
    end

    def webauthn_credential_name
      params.dig(:webauthn_credential, :nickname).presence || t("webauthn_credentials.default_name")
    end

    def webauthn_credential_transports
      Array(params.dig(:credential, :response, :transports)).compact_blank
    end
end
