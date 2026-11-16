# more info: https://github.com/rails/rails/tree/main/activestorage/app/controllers/active_storage
class ProxyController < ActiveStorage::BaseController
  include ActiveStorage::Streaming
  include ActiveStorage::DisableSession

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    topo = Topo.find(params[:id])
    # Public and cached by browsers/CDN, so only published photos in published areas;
    # admin pages load photos through signed Active Storage URLs instead
    return head(:not_found) unless topo.publicly_visible?

    # Processed now if the background job hasn't made it yet: streaming a variant that isn't
    # there sends an empty body, which would then be cached for ever
    representation = topo.display_photo.processed

    http_cache_forever public: true do
      send_blob_stream representation, disposition: params[:disposition]
    end
  end

  private
  def not_found
    head :not_found
  end
end
