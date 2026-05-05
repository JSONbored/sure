module BrexItem::Provided
  extend ActiveSupport::Concern

  def brex_provider
    return nil unless credentials_configured?

    Provider::Brex.new(token.to_s.strip, base_url: effective_base_url)
  end

  def syncer
    BrexItem::Syncer.new(self)
  end
end
