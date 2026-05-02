import { Controller } from "@hotwired/stimulus";
import {
  prepareCredentialRequestOptions,
  serializePublicKeyCredential
} from "utils/webauthn";

export default class extends Controller {
  static targets = ["error"];
  static values = {
    optionsUrl: String,
    verifyUrl: String,
    unsupportedMessage: String
  };

  async authenticate(event) {
    event.preventDefault();
    this.clearError();

    if (!window.PublicKeyCredential) {
      this.showError(this.unsupportedMessageValue);
      return;
    }

    try {
      const options = await this.fetchOptions();
      const credential = await navigator.credentials.get({
        publicKey: prepareCredentialRequestOptions(options)
      });

      await this.verifyCredential(serializePublicKeyCredential(credential));
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

  async verifyCredential(credential) {
    const response = await fetch(this.verifyUrlValue, {
      method: "POST",
      headers: this.headers,
      credentials: "same-origin",
      body: JSON.stringify({ credential })
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
      const fallback = await response.text();
      if (fallback) return fallback;
    }

    return "Could not verify that passkey or security key. Please try again.";
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message;
      this.errorTarget.hidden = false;
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.hidden = true;
    }
  }
}
