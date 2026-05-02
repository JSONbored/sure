module WebauthnRelyingParty
  extend ActiveSupport::Concern

  private
    def webauthn_relying_party
      WebAuthn::RelyingParty.new(
        name: "Sure",
        id: request.host,
        allowed_origins: [ request.base_url ],
        verify_attestation_statement: false
      )
    end

    def webauthn_credential_payload
      payload = params.require(:credential)
      payload = JSON.parse(payload) if payload.is_a?(String)

      case payload
      when ActionController::Parameters
        payload.to_unsafe_h
      when Hash
        payload
      else
        raise ActionController::ParameterMissing, :credential
      end
    end
end
