module Admin::AreasHelper
  def geojson_source_url(area, download: false, prod_url: false)
    args = { download: download.presence }
    args.merge!(host: request.host, port: nil, protocol: "https") if prod_url

    admin_map_url(area_id: area.id, format: :geojson, **args)
  end
end
