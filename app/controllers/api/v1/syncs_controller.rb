# frozen_string_literal: true

class Api::V1::SyncsController < Api::V1::BaseController
  include Pagy::Backend

  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  private_constant :UUID_PATTERN

  before_action :ensure_read_scope
  before_action :set_sync, only: [ :show ]

  def index
    @per_page = safe_per_page_param
    @pagy, @syncs = pagy(
      family_syncs_query.preload(:syncable, :children).ordered,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def latest
    @sync = family_syncs_query.preload(:syncable, :children).ordered.first
    render :show
  end

  def show
    render :show
  end

  private

    def set_sync
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @sync = family_syncs_query.preload(:syncable, :children).find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def family_syncs_query
      Sync.for_family(current_resource_owner.family, resource_owner: current_resource_owner)
    end

    def valid_uuid?(value)
      value.to_s.match?(UUID_PATTERN)
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i

      case per_page
      when 1..100
        per_page
      else
        25
      end
    end
end
