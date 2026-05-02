import { Controller } from "@hotwired/stimulus";
import {
  prepareCredentialCreationOptions,
  serializePublicKeyCredential
} from "utils/webauthn";

export default class extends Controller {
  static targets = ["error", "nickname"];
  static values = {
    optionsUrl: String,
    createUrl: String,
    unsupportedMessage: String,
    errorFallback: String
  };

  async register(event) {
    event.preventDefault();
    this.clearError();

    if (!window.PublicKeyCredential) {
      this.showError(this.unsupportedMessageValue);
      return;
    }

    try {
      const options = await this.fetchOptions();
      const credential = await navigator.credentials.create({
        publicKey: prepareCredentialCreationOptions(options)
      });

      await this.createCredential(serializePublicKeyCredential(credential));
    } catch (error) {
      this.showError(error.message);
    }
  }

  async fetchOptions() {
    const response = await fetch(this.optionsUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin"
    });

    if (!response.ok) throw new Error(await this.errorMessage(response));

    return response.json();
  }

  async createCredential(credential) {
    const response = await fetch(this.createUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin",
      body: JSON.stringify({
        credential,
        webauthn_credential: {
          nickname: this.hasNicknameTarget ? this.nicknameTarget.value : ""
        }
      })
    });

    if (!response.ok) throw new Error(await this.errorMessage(response));

    const result = await response.json();
    window.location.href = result.redirect_url;
  }

  get headers() {
    return {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
    };
  }

  async errorMessage(response) {
    try {
      const result = await response.clone().json();
      if (result.error) return result.error;
    } catch (_error) {
      return this.errorFallbackValue;
    }

    return this.errorFallbackValue;
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message;
      this.errorTarget.hidden = false;
      this.errorTarget.setAttribute("aria-hidden", "false");
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.hidden = true;
      this.errorTarget.setAttribute("aria-hidden", "true");
    }
  }
}
