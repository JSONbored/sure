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
      payload.respond_to?(:to_unsafe_h) ? payload.to_unsafe_h : payload.to_h
    end
end
