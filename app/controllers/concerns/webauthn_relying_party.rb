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

      payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
      raise ActionController::BadRequest, "credential must be an object" unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError, TypeError, ArgumentError
      raise ActionController::BadRequest, "invalid credential payload"
    end
end
