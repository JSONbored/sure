class Merchant < ApplicationRecord
  TYPES = %w[FamilyMerchant ProviderMerchant].freeze

  has_many :transactions, dependent: :nullify
  has_many :recurring_transactions, dependent: :destroy

  validates :name, presence: true
  validates :type, inclusion: { in: TYPES }

  scope :alphabetically, -> { order(:name) }

  class << self
    def extract_domain(url)
      return nil if url.blank?

      normalized_url = url.to_s.strip
      normalized_url = "https://#{normalized_url}" unless normalized_url.start_with?("http://", "https://")
      URI.parse(normalized_url).host&.sub(/\Awww\./, "")
    rescue URI::InvalidURIError
      url.to_s.strip.sub(/\Awww\./, "").presence
    end

    def brandfetch_logo_url_for(url)
      domain = extract_domain(url)
      return nil unless domain.present? && Setting.brand_fetch_client_id.present?

      size = Setting.brand_fetch_logo_size
      "https://cdn.brandfetch.io/#{domain}/icon/fallback/lettermark/w/#{size}/h/#{size}?c=#{Setting.brand_fetch_client_id}"
    end
  end
end
